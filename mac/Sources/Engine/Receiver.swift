import Darwin
import Foundation

// Multipath receiver.
//
// Reassembly is trivially correct because chunks carry their own file offset:
// every data socket runs its own reader thread and writes straight to the right
// place in the file with pwrite(). No ordering, no per-socket buffering, and
// no cross-socket coordination beyond a set of chunk indices.
//
// Resume and de-duplication are cheap: if a file of the offered size already
// exists and hashes equal, we answer "offset = size" and the sender has nothing
// left to do.

struct ReceivedFile {
    let name: String
    let path: String
    let size: Int64
    let seconds: Double
}

/// One file being written by N sockets at once. Every data socket writes into
/// the same fd at absolute offsets, so no writer lock is needed — only the
/// bookkeeping is guarded.
final class ActiveFile {
    let name: String
    let path: String
    let size: Int64
    let digest: String
    let startOffset: Int64
    let chunkCount: Int

    private let fd: Int32
    private let condition = NSCondition()
    private var indices = Set<Int>()
    private var written: Int64 = 0

    init(name: String, path: String, size: Int64, digest: String, startOffset: Int64) throws {
        self.name = name
        self.path = path
        self.size = size
        self.digest = digest
        self.startOffset = startOffset
        self.chunkCount = Int((size - startOffset + Int64(Proto.chunkSize) - 1) / Int64(Proto.chunkSize))

        let flags = startOffset > 0 ? (O_RDWR | O_CREAT) : (O_RDWR | O_CREAT | O_TRUNC)
        fd = Darwin.open(path, flags, 0o644)
        guard fd >= 0 else { throw HyperSendError.fileWrite("cannot open \(path)") }
        if startOffset > 0 {
            // The final hash is what really proves correctness; this just keeps
            // the length honest while chunks land out of order.
            _ = ftruncate(fd, startOffset)
        }
    }

    var receivedBytes: Int64 {
        condition.lock()
        defer { condition.unlock() }
        return startOffset + written
    }

    /// Writes one chunk where it belongs. Safe to call from many threads.
    func ingest(offset: Int64, payload: Data) throws {
        let index = Int(offset / Int64(Proto.chunkSize))
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var done = 0
            while done < raw.count {
                let n = Darwin.pwrite(fd, base.advanced(by: done), raw.count - done, off_t(offset) + off_t(done))
                if n > 0 {
                    done += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                throw HyperSendError.fileWrite("pwrite at \(offset) failed (errno \(errno))")
            }
        }
        condition.lock()
        if indices.insert(index).inserted {
            written += Int64(payload.count)
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Waits until every scheduled chunk has landed, or until it is clear the
    /// sender has gone away.
    ///
    /// `liveSockets` reports the session's data-socket count rather than this
    /// file's: the sender opens its pool *before* offering, so sockets are
    /// usually accepted while no file is active yet. Counting per file would
    /// read zero and abandon a perfectly healthy, merely slow transfer.
    func waitUntilComplete(timeout: TimeInterval, liveSockets: () -> Int) -> Bool {
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while indices.count < chunkCount {
            if Date() >= deadline { return false }
            if liveSockets() == 0, Date().timeIntervalSince(started) > 1.5 { return false }
            condition.wait(until: Date().addingTimeInterval(0.2))
        }
        return true
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
    }
}

/// Holds the file and sockets currently in play. Written by the session thread,
/// read by every data-socket thread, so all access goes through the lock.
private final class ActiveBox {
    private let lock = NSLock()
    private var file: ActiveFile?
    private var sockets: [TCPConnection] = []

    func get() -> ActiveFile? {
        lock.lock()
        defer { lock.unlock() }
        return file
    }

    func set(_ value: ActiveFile?) {
        lock.lock()
        let previous = file
        file = value
        lock.unlock()
        previous?.close()
    }

    func add(_ conn: TCPConnection) {
        lock.lock()
        sockets.append(conn)
        lock.unlock()
    }

    func remove(_ conn: TCPConnection) {
        lock.lock()
        sockets.removeAll { $0 === conn }
        lock.unlock()
    }

    /// Live data sockets for the whole session (not per file).
    var openCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sockets.count
    }

    /// Closes every data socket (end of session).
    func closeAll() {
        lock.lock()
        let all = sockets
        sockets = []
        lock.unlock()
        all.forEach { $0.close() }
    }
}

final class ReceiveEngine {
    struct Hooks {
        /// Return false to decline the file.
        var accept: ((String, Int64) -> Bool)?
        var progress: ((String, Int64, Int64) -> Void)?
        var finished: ((ReceivedFile) -> Void)?
        var log: ((String) -> Void)?
    }

