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

            // IPv6 twin: ff02::1 on every multicast-capable interface. Purely
            // additive — v4 receivers never see these packets.
            sendV6Multicast(body)

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

    /// One ff02::1 copy per multicast v6 interface, each scoped by if_index.
    /// Best-effort: an interface without v6 connectivity just doesn't send.
    private func sendV6Multicast(_ payload: Data) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return }
        defer { freeifaddrs(head) }

        var v6Addr = sockaddr_in6()
        v6Addr.sin6_family = sa_family_t(AF_INET6)
        v6Addr.sin6_port = port.bigEndian
        v6Addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        inet_pton(AF_INET6, "ff02::1", &v6Addr.sin6_addr)

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var seenIndexes = Set<UInt32>()
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET6),
                  (Int32(current.pointee.ifa_flags) & IFF_UP) != 0,
                  (Int32(current.pointee.ifa_flags) & IFF_LOOPBACK) == 0,
                  (Int32(current.pointee.ifa_flags) & IFF_MULTICAST) != 0
            else { continue }
            let index = if_nametoindex(current.pointee.ifa_name)
            guard index != 0, !seenIndexes.contains(index) else { continue }
            seenIndexes.insert(index)

            v6Addr.sin6_scope_id = index
            payload.withUnsafeBytes { raw in
                withUnsafePointer(to: &v6Addr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = sendto(fd, raw.baseAddress, raw.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
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
    private var fd6: Int32 = -1

    init(onPeers: @escaping ([Peer]) -> Void) {
        self.onPeers = onPeers
    }

    func start() {
        // IPv4 socket — the historical path, unchanged.
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

        // IPv6 socket — additive. Hears ff02::1 beacons from v6 speakers
        // (phone or Mac). Absent when the host has no v6 at all.
        let sock6 = socket(AF_INET6, SOCK_DGRAM, 0)
        if sock6 >= 0 {
            var one6: Int32 = 1
            var v6only: Int32 = 1
            setsockopt(sock6, SOL_SOCKET, SO_REUSEADDR, &one6, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sock6, SOL_SOCKET, SO_REUSEPORT, &one6, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sock6, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
            var addr6 = sockaddr_in6()
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = Proto.discoveryPort.bigEndian
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            let rc6 = withUnsafePointer(to: &addr6) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sock6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if rc6 == 0 {
                var group = ipv6_mreq()
                _ = inet_pton(AF_INET6, "ff02::1", &group.ipv6mr_multiaddr)
                group.ipv6mr_interface = 0 // every interface
                _ = setsockopt(sock6, IPPROTO_IPV6, IPV6_JOIN_GROUP, &group, socklen_t(MemoryLayout<ipv6_mreq>.size))
                fd6 = sock6
            } else {
                Darwin.close(sock6)
            }
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
            var ready = false
            if fd >= 0, waitReadable(fd, timeoutMs: 250) {
                ready = true
                if let peer = readBeacon(fd, buffer: &buffer) {
                    record(peer)
                    publish()
                }
            }
            if fd6 >= 0, waitReadable(fd6, timeoutMs: 250) {
                ready = true
                if let peer = readBeacon(fd6, buffer: &buffer) {
                    record(peer)
                    publish()
                }
            }
            if !ready { expire() }
        }
    }

    /// One device, one entry. A dual-stack peer arrives on BOTH families;
    /// keying by name keeps it a single row, and the address only moves when
    /// the new one ranks better (global v6 > v4 > link-local) so the row does
    /// not flicker between families every 500 ms.
    private func record(_ peer: Peer) {
        if var existing = peers[peer.name] {
            existing.lastSeen = peer.lastSeen
            if TCPConnection.addressRank(peer.host) < TCPConnection.addressRank(existing.host) {
                existing.host = peer.host
                existing.port = peer.port
            }
            peers[peer.name] = existing
        } else {
            peers[peer.name] = peer
        }
    }

    /// Reads one beacon from either family's socket; nil on timeout/EAGAIN.
    private func readBeacon(_ socketFd: Int32, buffer: inout [UInt8]) -> Peer? {
        var from = sockaddr_storage()
        var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from) { fp in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                buffer.withUnsafeMutableBytes { raw in
                    Darwin.recvfrom(socketFd, raw.baseAddress, raw.count, 0, sp, &fromLen)
                }
            }
        }
        guard n > 0 else { return nil }
        let data = Data(buffer[0 ..< n])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let magic = obj["magic"] as? String, magic == Proto.magic,
              let port = obj["port"] as? Int, port > 0, port < 65536
        else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafeMutablePointer(to: &from) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, fromLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard rc == 0 else { return nil }
        var address = String(cString: host)
        if address.hasPrefix("::ffff:") { address = String(address.dropFirst(7)) }
        guard !address.isEmpty, address != "0.0.0.0" else { return nil }

        let name = (obj["name"] as? String) ?? "Unknown device"
        return Peer(name: name, host: address, port: UInt16(port), lastSeen: Date())
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
        if fd6 >= 0 {
            Darwin.close(fd6)
            fd6 = -1
        }
    }
}
