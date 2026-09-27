import Darwin
import Foundation

// HyperSend wire protocol v2 — must stay byte-identical to src/protocol.ts and
// the Android app's Protocol.kt.
//
//   control : [4-byte BE length][JSON]                     over TCP :44010
//   data    : [4-byte BE length][1-byte flags][8-byte BE offset][payload]
//                                                          over TCP :44012
//   beacon  : UDP :44011, JSON {magic, port, name}
//
// The 13-byte data header is what makes multipath trivial: the receiver places
// each payload at its file offset, so chunks may arrive on any socket, in any
// order, from any number of transports.

enum Proto {
    static let version = 2
    static let controlPort: UInt16 = 44010
    static let discoveryPort: UInt16 = 44011
    /// Fixed on purpose: a stable port is what lets `adb forward` give the USB
    /// cable a lane of its own.
    static let usbDataPort: UInt16 = 44012
    /// Local side of the adb tunnel. Deliberately different from `usbDataPort`
    /// so this Mac can *receive* on 44012 while also *sending* over the cable:
    /// adb forwards 127.0.0.1:44013 → phone:44012, and a local receiver binding
    /// 44012 never collides with it.
    static let usbLocalPort: UInt16 = 44013
    /// Phone→Mac cable direction: `adb reverse tcp:44014 tcp:44012` lets the
    /// PHONE dial 127.0.0.1:44014 and land on this Mac's data plane :44012.
    /// Distinct from usbLocalPort because the two tunnels point opposite ways
    /// and must not collide in adb's tables.
    static let usbReverseLocalPort: UInt16 = 44014
    static let chunkSize = 2 * 1024 * 1024
    static let chunkHeaderBytes = 13
    static let maxControlBytes = 1 << 20
    static let magic = "hypersend-beacon-v1"
    static let appName = "HyperSend"
}

enum HyperSendError: Error, LocalizedError {
    case socket(String)
    case protocolViolation(String)
    case fileRead(String)
    case fileWrite(String)
    case rejected(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .socket(let m): return "Network: \(m)"
        case .protocolViolation(let m): return "Protocol: \(m)"
        case .fileRead(let m): return "Read: \(m)"
        case .fileWrite(let m): return "Write: \(m)"
        case .rejected(let m): return "Rejected: \(m)"
        case .timedOut(let m): return "Timeout: \(m)"
        }
    }
}

// MARK: - Big-endian helpers

@inline(__always) func be32(_ v: UInt32) -> Data {
    var x = v.bigEndian
    return Data(bytes: &x, count: 4)
}

@inline(__always) func be64(_ v: UInt64) -> Data {
    var x = v.bigEndian
    return Data(bytes: &x, count: 8)
}

extension Data {
    // Byte-at-a-time on purpose: Data slices have their own index space, so a
    // plain subscript is the only safe read without copying first.
    @inline(__always) func be32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return (UInt32(self[base]) << 24)
            | (UInt32(self[base + 1]) << 16)
            | (UInt32(self[base + 2]) << 8)
            | UInt32(self[base + 3])
    }

    @inline(__always) func be64(at offset: Int) -> UInt64 {
        let base = startIndex + offset
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value = (value << 8) | UInt64(self[base + index])
        }
        return value
    }
}

// MARK: - select() helpers

@inline(__always) func fdBit(_ fd: Int32, _ set: inout fd_set) {
    withUnsafeMutablePointer(to: &set) { p in
        let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: Int32.self)
        raw[Int(fd) / 32] |= Int32(1) << Int32(fd % 32)
    }
}

/// True when `fd` is readable within `timeoutMs`.
func waitReadable(_ fd: Int32, timeoutMs: Int32) -> Bool {
    var set = fd_set()
    fdBit(fd, &set)
    var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: Int32((timeoutMs % 1000) * 1000))
    return select(fd + 1, &set, nil, nil, &tv) > 0
}

func waitWritable(_ fd: Int32, timeoutMs: Int32) -> Bool {
    var set = fd_set()
    fdBit(fd, &set)
    var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: Int32((timeoutMs % 1000) * 1000))
    return select(fd + 1, nil, &set, nil, &tv) > 0
}

// MARK: - Buffered reader over a raw fd

/// Byte-accurate buffered reader. One per data-plane socket.
final class ByteReader {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var eof = false
    private let readChunk = 256 * 1024

    init(fd: Int32) {
        self.fd = fd
    }

    var available: Int { buffer.count - cursor }