    private let destDir: URL
    private let controlPort: UInt16
    private let preferredDataPort: UInt16
    private var hooks: Hooks
    private var controlServer: TCPServer?
    private var running = false
    private let hookLock = NSLock()

    /// Port the data plane actually bound — surfaced so the UI can explain the
    /// USB tunnel state.
    private(set) var dataPort: UInt16 = 0

    init(
        destDir: URL,
        controlPort: UInt16 = Proto.controlPort,
        dataPort: UInt16 = Proto.usbDataPort,
        hooks: Hooks = Hooks(),
    ) {
        self.destDir = destDir
        self.controlPort = controlPort
        self.preferredDataPort = dataPort
        self.hooks = hooks
    }

    func updateHooks(_ newHooks: Hooks) {
        hookLock.lock()
        hooks = newHooks
        hookLock.unlock()
    }

    private func current() -> Hooks {
        hookLock.lock()
        defer { hookLock.unlock() }
        return hooks
    }

    func start() throws {
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let server = try TCPServer(port: controlPort)
        controlServer = server
        running = true

        let thread = Thread { [weak self] in self?.acceptLoop(server) }
        thread.name = "hypersend.receiver"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    func stop() {
        running = false
        controlServer?.close()
        controlServer = nil
    }

    private func acceptLoop(_ server: TCPServer) {
        while running {
            guard let connection = (try? server.accept(timeoutMs: 300)) ?? nil else { continue }
            let thread = Thread { [weak self] in self?.runSession(connection) }
            thread.name = "hypersend.session"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    // MARK: - Session

    private func runSession(_ control: TCPConnection) {
        let box = ActiveBox()
        var dataServer: TCPServer?
        defer {
            box.closeAll()
            dataServer?.close()
            control.close()
        }

        func startDataPlane(preferred: UInt16, log: @escaping (String) -> Void) throws -> TCPServer {
            if let fixed = try? TCPServer(port: preferred) {
                return fixed
            }
            let ephemeral = try TCPServer(port: 0)
            log("data port \(preferred) busy — using :\(ephemeral.boundPort) (fixed-port lanes unavailable)")
            return ephemeral
        }

        func acceptData(_ server: TCPServer) {
            while running, server.fd >= 0 {
                guard let connection = (try? server.accept(timeoutMs: 300)) ?? nil else {
                    if server.fd < 0 { return }
                    continue
                }
                box.add(connection)
                let thread = Thread { [weak self] in
                    self?.readChunks(connection, box: box)
                    box.remove(connection)
                    connection.close()
                }
                thread.name = "hypersend.data.rx"
                thread.stackSize = 512 * 1024
                thread.start()
            }
        }

        do {
            while running {
                guard let msg = try control.readJSON(timeoutMs: 1000) else { break }
                let hooks = current()

                switch msg["type"] as? String {
                case "hello":
                    let peerVersion = (msg["version"] as? Int) ?? 0
                    guard peerVersion == Proto.version else {
                        try control.writeJSON([
                            "type": "error",
                            "message": "protocol mismatch: peer v\(peerVersion), us v\(Proto.version)",
                        ])
                        return
                    }
                    let peerName = (msg["name"] as? String) ?? "device"
                    hooks.log?("\(peerName) connected")

                    // Bind the FIXED data port whenever possible: a stable port
                    // is the only reason `adb forward tcp:44012 tcp:44012` can
                    // hand the USB cable its own lane.
                    let server = try startDataPlane(preferred: preferredDataPort, log: { hooks.log?($0) })
                    dataServer = server
                    dataPort = server.boundPort

                    try control.writeJSON([
                        "type": "ready",
                        "name": hostName(),
                        "dataPort": Int(server.boundPort),
                        "chunkSize": Proto.chunkSize,
                    ])
                    let acceptor = Thread { acceptData(server) }
                    acceptor.name = "hypersend.data"
                    acceptor.stackSize = 256 * 1024
                    acceptor.start()

                case "offer":
                    guard let transferId = msg["transferId"] as? String else { continue }
                    let rawPath = (msg["path"] as? String) ?? ""
                    let size = Int64((msg["size"] as? Int) ?? 0)
                    let digest = (msg["sha256"] as? String) ?? ""

                    let safePath: String
                    do {
                        safePath = try sanitizeRelativePath(rawPath)
                    } catch {
                        try control.writeJSON([
                            "type": "offer-response",
                            "transferId": transferId,
                            "accept": false,
                            "reason": "unsafe path",
                        ])
                        continue
                    }

                    let destination = destDir.appendingPathComponent(safePath)
                    try? FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                    )

                    // Resume: same size AND same hash means we already hold it.
                    var offset: Int64 = 0
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
                       let existing = attrs[.size] as? Int64, existing > 0 {
                        if existing < size {
                            offset = existing
                        } else if existing == size {
                            if (try? sha256File(destination)) == digest {
                                try control.writeJSON([
                                    "type": "offer-response",
                                    "transferId": transferId,
                                    "accept": true,
                                    "offset": Int(size),
                                ])
                                try control.writeJSON([
                                    "type": "file-done",
                                    "transferId": transferId,
                                    "ok": true,
                                ])
                                hooks.finished?(ReceivedFile(
                                    name: destination.lastPathComponent,
                                    path: destination.path,
                                    size: size,
                                    seconds: 0,
                                ))
                                hooks.log?("already have \(destination.lastPathComponent) — skipped")
                                continue
                            }
                        }
                    }

                    if let accept = hooks.accept, !accept(safePath, size) {
                        try control.writeJSON([
                            "type": "offer-response",
                            "transferId": transferId,
                            "accept": false,
                            "reason": "declined by receiver",
                        ])
                        continue
                    }

                    try control.writeJSON([
                        "type": "offer-response",
                        "transferId": transferId,
                        "accept": true,
                        "offset": Int(offset),
                    ])

                    box.set(nil)
                    let file = try ActiveFile(
                        name: destination.lastPathComponent,
                        path: destination.path,
                        size: size,
                        digest: digest,
                        startOffset: offset,
                    )
                    box.set(file)

                    if size > offset {
                        hooks.log?("receiving \(file.name) · \(formattedBytes(size))")
                    }

                case "file-sent":
                    guard let transferId = msg["transferId"] as? String, let file = box.get() else { continue }
                    let arrived = file.waitUntilComplete(timeout: 900, liveSockets: { box.openCount })
                    let actual = (try? sha256File(URL(fileURLWithPath: file.path))) ?? ""
                    if arrived, actual == file.digest {
                        try control.writeJSON(["type": "file-done", "transferId": transferId, "ok": true])
                        hooks.finished?(ReceivedFile(
                            name: file.name,
                            path: file.path,
                            size: file.size,
                            seconds: 0,
                        ))
                        hooks.log?("✓ \(file.name) verified · \(formattedBytes(file.size))")
                    } else {
                        try? FileManager.default.removeItem(atPath: file.path)
                        var reply: [String: Any] = [
                            "type": "file-done",
                            "transferId": transferId,
                            "ok": false,
                        ]
                        reply["error"] = arrived ? "sha256 mismatch — file discarded" : "data streams ended early"
                        try control.writeJSON(reply)
                        hooks.log?("✗ \(file.name) failed — discarded")
                    }
                    box.set(nil)

                case "batch-done":
                    hooks.log?("batch complete · \((msg["files"] as? Int) ?? 0) file(s)")
                    return

                case "error":
                    hooks.log?("peer error: \((msg["message"] as? String) ?? "unknown")")
                    return

                default:
                    continue
                }
            }
        } catch {
            current().log?("session ended: \(error.localizedDescription)")
        }
    }

    // MARK: - Data plane

    private func readChunks(_ conn: TCPConnection, box: ActiveBox) {
        let reader = ByteReader(fd: conn.fd)
        var lastReport = Date.distantPast
        while running {
            do {
                guard let header = try reader.readChunkHeader() else { return }
                guard let payload = try reader.readExactly(header.payloadBytes) else { return }
                guard let file = box.get() else {
                    throw HyperSendError.protocolViolation("chunk arrived with no active file")
                }
                try file.ingest(offset: header.offset, payload: payload)

                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.2 {
                    lastReport = now
                    current().progress?(file.name, file.receivedBytes, file.size)
                }
            } catch {
                return
            }
        }
    }
}

func hostName() -> String {
    let name = Host.current().localizedName ?? "Mac"
    return name.isEmpty ? "Mac" : name
}
