import Darwin
import Foundation

// Device discovery: a UDP beacon on :44011 carrying {magic, port, name}.
// The receiver broadcasts "I'm here" every 500 ms; anyone listening can
// connect back without typing IP addresses. Deliberately dumb — it is a LAN
// protocol, not a service registry.

struct Peer: Equatable {
    var name: String
    var host: String
    var port: UInt16
    var lastSeen: Date
    /// True when this peer is also reachable over the adb USB tunnel.
    var usbReachable: Bool = false

    var displayAddress: String { "\(host):\(port)" }
}

/// Blocking one-shot beacon sniff. Headless mode has no run loop to drive the
/// listener's main-queue callbacks, so it reads the socket directly.
func sniffPeer(timeout: TimeInterval) -> Peer? {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else { return nil }
    defer { Darwin.close(sock) }
    var one: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = Proto.discoveryPort.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return nil }

    let deadline = Date().addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 2048)
    while Date() < deadline {
        guard waitReadable(sock, timeoutMs: 500) else { continue }
        var from = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { fp in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                buffer.withUnsafeMutableBytes { raw in
                    Darwin.recvfrom(sock, raw.baseAddress, raw.count, 0, sp, &fromLen)
                }
            }
        }
        guard n > 0 else { continue }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer[0 ..< n])) as? [String: Any],
              let magic = obj["magic"] as? String, magic == Proto.magic,
              let port = obj["port"] as? Int, port > 0, port < 65536
        else { continue }
        var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sinAddr = from.sin_addr
        inet_ntop(AF_INET, &sinAddr, &hostBuf, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: hostBuf)
        guard !host.isEmpty, host != "0.0.0.0" else { continue }
        return Peer(name: (obj["name"] as? String) ?? "device", host: host, port: UInt16(port), lastSeen: Date())
    }
    return nil
}

/// Local IPv4 addresses, so the UI can tell the user how to reach this Mac.
func localIPv4Addresses() -> [(interface: String, address: String)] {
    var results: [(String, String)] = []
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let current = cursor {
        defer { cursor = current.pointee.ifa_next }
        guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = Int32(current.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        let name = String(cString: current.pointee.ifa_name)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard rc == 0 else { continue }
        let address = String(cString: host)
        guard !address.isEmpty else { continue }
        results.append((name, address))
    }
    return results
}

/// Sends the beacon so other HyperSend instances can find this machine.
final class BeaconBroadcaster {
    private let port: UInt16
    private let payloadPort: UInt16
    private let name: String
    private var fd: Int32 = -1
    private var stopped = false
    private var thread: Thread?

    init(controlPort: UInt16, name: String) {
        self.payloadPort = controlPort
        self.name = name
        self.port = Proto.discoveryPort
    }

    func start() {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        fd = sock
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        let t = Thread { [weak self] in self?.loop() }
        t.name = "hypersend.beacon.tx"
        t.stackSize = 256 * 1024
        thread = t
        t.start()
    }

    private func loop() {
        let body: Data = (try? JSONSerialization.data(withJSONObject: [
            "magic": Proto.magic,
            "port": Int(payloadPort),
            "name": name,
            "version": Proto.version,
        ])) ?? Data()

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        // Global 255.255.255.255 is filtered by many hotspots and APs; a
        // subnet-directed broadcast (a.b.c.255) usually survives. Recompute
        // periodically so a network change is picked up mid-session.
        var directed = directedBroadcastAddresses()
        var ticks = 0

        while !stopped {
            var targets: [UInt32] = [INADDR_BROADCAST] + directed
            // Loopback copy so two instances on one Mac can still see each
            // other (useful for testing the engine against itself).
            targets.append(UInt32(INADDR_LOOPBACK).bigEndian)

            for target in targets {
                addr.sin_addr.s_addr = target
                body.withUnsafeBytes { raw in
                    _ = withUnsafePointer(to: &addr) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            Darwin.sendto(fd, raw.baseAddress, raw.count, 0, sa,
                                          socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }

            ticks += 1
            if ticks % 40 == 0 { directed = directedBroadcastAddresses() }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// a.b.c.255 for every local IPv4 subnet this Mac sits on (/24 assumed;
    /// good enough for home and hotspot networks, which is where this runs).
    private func directedBroadcastAddresses() -> [UInt32] {
        localIPv4Addresses().compactMap { _, address -> UInt32? in
            var addr = in_addr()
            guard inet_pton(AF_INET, address, &addr) == 1 else { return nil }
            let host = CFSwapInt32BigToHost(addr.s_addr)
            guard host != 0 else { return nil }
            return CFSwapInt32HostToBig((host & 0xFFFF_FF00) | 0xFF)
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

/// Listens for beacons and keeps an up-to-date peer table.
final class BeaconListener {
    private var fd: Int32 = -1
    private var stopped = false
    private var thread: Thread?
    private let onPeers: ([Peer]) -> Void
    private var peers: [String: Peer] = [:]

    init(onPeers: @escaping ([Peer]) -> Void) {
        self.onPeers = onPeers
    }

    func start() {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        fd = sock
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Proto.discoveryPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(sock)
            fd = -1
            return
        }

        let t = Thread { [weak self] in self?.loop() }
        t.name = "hypersend.beacon.rx"
        t.stackSize = 256 * 1024
        thread = t
        t.start()
    }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while !stopped {
            guard waitReadable(fd, timeoutMs: 500) else {
                expire()
                continue
            }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    buffer.withUnsafeMutableBytes { raw in
                        Darwin.recvfrom(fd, raw.baseAddress, raw.count, 0, sp, &fromLen)
                    }
                }
            }
            guard n > 0 else { continue }
            let data = Data(buffer[0 ..< n])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let magic = obj["magic"] as? String, magic == Proto.magic,
                  let port = obj["port"] as? Int, port > 0, port < 65536
            else { continue }

            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = from.sin_addr
            inet_ntop(AF_INET, &sinAddr, &host, socklen_t(INET_ADDRSTRLEN))
            let address = String(cString: host)
            guard !address.isEmpty, address != "0.0.0.0" else { continue }

            let name = (obj["name"] as? String) ?? "Unknown device"
            let key = "\(name)@\(address)"
            peers[key] = Peer(name: name, host: address, port: UInt16(port), lastSeen: Date())
            publish()
        }
    }

    /// Peers that stop broadcasting (e.g. app closed) drop off after 6 s.
    private func expire() {
        let cutoff = Date().addingTimeInterval(-6)
        let before = peers.count
        peers = peers.filter { $0.value.lastSeen > cutoff }
        if peers.count != before {
            publish()
        }
    }

    private func publish() {
        let snapshot = peers.values.sorted { $0.name < $1.name }
        DispatchQueue.main.async { [onPeers] in onPeers(snapshot) }
    }

    func stop() {
        stopped = true
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}