    private func fill() -> Bool {
        if eof { return false }
        var tmp = [UInt8](repeating: 0, count: readChunk)
        while true {
            let n = tmp.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, readChunk, 0) }
            if n > 0 {
                if cursor > 0 {
                    buffer.removeFirst(cursor)
                    cursor = 0
                }
                buffer.append(contentsOf: tmp[0 ..< n])
                return true
            }
            if n == 0 {
                eof = true
                return false
            }
            if errno == EINTR { continue }
            eof = true
            return false
        }
    }

    /// Reads exactly `n` bytes, or nil on clean EOF at a message boundary.
    func readExactly(_ n: Int) throws -> Data? {
        while available < n {
            if !fill() {
                if available == 0 { return nil }
                throw HyperSendError.protocolViolation("stream ended mid-message (\(available)/\(n) bytes)")
            }
        }
        let out = Data(buffer[cursor ..< cursor + n])
        cursor += n
        if cursor == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            cursor = 0
        }
        return out
    }

    /// Reads one v2 chunk header. Returns nil at a clean EOF.
    func readChunkHeader() throws -> (payloadBytes: Int, offset: Int64)? {
        guard let head = try readExactly(Proto.chunkHeaderBytes) else { return nil }
        let len = Int(head.be32(at: 0))
        let flags = head[4]
        guard flags & 0x01 != 0 else {
            throw HyperSendError.protocolViolation("chunk is not v2 (flags \(flags))")
        }
        guard len >= Proto.chunkHeaderBytes - 4, len <= 64 * 1024 * 1024 else {
            throw HyperSendError.protocolViolation("bad chunk length \(len)")
        }
        return (len - (Proto.chunkHeaderBytes - 4), Int64(bitPattern: head.be64(at: 5)))
    }
}

// MARK: - TCP connection

/// Blocking TCP socket with exact-length reads and optional read timeouts.
final class TCPConnection {
    private(set) var fd: Int32

    init(fd: Int32) {
        self.fd = fd
        tune()
    }

    deinit { close() }

    private func tune() {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var snd: Int32 = 4 * 1024 * 1024
        var rcv: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
    }

