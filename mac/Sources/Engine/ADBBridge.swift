import Foundation

// The USB lane, without writing a driver.
//
// The phone's USB tethering is RNDIS, which macOS cannot talk to at all (no
// RNDIS driver ships, and one cannot be installed without a kext). But the
// cable is still a usable transport: `adb forward tcp:44012 tcp:44012` turns
// the Mac's loopback port 44012 into a TCP tunnel that terminates *inside* the
// phone. The receiver binds a FIXED data port precisely so that tunnel can
// exist — that is what gives the cable its own lane in the multipath pool.
//
// Measured: USB 2.0 caps the cable at ~35 MB/s, so Wi-Fi + cable lands near
// 51 MB/s versus 28 MB/s on Wi-Fi alone.

enum ADBBridge {
    /// Common install locations, checked in order before falling back to PATH.
    private static let searchPaths = [
        "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
        "/usr/local/share/android-commandlinetools/platform-tools/adb",
        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
    ]

    private static var cachedPath: String??
    private static let lock = NSLock()

    static func adbPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedPath { return cached }
        let found = searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? which("adb")
        cachedPath = found
        return found
    }

    private static func which(_ tool: String) -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in env.split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static var isAvailable: Bool { adbPath() != nil }

    @discardableResult
    static func run(_ args: [String], timeout: TimeInterval = 12) -> (status: Int32, output: String) {
        guard let adb = adbPath() else { return (-1, "") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "")
        }

        // Never hang the UI on adb. If it stalls (unauthorized device, wedged
        // server) kill it and report failure so the Wi-Fi lane still works.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return (-2, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Serials of devices in the `device` state (not `unauthorized`/`offline`).
    static func authorizedDevices() -> [String] {
        let out = run(["devices"]).output
        return out.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2, parts[1].trimmingCharacters(in: .whitespaces) == "device" else { return nil }
            return parts[0]
        }
    }

    /// IPv4 addresses reported by the phone, with interface names.
    static func deviceAddresses(serial: String? = nil) -> [(iface: String, address: String)] {
        var args: [String] = []
        if let serial { args += ["-s", serial] }
        args += ["shell", "ip", "-4", "addr", "show"]
        let out = run(args).output

        var results: [(String, String)] = []
        var currentIface = "?"
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: #"^\d+:\s+([A-Za-z0-9_.\-]+)"#, options: .regularExpression) {
                let piece = line[r]
                if let colon = piece.range(of: ":") {
                    currentIface = piece[colon.upperBound...]
                        .trimmingCharacters(in: .whitespaces)
                        .split(separator: "@").first.map(String.init) ?? "?"
                }
            } else if line.hasPrefix("inet ") {
                let address = line.dropFirst(5).split(separator: " ").first.map(String.init) ?? ""
                if !address.isEmpty { results.append((currentIface, address)) }
            }
        }
        return results
    }

    /// Best guess at the address to reach the phone on right now. Prefers the
    /// hotspot AP interface, then USB tether, then Wi-Fi.
    static func preferredHost(serial: String? = nil) -> String? {
        let addrs = deviceAddresses(serial: serial)
        let order = ["ap0", "rndis0", "wlan0"]
        for iface in order {
            if let hit = addrs.first(where: { $0.iface == iface }) { return hit.address }
        }
        return addrs.first { !$0.address.hasPrefix("127.") }?.address
    }

    static func deviceModel(serial: String? = nil) -> String? {
        var args: [String] = []
        if let serial { args += ["-s", serial] }
        args += ["shell", "getprop", "ro.product.model"]
        let out = run(args).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    static func forwardList() -> [String] {
        run(["forward", "--list"]).output
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Adds `tcp:<local> tcp:<remote>` on the Mac → phone direction.
    @discardableResult
    static func ensureForward(localPort: UInt16, remotePort: UInt16, serial: String? = nil) -> Bool {
        let spec = "tcp:\(localPort)"
        let remote = "tcp:\(remotePort)"
        if forwardList().contains(where: { $0.contains(spec) && $0.hasSuffix(remote) }) {
            return true
        }
        var args: [String] = []
        if let serial { args += ["-s", serial] }
        args += ["forward", spec, remote]
        let result = run(args)
        return result.status == 0
    }

    /// Adds `tcp:<local> tcp:<remote>` in the phone → Mac direction, so the
    /// phone can push into this Mac over the cable.
    @discardableResult
    static func ensureReverse(localPort: UInt16, remotePort: UInt16, serial: String? = nil) -> Bool {
        let local = "tcp:\(localPort)"
        let remote = "tcp:\(remotePort)"
        if run(["reverse", "--list"]).output.contains(remote) { return true }
        var args: [String] = []
        if let serial { args += ["-s", serial] }
        args += ["reverse", local, remote]
        return run(args).status == 0
    }

    @discardableResult
    static func removeForward(localPort: UInt16) -> Bool {
        run(["forward", "--remove", "tcp:\(localPort)"]).status == 0
    }
}
