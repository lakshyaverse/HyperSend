import Foundation
import CryptoKit
import Darwin

// HyperSend engine (Swift) — speaks the exact wire protocol the Node reference
// implementation and the Android app use:
//
//   control channel : [4-byte big-endian length][JSON] over TCP :44010
//   data plane      : [4-byte length][1-byte flags][8-byte BE offset][payload]
//                     over one or more TCP connections to the receiver's
//                     advertised data port (:44012 on Android, which is fixed
//                     so `adb forward tcp:44012 tcp:44012` can add the USB lane)
//   discovery       : UDP beacon on :44011, JSON {magic,port,name}
//
// Multipath: every data connection is a worker pulling chunk offsets from ONE
// shared queue. Fast lanes simply complete more chunks — no scheduling logic
// beyond a lock-protected counter.

enum HyperSendError: Error, LocalizedError {
    case socket(String)
    case protocolViolation(String)
    case fileRead(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .socket(let m): return "Network error: \(m)"
        case .protocolViolation(let m): return "Protocol error: \(m)"
        case .fileRead(let m): return "File error: \(m)"
        case .rejected(let m): return "Receiver rejected the file: \(m)"
        }
    }
}

// MARK: - Byte helpers

@inline(__always)
func be32(_ v: UInt32) -> Data {
    var x = v.bigEndian
    return Data(bytes: &x, count: 4)
}

@inline(__always)
func be64(_ v: UInt64) -> Data {
    var x = v.bigEndian
    return Data(bytes: &x, count: 8)
}

@inline(__always)
func readBE32(_ d: Data, _ i: Int) -> UInt32 {
    var v: UInt32 = 0
    _ = withUnsafeMutableBytes(of: &v) { d.copyBytes(to: $0, from: i..<(i + 4)) }
    return UInt32(bigEndian: v)
}

@inline(__always)
func readBE64(_ d: Data, _ i: Int) -> UInt64 {
    var v: UInt64 = 0
    _ = withUnsafeMutableBytes(of: &v) { d.copyBytes(to: $0, from: i..<(i + 8)) }
    return UInt64(bigEndian: v)
}

// MARK: - TCP connection

/// Blocking TCP socket with exact-length reads. Runs on background threads.
final class TCPConnection {
    private var fd: Int32 = -1

    init() {}

    deinit { close() }

    static func connect(host: String, port: UInt16, timeout: TimeInterval = 8) throws -> TCPConnection {
        let c = TCPConnection()
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw HyperSendError.socket("socket() failed") }
        c.fd = sock

        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var sndbuf: Int32 = 4 * 1024 * 1024
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw HyperSendError.socket("bad address \(host)")
        }

        // Non-blocking connect with select() timeout, then back to blocking.
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 && errno != EINPROGRESS {
            throw HyperSendError.socket("connect failed (errno \(errno))")
        }
        if rc != 0 {
            var wfds = fd_set()
            withUnsafeMutablePointer(to: &wfds) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int32.self)
                raw[Int(sock / 32)] |= Int32(1 << (sock % 32))
            }
            var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
            let sel = select(sock + 1, nil, &wfds, nil, &tv)
            if sel <= 0 { throw HyperSendError.socket("connect timed out to \(host):\(port)") }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 { throw HyperSendError.socket("connect refused (errno \(soErr))") }
        }
        _ = fcntl(sock, F_SETFL, flags)
        return c
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.send(fd, base, remaining, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    throw HyperSendError.socket("send failed (errno \(errno))")
                }
                remaining -= n
                base = base.advanced(by: n)
            }
        }
    }

    /// Read exactly `count` bytes (nil on clean EOF at a boundary).
    func readExactly(_ count: Int) throws -> Data? {
        var out = Data()
        out.reserveCapacity(count)
        var buf = [UInt8](repeating: 0, count: min(count, 65536))
        while out.count < count {
            let want = min(buf.count, count - out.count)
            let n = buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, want, 0) }
            if n == 0 { return out.isEmpty ? nil : out }
            if n < 0 {
                if errno == EINTR { continue }
                throw HyperSendError.socket("recv failed (errno \(errno))")
            }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// Read one [len][JSON] control frame.
    func readJSON() throws -> [String: Any]? {
        guard let lenData = try readExactly(4) else { return nil }
        let len = Int(readBE32(lenData, 0))
        guard len > 0, len <= 1 << 20 else {
            throw HyperSendError.protocolViolation("bad control frame length \(len)")
        }
        guard let body = try readExactly(len) else {
            throw HyperSendError.protocolViolation("truncated control frame")
        }
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw HyperSendError.protocolViolation("control frame was not a JSON object")
        }
        return obj
    }

    func writeJSON(_ obj: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: obj)
        try writeAll(be32(UInt32(body.count)) + body)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

// MARK: - Discovery (UDP beacon listener)