    static func connect(host: String, port: UInt16, timeoutMs: Int32 = 8000) throws -> TCPConnection {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw HyperSendError.socket("socket() failed") }

        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var snd: Int32 = 4 * 1024 * 1024
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(sock)
            throw HyperSendError.socket("not an IPv4 address: \(host)")
        }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            if errno != EINPROGRESS {
                let e = errno
                Darwin.close(sock)
                throw HyperSendError.socket("connect \(host):\(port) failed (errno \(e))")
            }
            guard waitWritable(sock, timeoutMs: timeoutMs) else {
                Darwin.close(sock)
                throw HyperSendError.timedOut("connect \(host):\(port)")
            }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 {
                Darwin.close(sock)
                throw HyperSendError.socket("connect \(host):\(port) refused (errno \(soErr))")
            }
        }
        _ = fcntl(sock, F_SETFL, flags)
        return TCPConnection(fd: sock)
    }

    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.send(fd, base, remaining, 0)
                if n > 0 {
                    remaining -= n
                    base = base.advanced(by: n)
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    _ = waitWritable(fd, timeoutMs: 30_000)
                    continue
                }
                throw HyperSendError.socket("send failed (errno \(errno))")
            }
        }
    }

    func writeJSON(_ obj: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: obj)
        try writeAll(be32(UInt32(body.count)) + body)
    }

    /// Read one [len][JSON] control frame. `timeoutMs < 0` blocks forever.
    func readJSON(timeoutMs: Int32 = -1) throws -> [String: Any]? {
        if timeoutMs >= 0, !waitReadable(fd, timeoutMs: timeoutMs) {
            throw HyperSendError.timedOut("waiting for control message")
        }
        guard let lenData = try readExactly(4) else { return nil }
        let len = Int(lenData.be32(at: 0))
        guard len > 0, len <= Proto.maxControlBytes else {
            throw HyperSendError.protocolViolation("bad control frame length \(len)")
        }
        guard let body = try readExactly(len) else {
            throw HyperSendError.protocolViolation("truncated control frame")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw HyperSendError.protocolViolation("control frame was not a JSON object")
        }
        return obj
    }

    private func readExactly(_ count: Int) throws -> Data? {
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
            out.append(contentsOf: buf[0 ..< n])
        }
        return out
    }

    /// Confirms a socket is actually accepting connections (used to probe the
    /// USB tunnel lane before we promise the user a second path).
    static func probe(host: String, port: UInt16, timeoutMs: Int32 = 700) -> Bool {
        (try? connect(host: host, port: port, timeoutMs: timeoutMs)) != nil
    }

    // MARK: Dual-stack addressing

    /// Every address of `host` in the best-first order the app agrees on:
    /// global v6 > IPv4 > v6 ULA > v6 link-local > loopback. Hostnames are
    /// resolved here; literals pass through untouched.
    static func addressCandidates(host: String) -> [String] {
        var out: [String] = []
        for family in [AF_INET6, AF_INET] {
            var hints = addrinfo()
            hints.ai_family = family
            var info: UnsafeMutablePointer<addrinfo>?
            let rc = getaddrinfo(host, nil, &hints, &info)
            defer { if let info { freeaddrinfo(info) } }
            guard rc == 0, let info else { continue }
            var cursor: UnsafeMutablePointer<addrinfo>? = info
            while let ai = cursor {
                if ai.pointee.ai_addrlen > 0, let sa = ai.pointee.ai_addr {
                    var storage = sockaddr_storage()
                    memcpy(&storage, sa, min(MemoryLayout<sockaddr_storage>.size, Int(ai.pointee.ai_addrlen)))
                    if let text = describeAddress(storage) {
                        out.append(text)
                    }
                }
                cursor = ai.pointee.ai_next
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Parses an address literal into sockaddr_storage (v4 or v6).
    static func resolveNumeric(_ host: String) -> sockaddr_storage? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            var sa = sockaddr_in()
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_addr = v4
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            var storage = sockaddr_storage()
            memcpy(&storage, &sa, MemoryLayout<sockaddr_in>.size)
            storage.ss_family = sa_family_t(AF_INET)
            return storage
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            var sa = sockaddr_in6()
            sa.sin6_family = sa_family_t(AF_INET6)
            sa.sin6_addr = v6
            sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            var storage = sockaddr_storage()
            memcpy(&storage, &sa, MemoryLayout<sockaddr_in6>.size)
            storage.ss_family = sa_family_t(AF_INET6)
            return storage
        }
        return nil
    }

    /// inet_ntop over either family.
    static func describeAddress(_ sa: sockaddr_storage) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: sa) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(sa.ss_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard rc == 0 else { return nil }
        let text = String(cString: host)
        // getnameinfo renders mapped v4 as ::ffff:a.b.c.d — show plain v4.
        if text.hasPrefix("::ffff:") { return String(text.dropFirst(7)) }
        return text
    }

    /// Rank: global v6 first, IPv4 next, then ULA, link-local, loopback.
    static func addressRank(_ text: String) -> Int {
        if text.contains(":") {
            let lower = text.lowercased()
            if lower == "::1" { return 4 }
            if lower.hasPrefix("fe80") { return 3 }
            if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return 2 }
            return 0 // global v6
        }
        if text == "127.0.0.1" { return 4 }
        return 1
    }

    ///
    /// Dual-stack connect. Resolves `host` to ALL its addresses (both
    /// families), ranks them best-first, and walks them with a shared time
    /// budget — a dead AAAA costs a slice, never the transfer. `connect`'s
    /// literal-IPv4 fast path is unchanged for the tunnel lanes.
    ///
    static func connectBest(host: String, port: UInt16, timeoutMs: Int32 = 8000) throws -> TCPConnection {
        var candidates = addressCandidates(host: host)
        if candidates.isEmpty {
            // Hostname resolved to nothing (or no DNS): try it as a literal.
            candidates = [host]
        }
        let ranked = candidates.sorted { addressRank($0) < addressRank($1) }
        let perAddress = max(750, Int(timeoutMs) / max(1, ranked.count))
        var lastError: Error = HyperSendError.socket("no addresses for \(host)")
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)

        for candidate in ranked {
            guard Date() < deadline else { break }
            guard let storage = resolveNumeric(candidate) else { continue }
            do {
                return try connect(storage: storage, host: candidate, port: port, timeoutMs: Int32(perAddress))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }    /// One connect attempt against a prepared sockaddr (either family).
    static func connect(storage: sockaddr_storage, host: String, port: UInt16, timeoutMs: Int32) throws -> TCPConnection {
        var addr = storage
        // The port lives at bytes 2–3 in both sockaddr_in and sockaddr_in6,
        // and resolveNumeric leaves it zero — stamp it in here.
        withUnsafeMutableBytes(of: &addr) { raw in
            raw[2] = UInt8(port >> 8)
            raw[3] = UInt8(port & 0xFF)
        }
        let family = Int32(addr.ss_family)
        let sock = socket(family, SOCK_STREAM, 0)
        guard sock >= 0 else { throw HyperSendError.socket("socket() failed")
 }

        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var snd: Int32 = 4 * 1024 * 1024
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        let addrLen = addr.ss_len
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(addrLen))
            }
        }
        if rc != 0 {
            if errno != EINPROGRESS {
                let e = errno
                Darwin.close(sock)
                throw HyperSendError.socket("connect \(host):\(port) failed (errno \(e))")
            }
            guard waitWritable(sock, timeoutMs: timeoutMs) else {
                Darwin.close(sock)
                throw HyperSendError.timedOut("connect \(host):\(port)")
            }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 {
                Darwin.close(sock)
                throw HyperSendError.socket("connect \(host):\(port) refused (errno \(soErr))")
            }
        }
        _ = fcntl(sock, F_SETFL, flags)
        return TCPConnection(fd: sock)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

