import CryptoKit
import Darwin
import Foundation

// Multipath sender.
//
// A file is a list of fixed-size chunks. One shared offset queue, one worker
// per data socket. Fast lanes simply pull more chunks — there is no scheduler
// to tune, no bandwidth estimate to get wrong, and adding a lane is just
// adding sockets. The receiver reassembles by file offset, so chunk order and
// provenance never matter.

/// One transport path into the same receiver.
struct Lane {
    let label: String
    let host: String
    /// nil = use the data port the receiver advertises (the normal Wi-Fi case).
    /// Set it when this lane is a tunnel with its own fixed port (USB via adb).
    let port: UInt16?
}

struct LaneReport {
    var bytes: Int64 = 0
    var chunks: Int = 0
    /// Bytes per second, smoothed over the transfer so far.
    var bytesPerSec: Double = 0
}

struct SendProgress {
    let fileName: String
    let fileIndex: Int
    let fileCount: Int
    let bytesDone: Int64
    let bytesTotal: Int64
    let lanes: [String: LaneReport]
    let seconds: Double

    var bytesPerSec: Double { seconds > 0 ? Double(bytesDone) / seconds : 0 }
    var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
}

struct SendSummary {
    let files: Int
    let bytes: Int64
    let seconds: Double
    let lanes: [String: LaneReport]
    var bytesPerSec: Double { seconds > 0 ? Double(bytes) / seconds : 0 }
}