final class BeaconListener {
    struct Peer {
        let name: String
        let host: String
        let port: UInt16
    }

    private let magic = "hypersend-beacon-v1"
    private var fd: Int32 = -1
    private var stopped = false

    /// Binds UDP :44011 and reports the first peer seen (the receiver
    /// broadcasts "I'm here" every 500 ms).
    func findPeer(timeout: TimeInterval = 6, onFound: @escaping (Peer) -> Void) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        fd = sock
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(44011).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else {
            Darwin.close(sock)
            fd = -1
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while !stopped && Date() < deadline {
            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            var rfds = fd_set()
            withUnsafeMutablePointer(to: &rfds) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int32.self)
                raw[Int(sock / 32)] |= Int32(1 << (sock % 32))
            }
            let ready = select(sock + 1, &rfds, nil, nil, &tv)
            if ready <= 0 { continue }

            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fptr -> Int in
                fptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                    buffer.withUnsafeMutableBytes { raw in
                        Darwin.recvfrom(sock, raw.baseAddress, raw.count, 0, sptr, &fromLen)
                    }
                }
            }
            guard n > 0 else { continue }
            let data = Data(buffer[0..<n])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let m = obj["magic"] as? String, m == magic,
                  let port = obj["port"] as? Int, port > 0, port < 65536
            else { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = from.sin_addr
            inet_ntop(AF_INET, &sinAddr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
            let host = String(cString: hostBuf)
            let name = (obj["name"] as? String) ?? "device"
            onFound(Peer(name: name, host: host, port: UInt16(port)))
            return
        }
    }

    func stop() {
        stopped = true
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

// MARK: - Hashing

func sha256File(_ url: URL) throws -> String {
    let fh = try FileHandle(forReadingFrom: url)
    defer { try? fh.close() }
    var hasher = SHA256()
    while true {
        let chunk = try fh.read(upToCount: 4 * 1024 * 1024) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Engine

final class HyperSendEngine {
    static let controlPort: UInt16 = 44010
    static let chunkSize = 2 * 1024 * 1024
    /// Fixed data port on the Android receiver — makes the adb USB lane possible.
    static let usbDataPort: UInt16 = 44012

    struct LaneInfo {
        let label: String
        let host: String
        let port: UInt16
    }

    struct LaneStat {
        var bytes: Int64 = 0
        var chunks: Int = 0
    }

    struct Progress {
        let bytesDone: Int64
        let bytesTotal: Int64
        let lanes: [String: LaneStat]
        let laneCount: Int
    }

    struct Summary {
        let bytes: Int64
        let seconds: Double
        let lanes: [String: LaneStat]
        var megabytesPerSecond: Double { seconds > 0 ? Double(bytes) / 1_048_576.0 / seconds : 0 }
    }

    private let lock = NSLock()
    private var laneStats: [String: LaneStat] = [:]
    private var lanesByName: [String: LaneInfo] = [:]

    /// Send one file to `primary` (Wi-Fi) plus any extra lanes (e.g. the USB
    /// cable through adb forward). Progress is delivered on the main queue.
    func send(
        file: URL,
        primary: LaneInfo,
        extraLanes: [LaneInfo] = [],
        socketsPerLane: Int = 2,
        progress: @escaping (Progress) -> Void,
    ) throws -> Summary {
        let started = Date()
        let totalSize = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let digest = try sha256File(file)

        // ── control channel over the primary lane ─────────────────────────
        let control = try TCPConnection.connect(host: primary.host, port: primary.port)
        defer { control.close() }

        try control.writeJSON([
            "type": "hello",
            "version": 2,
            "name": "HyperSend for macOS",
            "chunkSize": Self.chunkSize,
        ])
        guard let ready = try control.readJSON(), (ready["type"] as? String) == "ready",
              let dataPort = ready["dataPort"] as? Int
        else { throw HyperSendError.protocolViolation("no ready message from receiver") }

        // ── data lanes ────────────────────────────────────────────────────
        let lanes: [LaneInfo] = [primary] + extraLanes
        var conns: [(lanes: String, host: String, port: UInt16, conn: TCPConnection)] = []
        for lane in lanes {
            // The advertised port is only valid on the primary (Wi-Fi) lane; a
            // tunnel lane carries its own fixed port.
            let port = (lane.label == primary.label) ? UInt16(dataPort) : lane.port
            for _ in 0..<socketsPerLane {
                let c = try TCPConnection.connect(host: lane.host, port: port)
                conns.append((lane.label, lane.host, port, c))
            }
        }
        defer { conns.forEach { $0.conn.close() } }

        lock.lock()
        laneStats = Dictionary(uniqueKeysWithValues: lanes.map { ($0.label, LaneStat()) })
        lanesByName = Dictionary(uniqueKeysWithValues: lanes.map { ($0.label, $0) })
        lock.unlock()

        // ── offer ─────────────────────────────────────────────────────────
        let transferId = UUID().uuidString
        try control.writeJSON([
            "type": "offer",
            "transferId": transferId,
            "path": file.lastPathComponent,
            "size": totalSize,
            "sha256": digest,
        ])
        guard let resp = try control.readJSON(),
              (resp["transferId"] as? String) == transferId,
              (resp["type"] as? String) == "offer-response"
        else { throw HyperSendError.protocolViolation("bad offer response") }

        if (resp["accept"] as? Bool) != true {
            throw HyperSendError.rejected((resp["reason"] as? String) ?? "unknown reason")
        }
        let offset = Int64((resp["offset"] as? Int) ?? 0)

        // Receiver already has the exact bytes — nothing to send.
        if offset >= totalSize {
            try control.writeJSON(["type": "file-sent", "transferId": transferId])
            guard let done = try control.readJSON(), (done["ok"] as? Bool) == true else {
                throw HyperSendError.rejected("verification failed")
            }
            try control.writeJSON(["type": "batch-done", "files": 1, "bytes": 0, "elapsedMs": 0])
            report(bytesTotal: totalSize, total: totalSize, progress: progress)
            return Summary(bytes: 0, seconds: Date().timeIntervalSince(started), lanes: snapshotLanes())
        }

        // ── chunk workers (one per connection, shared offset queue) ───────
        let fd = Darwin.open(file.path, O_RDONLY)
        guard fd >= 0 else { throw HyperSendError.fileRead("cannot open \(file.path)") }
        defer { Darwin.close(fd) }

        var nextOffset = offset
        let queueLock = NSLock()
        let chunk = Self.chunkSize
        let group = DispatchGroup()
        var firstError: Error?

        for entry in conns {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { group.leave() }
                guard let self else { return }
                while true {
                    queueLock.lock()
                    let start = nextOffset
                    if start >= totalSize {
                        queueLock.unlock()
                        return
                    }
                    nextOffset = start + Int64(chunk)
                    queueLock.unlock()

                    let length = Int(min(Int64(chunk), totalSize - start))
                    var payload = Data(count: length)
                    let read = payload.withUnsafeMutableBytes { raw -> Int in
                        Darwin.pread(fd, raw.baseAddress, length, off_t(start))
                    }
                    if read != length {
                        queueLock.lock()
                        if firstError == nil {
                            firstError = HyperSendError.fileRead("short read at \(start): \(read)/\(length)")
                        }
                        nextOffset = totalSize
                        queueLock.unlock()
                        return
                    }

                    var header = be32(UInt32(12 + length))
                    header[4] = 0x01
                    header.append(be64(UInt64(start)))
                    do {
                        try entry.conn.writeAll(header)
                        try entry.conn.writeAll(payload)
                    } catch {
                        queueLock.lock()
                        if firstError == nil { firstError = error }
                        queueLock.unlock()
                        return
                    }
                    self.record(lane: entry.lanes, bytes: Int64(length))
                    self.report(bytesTotal: totalSize, total: totalSize, progress: progress)
                }
            }
        }

        group.wait()
        if let err = firstError { throw err }

        // ── completion handshake ──────────────────────────────────────────
        try control.writeJSON(["type": "file-sent", "transferId": transferId])
        guard let done = try control.readJSON() else {
            throw HyperSendError.protocolViolation("receiver closed before verifying")
        }
        if (done["ok"] as? Bool) != true {
            throw HyperSendError.rejected((done["error"] as? String) ?? "verification failed")
        }
        let seconds = Date().timeIntervalSince(started)
        try control.writeJSON([
            "type": "batch-done",
            "files": 1,
            "bytes": totalSize - offset,
            "elapsedMs": Int(seconds * 1000),
        ])
        return Summary(bytes: totalSize - offset, seconds: seconds, lanes: snapshotLanes())
    }

    private func record(lane: String, bytes: Int64) {
        lock.lock()
        var s = laneStats[lane] ?? LaneStat()
        s.bytes += bytes
        s.chunks += 1
        laneStats[lane] = s
        lock.unlock()
    }

    private func snapshotLanes() -> [String: LaneStat] {
        lock.lock()
        defer { lock.unlock() }
        return laneStats
    }

    private var lastReport = Date.distantPast

    private func report(bytesTotal: Int64, total: Int64, progress: @escaping (Progress) -> Void) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.15 else {
            lock.unlock()
            return
        }
        lastReport = now
        let stats = laneStats
        let count = lanesByName.count
        lock.unlock()

        let done = stats.values.reduce(Int64(0)) { $0 + $1.bytes }
        let p = Progress(bytesDone: done, bytesTotal: total, lanes: stats, laneCount: count)
        DispatchQueue.main.async { progress(p) }
    }
}