// MARK: - TCP server

/// Minimal listening socket with a select-based accept so callers can poll.
final class TCPServer {
    private(set) var fd: Int32 = -1
    let port: UInt16

    init(port: UInt16, backlog: Int32 = 64) throws {
        self.port = port
        // Dual-stack by preference: one socket on :: with IPV6_V6ONLY off
        // accepts IPv6 AND IPv4 (v4 arrives as ::ffff:a.b.c.d mapped). The
        // kernel does the mapping, so every existing IPv4 client — adb
        // tunnels, loopback tests, the Node engine — behaves identically.
        // Any failure falls back to the plain IPv4 bind, the historical path.
        if let dual = try? TCPServer.makeDualStack(port: port, backlog: backlog) {
            fd = dual
            return
        }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw HyperSendError.socket("socket() failed") }

        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(sock)
            throw HyperSendError.socket("bind :\(port) failed (errno \(e))")
        }
        guard Darwin.listen(sock, backlog) == 0 else {
            Darwin.close(sock)
            throw HyperSendError.socket("listen :\(port) failed")
        }
        fd = sock
    }

    /// Binds [::]:port with v6ONLY off. Returns the fd, or nil when the host
    /// has no IPv6 support at all (rare on macOS).
    private static func makeDualStack(port: UInt16, backlog: Int32) -> Int32? {
        let sock = socket(AF_INET6, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }

        var one: Int32 = 1
        var zero: Int32 = 0
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // The whole point: keep v4-mapped addresses flowing through this one
        // listener. Without this the v4 clients above would find the port dark.
        setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(sock)
            return nil
        }
        guard Darwin.listen(sock, backlog) == 0 else {
            Darwin.close(sock)
            return nil
        }
        return sock
    }

    /// The port actually bound — resolves ephemeral (:0) listeners. Port sits
    /// at bytes 2–3 of both sockaddr_in and sockaddr_in6, so one read covers
    /// both families.
    var boundPort: UInt16 {
        guard fd >= 0 else { return port }
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &ss) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { return port }
        return withUnsafeBytes(of: &ss) { raw in
            UInt16(raw[2]) << 8 | UInt16(raw[3])
        }
    }

    /// Accepts one client, waiting at most `timeoutMs`. Returns a tuned
    /// connection ready for use.
    func accept(timeoutMs: Int32 = 500) throws -> TCPConnection? {
        guard fd >= 0 else { return nil }
        guard waitReadable(fd, timeoutMs: timeoutMs) else { return nil }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(fd, $0, &len)
            }
        }
        guard client >= 0 else { return nil }
        return TCPConnection(fd: client)
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

// MARK: - Path safety

/// Receiver-side path sanitisation — the only place remote strings become
/// filesystem paths. Mirrors sanitizeRelativePath() in src/protocol.ts.
func sanitizeRelativePath(_ input: String) throws -> String {
    guard !input.isEmpty, input.count <= 512 else {
        throw HyperSendError.protocolViolation("invalid path length")
    }
    let normalised = input.replacingOccurrences(of: "\\", with: "/")
    let parts = normalised.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    for part in parts where part.isEmpty || part == "." || part == ".." || part.contains("\0") {
        throw HyperSendError.protocolViolation("unsafe path segment \(part.debugDescription)")
    }
    let joined = parts.joined(separator: "/")
    if joined.hasPrefix("/") || joined.range(of: "^[A-Za-z]:", options: .regularExpression) != nil {
        throw HyperSendError.protocolViolation("absolute paths are not allowed")
    }
    return joined
}