/// Streaming SHA-256 — the receiver verifies this, so it is not optional.
func sha256File(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

final class SendEngine {
    // All mutable state lives behind one lock; the chunk workers hammer this
    // from several threads, so nothing here may be touched unlocked.
    private let lock = NSLock()
    private var laneStats: [String: LaneReport] = [:]
    private var transmitted: Int64 = 0
    private var lastReport = Date.distantPast
    private var runStarted = Date()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Sends `files` to one receiver over `primary` plus any `extraLanes`.
    /// Blocking — call it off the main thread.
    ///
    /// `paths` optionally overrides the destination path of each file, which is
    /// how a folder send preserves its structure (`photos/2024/a.jpg`). It must
    /// be the same length as `files` when given.
    func send(
        files: [URL],
        paths: [String]? = nil,
        primary: Lane,
        extraLanes: [Lane],
        controlPort: UInt16 = Proto.controlPort,
        socketsPerLane: Int = 2,
        progress: ((SendProgress) -> Void)? = nil,
        log: ((String) -> Void)? = nil,
    ) throws -> SendSummary {
        if let paths, paths.count != files.count {
            throw HyperSendError.protocolViolation("paths (\(paths.count)) and files (\(files.count)) disagree")
        }
        lock.lock()
        cancelled = false
        laneStats = [:]
        transmitted = 0
        lastReport = Date.distantPast
        runStarted = Date()
        lock.unlock()

        let started = runStarted
        let allLanes = [primary] + extraLanes
        for lane in allLanes { laneStats[lane.label] = LaneReport() }

        let sizes: [Int64] = files.map {
            Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let totalBytes = sizes.reduce(0, +)

        // ── control channel (always over the primary lane) ────────────────
        let control = try TCPConnection.connect(host: primary.host, port: controlPort)
        defer { control.close() }

        try control.writeJSON([
            "type": "hello",
            "version": Proto.version,
            "name": Proto.appName,
            "chunkSize": Proto.chunkSize,
        ])

        let advertisedDataPort = try awaitDataPort(control)
        log?("receiver ready · data plane :\(advertisedDataPort)")

        // ── data sockets ──────────────────────────────────────────────────
        var sockets: [(lane: String, conn: TCPConnection)] = []
        var liveLanes: [String] = []
        for lane in allLanes {
            let port = lane.port ?? advertisedDataPort
            var opened = 0
            for _ in 0 ..< max(1, socketsPerLane) {
                do {
                    sockets.append((lane.label, try TCPConnection.connect(host: lane.host, port: port)))
                    opened += 1
                } catch {
                    // A lane that will not open must not kill the transfer:
                    // losing the cable should just mean a slower send.
                    log?("lane \(lane.label) on :\(port) unavailable — \(error.localizedDescription)")
                }
            }
            if opened > 0 { liveLanes.append("\(lane.label) ×\(opened)") }
        }
        guard !sockets.isEmpty else { throw HyperSendError.socket("no data lanes could be opened") }
        defer { sockets.forEach { $0.conn.close() } }
        log?("data lanes: " + liveLanes.joined(separator: " + "))

        // ── per-file transfer ─────────────────────────────────────────────
        var filesDone = 0

        for (index, file) in files.enumerated() {
            if isCancelled { break }
            let size = sizes[index]
            let displayName = paths?[index] ?? file.lastPathComponent
            let digest = try sha256File(file)
            let transferId = UUID().uuidString

            try control.writeJSON([
                "type": "offer",
                "transferId": transferId,
                "path": displayName,
                "size": size,
                "sha256": digest,
            ])

            let offset = try awaitOfferResponse(control, transferId: transferId, size: size)
            if offset > 0 { log?("resuming \(displayName) at \(formattedBytes(offset))") }

            if size > offset && !isCancelled {
                try pumpChunks(
                    file: file,
                    displayName: displayName,
                    from: offset,
                    size: size,
                    sockets: sockets,
                    fileIndex: index + 1,
                    fileCount: files.count,
                    bytesTotal: totalBytes,
                    progress: progress,
                )
            }

            try control.writeJSON(["type": "file-sent", "transferId": transferId])
            try awaitFileDone(control, transferId: transferId)

            filesDone += 1
            log?("verified \(displayName) · sha256 ok")
            emit(
                fileName: displayName,
                fileIndex: index + 1,
                fileCount: files.count,
                bytesTotal: totalBytes,
                started: started,
                progress: progress,
                force: true,
            )
        }

        let seconds = Date().timeIntervalSince(started)
        try control.writeJSON([
            "type": "batch-done",
            "files": filesDone,
            "bytes": transmitted,
            "elapsedMs": Int(seconds * 1000),
        ])

        return SendSummary(files: filesDone, bytes: transmitted, seconds: seconds, lanes: snapshot(seconds: seconds))
    }

    // MARK: - Control handshakes

    private func awaitDataPort(_ control: TCPConnection) throws -> UInt16 {
        let deadline = Date().addingTimeInterval(15)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw HyperSendError.timedOut("receiver did not answer hello") }
            guard let msg = try control.readJSON(timeoutMs: Int32(remaining * 1000)) else {
                throw HyperSendError.protocolViolation("receiver closed before ready")
            }
            switch msg["type"] as? String {
            case "ready":
                guard let port = msg["dataPort"] as? Int, port > 0, port < 65536 else {
                    throw HyperSendError.protocolViolation("receiver advertised a bad data port")
                }
                return UInt16(port)
            case "error":
                throw HyperSendError.rejected((msg["message"] as? String) ?? "receiver error")
            default:
                continue
            }
        }
    }

    private func awaitOfferResponse(_ control: TCPConnection, transferId: String, size: Int64) throws -> Int64 {
        // Generous on purpose: a receiver with automatic acceptance turned off
        // puts this offer in front of a *person*, and the answer takes as long
        // as a person takes. Mirrored by AppModel.acceptPromptTimeout.
        let deadline = Date().addingTimeInterval(120)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw HyperSendError.timedOut("no offer-response") }
            guard let msg = try control.readJSON(timeoutMs: Int32(remaining * 1000)) else {
                throw HyperSendError.protocolViolation("receiver closed during offer")
            }
            guard (msg["transferId"] as? String) == transferId else { continue }
            switch msg["type"] as? String {
            case "offer-response":
                if (msg["accept"] as? Bool) != true {
                    throw HyperSendError.rejected((msg["reason"] as? String) ?? "declined by receiver")
                }
                return min(max(Int64((msg["offset"] as? Int) ?? 0), 0), size)
            case "error":
                throw HyperSendError.rejected((msg["message"] as? String) ?? "receiver error")
            default:
                continue
            }
        }
    }

    private func awaitFileDone(_ control: TCPConnection, transferId: String) throws {
        // The receiver hashes the whole file on disk before answering, so this
        // window is generous.
        let deadline = Date().addingTimeInterval(900)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw HyperSendError.timedOut("receiver did not verify the file") }
            guard let msg = try control.readJSON(timeoutMs: Int32(remaining * 1000)) else {
                throw HyperSendError.protocolViolation("receiver closed before verifying")
            }
            guard (msg["transferId"] as? String) == transferId else { continue }
            switch msg["type"] as? String {
            case "file-done":
                if (msg["ok"] as? Bool) != true {
                    throw HyperSendError.rejected((msg["error"] as? String) ?? "verification failed")
                }
                return
            case "error":
                throw HyperSendError.rejected((msg["message"] as? String) ?? "receiver error")
            default:
                continue
            }
        }
    }

    // MARK: - Chunk pump

    private func pumpChunks(
        file: URL,
        displayName: String,
        from startOffset: Int64,
        size: Int64,
        sockets: [(lane: String, conn: TCPConnection)],
        fileIndex: Int,
        fileCount: Int,
        bytesTotal: Int64,
        progress: ((SendProgress) -> Void)?,
    ) throws {
        let fd = Darwin.open(file.path, O_RDONLY)
        guard fd >= 0 else { throw HyperSendError.fileRead("cannot open \(file.path)") }
        defer { Darwin.close(fd) }

        let queueLock = NSLock()
        var nextOffset = startOffset
        var firstError: Error?

        let group = DispatchGroup()
        let chunkSize = Proto.chunkSize
        let name = displayName

        for entry in sockets {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { group.leave() }
                while true {
                    if isCancelled { return }

                    queueLock.lock()
                    if nextOffset >= size {
                        queueLock.unlock()
                        return
                    }
                    let start = nextOffset
                    nextOffset = start + Int64(chunkSize)
                    queueLock.unlock()

                    let length = Int(min(Int64(chunkSize), size - start))
                    var payload = Data(count: length)
                    let read = payload.withUnsafeMutableBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return -1 }
                        var got = 0
                        while got < length {
                            let n = Darwin.pread(fd, base.advanced(by: got), length - got, off_t(start + Int64(got)))
                            if n <= 0 { break }
                            got += n
                        }
                        return got
                    }
                    guard read == length else {
                        queueLock.lock()
                        if firstError == nil {
                            firstError = HyperSendError.fileRead("short read at \(start) (\(read)/\(length))")
                        }
                        queueLock.unlock()
                        return
                    }

                    // Length field covers flags + offset + payload, i.e. 9 + n.
                    // Built with append(), never subscript-assignment: writing
                    // at endIndex on a Data traps instead of appending.
                    var frame = Data(capacity: Proto.chunkHeaderBytes + length)
                    frame.append(be32(UInt32(Proto.chunkHeaderBytes - 4 + length)))
                    frame.append(0x01)
                    frame.append(be64(UInt64(start)))

                    do {
                        try entry.conn.writeAll(frame)
                        try entry.conn.writeAll(payload)
                    } catch {
                        queueLock.lock()
                        if firstError == nil { firstError = error }
                        queueLock.unlock()
                        return
                    }

                    record(lane: entry.lane, bytes: Int64(length))
                    emit(
                        fileName: name,
                        fileIndex: fileIndex,
                        fileCount: fileCount,
                        bytesTotal: bytesTotal,
                        started: nil,
                        progress: progress,
                        force: false,
                    )
                }
            }
        }

        group.wait()
        if let error = firstError { throw error }
    }

    // MARK: - Stats & reporting

    private func record(lane: String, bytes: Int64) {
        lock.lock()
        var stat = laneStats[lane] ?? LaneReport()
        stat.bytes += bytes
        stat.chunks += 1
        laneStats[lane] = stat
        transmitted += bytes
        lock.unlock()
    }

    private func snapshot(seconds: Double) -> [String: LaneReport] {
        lock.lock()
        defer { lock.unlock() }
        var out = laneStats
        for key in out.keys {
            let bytes = out[key]?.bytes ?? 0
            out[key]?.bytesPerSec = seconds > 0 ? Double(bytes) / seconds : 0
        }
        return out
    }

    /// Throttled to ~8 Hz unless `force` (end of a file).
    private func emit(
        fileName: String,
        fileIndex: Int,
        fileCount: Int,
        bytesTotal: Int64,
        started: Date?,
        progress: ((SendProgress) -> Void)?,
        force: Bool,
    ) {
        guard let progress else { return }
        lock.lock()
        let now = Date()
        if !force, now.timeIntervalSince(lastReport) < 0.125 {
            lock.unlock()
            return
        }
        lastReport = now
        let stats = laneStats
        let done = transmitted
        let elapsed = now.timeIntervalSince(started ?? runStarted)
        lock.unlock()

        progress(SendProgress(
            fileName: fileName,
            fileIndex: fileIndex,
            fileCount: fileCount,
            bytesDone: done,
            bytesTotal: bytesTotal,
            lanes: stats,
            seconds: elapsed,
        ))
    }
}
