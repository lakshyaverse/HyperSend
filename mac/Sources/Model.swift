import AppKit
import Foundation
import Observation

// The app model. One place that owns the engine, the peer table and the
// transfer list; the views just read this and draw it.
//
// `@Observable` lets SwiftUI read these properties directly and redraw only the
// views that touched what changed — no manual change plumbing, no Combine, and
// no stale rows. The AppKit `onChange` hook is kept for headless callers.

enum TransferDirection {
    case send
    case receive
}

enum TransferStatus: Equatable {
    case queued
    case active
    case verifying
    case done
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}

@Observable
final class TransferItem: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64
    let direction: TransferDirection
    let started = Date()
    var bytesDone: Int64 = 0
    var lanes: [String: LaneReport] = [:]
    var status: TransferStatus = .queued
    var peerName: String
    var seconds: Double = 0

    // Rate tracking (exponential moving average over ~0.5 s samples).
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var lastLaneBytes: [String: Int64] = [:]
    var bytesPerSec: Double = 0
    var laneRates: [String: Double] = [:]

    init(name: String, size: Int64, direction: TransferDirection, peerName: String) {
        self.name = name
        self.size = size
        self.direction = direction
        self.peerName = peerName
    }

    var fraction: Double {
        size > 0 ? min(1, Double(bytesDone) / Double(size)) : (status == .done ? 1 : 0)
    }

    func sample(bytesDone: Int64, lanes: [String: LaneReport]) {
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleTime)
        guard dt > 0.05 else {
            self.bytesDone = bytesDone
            self.lanes = lanes
            return
        }
        let instantaneous = Double(bytesDone - lastSampleBytes) / dt
        bytesPerSec = bytesPerSec == 0 ? instantaneous : bytesPerSec * 0.6 + instantaneous * 0.4

        for (label, report) in lanes {
            let previous = lastLaneBytes[label] ?? 0
            let laneInstant = Double(report.bytes - previous) / dt
            let smoothed = laneRates[label] ?? 0
            laneRates[label] = smoothed == 0 ? laneInstant : smoothed * 0.6 + laneInstant * 0.4
            lastLaneBytes[label] = report.bytes
        }

        lastSampleTime = now
        lastSampleBytes = bytesDone
        self.bytesDone = bytesDone
        self.lanes = lanes
    }

    func finish(bytesDone: Int64, lanes: [String: LaneReport], seconds: Double) {
        self.bytesDone = bytesDone
        self.lanes = lanes
        self.seconds = seconds
        for (label, report) in lanes {
            laneRates[label] = seconds > 0 ? Double(report.bytes) / seconds : 0
        }
        bytesPerSec = seconds > 0 ? Double(bytesDone) / seconds : 0
    }
}

@Observable
final class AppModel {
    static let shared = AppModel()

    // ── Identity ─────────────────────────────────────────────────────────
    /// A name set in Settings wins; otherwise use the Mac's own name. Read once
    /// at launch, which is why the Settings footer says it applies next start.
    let deviceName: String = {
        let stored = UserDefaults.standard.string(forKey: Pref.deviceName) ?? ""
        return stored.trimmingCharacters(in: .whitespaces).isEmpty ? hostName() : stored
    }()

    private(set) var localAddresses: [(interface: String, address: String)] = []

    // ── Peers ────────────────────────────────────────────────────────────
    private(set) var peers: [Peer] = []
    var selectedPeerKey: String?

    // ── Transfers ────────────────────────────────────────────────────────
    private(set) var transfers: [TransferItem] = []
    var activeTransfer: TransferItem? { transfers.last { !$0.status.isTerminal } }
    private(set) var receivedCount = 0
    private(set) var sentCount = 0

    // ── Status ───────────────────────────────────────────────────────────
    private(set) var statusText = "Starting…"
    private(set) var logs: [String] = []
    private(set) var usbLaneReady = false
    private(set) var receiverReady = false
    var receiveDirectory: URL

    /// What to do when a peer offers a file. Defaults to accepting — but an
    /// explicit opt-out in Settings must survive, so this reads the stored value
    /// rather than a hardcoded true. (`object(forKey:)` keeps CLI runs, which
    /// never register defaults, on the accept-by-default path.)
    var autoAccept: Bool = UserDefaults.standard.object(forKey: Pref.autoAccept) as? Bool ?? true

    /// Read at delivery time, like `autoAccept`, so flipping a switch takes
    /// effect on the next file instead of the next launch.
    ///
    /// Both of these were declared, rendered in Settings, and read by nothing:
    /// the app always revealed the file whatever the toggles said.
    var revealInFinder: Bool = UserDefaults.standard.object(forKey: Pref.revealInFinder) as? Bool ?? true
    /// Off by default. "Open" launches the file with its default app, which
    /// means a `.command` or `.app` someone sends you is one click from
    /// running; revealing it in Finder is enough unless you ask for more.
    var openAfterReceive: Bool = UserDefaults.standard.object(forKey: Pref.openAfterReceive) as? Bool ?? false

    // Built in start(), not here: the broadcast name must be the *same* string
    // as `deviceName`, otherwise our own beacon no longer matches the self
    // filter below and the app lists this Mac as a nearby device.
    private var beacon: BeaconBroadcaster?
    private var listener: BeaconListener!
    private var receiver: ReceiveEngine?
    private let adbQueue = DispatchQueue(label: "hypersend.adb")
    private var lastUSBNote = ""
    private let sendQueue = DispatchQueue(label: "hypersend.send", qos: .userInitiated)
    private(set) var isSending = false
    /// Items dropped while a transfer is already running. Drained in order.
    private var queuedURLs: [URL] = []

    var queuedCount: Int { queuedURLs.count }

    /// Views subscribe to this to redraw.
    var onChange: (() -> Void)?

    private init() {
        let stored = UserDefaults.standard.string(forKey: Pref.receivePath) ?? ""
        if !stored.isEmpty {
            receiveDirectory = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            receiveDirectory = downloads.appendingPathComponent("HyperSend", isDirectory: true)
        }
        localAddresses = localIPv4Addresses()
    }

    // MARK: - Lifecycle

    func start() {
        log("\(deviceName) · \(localAddresses.map { "\($0.interface) \($0.address)" }.joined(separator: ", "))")

        listener = BeaconListener { [weak self] found in
            guard let self else { return }
            // Beacons arrive several times a second (including our own loopback
            // copy). Only touch the UI when the peer set actually changes —
            // otherwise every packet triggers a needless redraw.
            // Drop our own beacon: match on the name we broadcast, and also on
            // any address that is literally this machine (the broadcaster sends
            // a loopback copy, and the radio copy comes back with our own IP).
            let ownAddresses = Set(self.localAddresses.map { $0.address } + ["127.0.0.1", "::1"])
            var changed = false
            for peer in found where peer.name != self.deviceName && !ownAddresses.contains(peer.host) {
                if let index = self.peers.firstIndex(where: { $0.host == peer.host && $0.port == peer.port }) {
                    self.peers[index].lastSeen = peer.lastSeen
                    if self.peers[index].name != peer.name {
                        self.peers[index].name = peer.name
                        changed = true
                    }
                } else {
                    self.peers.append(peer)
                    changed = true
                }
            }
            guard changed else { return }
            if self.selectedPeerKey == nil { self.selectedPeerKey = self.peers.first?.key }
            self.statusText = self.peers.isEmpty
                ? "Scanning for devices on this network…"
                : "Ready — \(self.peers.count) device\(self.peers.count == 1 ? "" : "s") found"
            self.notify()
        }
        listener.start()
        beacon = BeaconBroadcaster(controlPort: Proto.controlPort, name: deviceName)
        beacon?.start()

        startReceiver()
        refreshUSB()

        // Expire stale beacons, and re-probe USB only while the lane is down —
        // `adb shell` is not cheap and the phone should not be poked for
        // nothing. Once the tunnel is up we leave it alone.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.expirePeers()
            if !self.usbLaneReady { self.refreshUSB() }
        }
    }

    func shutdown() {
        listener?.stop()
        beacon?.stop()
        receiver?.stop()
    }

    private func startReceiver() {
        let engine = ReceiveEngine(
            destDir: receiveDirectory,
            controlPort: Proto.controlPort,
            dataPort: Proto.usbDataPort,
        )
        receiver = engine
        engine.updateHooks(ReceiveEngine.Hooks(
            accept: { [weak self] path, size in
                guard let self else { return false }
                if self.autoAccept {
                    self.log("incoming: \(path) · \(formattedBytes(size))")
                    return true
                }
                // With automatic acceptance off the file is *offered*, not
                // refused: ask, and park this session thread until the user
                // answers. The sender's offer window outlasts this prompt (see
                // SendEngine.awaitOfferResponse), so a slow answer still
                // arrives as a decision rather than a failure.
                let answer = self.askToAccept(path: path, size: size)
                self.log(answer ? "accepted \(path)" : "declined \(path)")
                return answer
            },
            progress: { [weak self] name, done, total in
                self?.updateReceiveProgress(name: name, done: done, total: total)
            },
            finished: { [weak self] file in
                guard let self else { return }
                self.receivedCount += 1
                self.log("saved \(file.name) → \(self.receiveDirectory.path)")
                self.finishReceive(file)
                let received = URL(fileURLWithPath: file.path)
                if self.revealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([received])
                }
                if self.openAfterReceive {
                    NSWorkspace.shared.open(received)
                }
                self.notify()
            },
            log: { [weak self] message in self?.log(message) },
        ))
        do {
            try engine.start()
            receiverReady = true
            log("receiving on :\(Proto.controlPort), data plane :\(Proto.usbDataPort)")
            log("USB lane, when up, is the local port :\(Proto.usbLocalPort)")
            log("saving to \(receiveDirectory.path)")
        } catch {
            receiverReady = false
            log("receiver failed: \(error.localizedDescription)")
        }
    }

    // MARK: - USB lane (adb tunnel)

    /// Detects an attached Android device and opens the fixed-port tunnel that
    /// gives the cable its own lane. Entirely optional: without it we still
    /// have the Wi-Fi lane.
    func refreshUSB() {
        adbQueue.async { [weak self] in
            guard let self else { return }
            guard ADBBridge.isAvailable else {
                self.finishUSBProbe(ready: false, note: "adb not found — Wi-Fi lane only")
                return
            }
            let devices = ADBBridge.authorizedDevices()
            guard let serial = devices.first else {
                let unauthorized = ADBBridge.run(["devices"]).output.contains("unauthorized")
                self.finishUSBProbe(ready: false, note: unauthorized
                    ? "Approve USB debugging on the phone to enable the cable lane"
                    : "No Android device on USB — Wi-Fi lane only")
                return
            }

            let host = ADBBridge.preferredHost(serial: serial)
            let model = ADBBridge.deviceModel(serial: serial) ?? "Android device"
            let forwarded = ADBBridge.ensureForward(
                localPort: Proto.usbLocalPort,
                remotePort: Proto.usbDataPort,
                serial: serial,
            )

            DispatchQueue.main.async {
                self.usbLaneReady = forwarded
                if !forwarded {
                    self.noteOnce("USB lane failed to open for \(model)")
                } else {
                    self.noteOnce("USB lane up · 127.0.0.1:\(Proto.usbLocalPort) → \(model):\(Proto.usbDataPort)")
                }

                if let host, !host.isEmpty {
                    if let index = self.peers.firstIndex(where: { $0.host == host }) {
                        self.peers[index].usbReachable = forwarded
                        self.peers[index].lastSeen = Date()
                    } else {
                        self.peers.append(Peer(
                            name: model,
                            host: host,
                            port: Proto.controlPort,
                            lastSeen: Date(),
                            usbReachable: forwarded,
                        ))
                    }
                    self.selectedPeerKey = self.selectedPeerKey ?? "\(host):\(Proto.controlPort)"
                }
                self.notify()
            }
        }
    }

    private func finishUSBProbe(ready: Bool, note: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let changed = self.usbLaneReady != ready
            self.usbLaneReady = ready
            if changed || !ready { self.noteOnce(note) }
            self.notify()
        }
    }

    /// `refreshUSB` polls, so identical notes must not flood the activity log.
    private func noteOnce(_ message: String) {
        guard message != lastUSBNote else { return }
        lastUSBNote = message
        log(message)
    }

    /// True for an IPv4 literal or a plausible host name.
    ///
    /// Deliberately strict about shapes we could never connect to: a typo used
    /// to become a peer that sat in the sidebar looking real and never worked.
    static func isConnectableHost(_ input: String) -> Bool {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253 else { return false }

        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ octet in
            octet.allSatisfy { $0.isASCII && $0.isNumber } && (Int(octet).map { (0 ... 255).contains($0) } ?? false)
        }) {
            return true
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }

    /// Adds a manually entered device. Returns false when the address could not
    /// be reached by any amount of trying, so the caller can say why instead of
    /// silently listing it.
    @discardableResult
    func addPeerManually(host: String, name: String? = nil) -> Bool {
        guard Self.isConnectableHost(host) else { return false }
        if let index = peers.firstIndex(where: { $0.host == host }) {
            peers[index].lastSeen = Date()
        } else {
            peers.append(Peer(
                name: name ?? host,
                host: host,
                port: Proto.controlPort,
                lastSeen: Date(),
                usbReachable: usbLaneReady,
            ))
        }
        selectedPeerKey = "\(host):\(Proto.controlPort)"
        log("added device \(host) manually")
        notify()
        return true
    }

    private func expirePeers() {
        let cutoff = Date().addingTimeInterval(-8)
        let before = peers.count
        // Keep adb-detected peers even if they never broadcast.
        peers = peers.filter { $0.lastSeen > cutoff || $0.usbReachable }
        if peers.count != before {
            statusText = peers.isEmpty
                ? "Scanning for devices on this network…"
                : "Ready — \(peers.count) device\(peers.count == 1 ? "" : "s") found"
            notify()
        }
    }

    var selectedPeer: Peer? {
        guard let key = selectedPeerKey else { return peers.first }
        return peers.first { $0.key == key } ?? peers.first
    }

    // MARK: - Sending

    func chooseAndSend() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose files to send over Wi-Fi + USB"
        panel.prompt = "Send"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        send(urls: panel.urls)
    }

    func send(urls: [URL]) {
        guard !urls.isEmpty else { return }

        // Dropping more while something is in flight queues it instead of
        // refusing: a queue is what a drag-and-drop app is expected to do.
        if isSending {
            queuedURLs.append(contentsOf: urls)
            log("queued \(urls.count) item(s) — \(queuedURLs.count) waiting")
            statusText = "Queued — \(queuedURLs.count) waiting"
            notify()
            return
        }

        let sources: [SendSource]
        do {
            sources = try collectSendSources(from: urls)
        } catch {
            log(error.localizedDescription)
            statusText = error.localizedDescription
            notify()
            return
        }

        guard let peer = selectedPeer else {
            log("no device selected — waiting for a beacon or add one manually")
            statusText = "No device selected"
            notify()
            return
        }

        var lanes: [Lane] = [Lane(label: "wifi", host: peer.host, port: nil)]
        if peer.usbReachable, TCPConnection.probe(host: "127.0.0.1", port: Proto.usbLocalPort) {
            lanes.append(Lane(label: "usb", host: "127.0.0.1", port: Proto.usbLocalPort))
        } else if peer.usbReachable {
            log("USB tunnel advertised but not answering — sending on Wi-Fi only")
        }

        // One row per file. A folder send shows the relative path so the row
        // still says where the file lives inside the folder.
        let items: [TransferItem] = sources.map { source in
            TransferItem(
                name: source.relativePath,
                size: source.size,
                direction: .send,
                peerName: peer.name,
            )
        }
        let files = sources.map(\.url)
        let paths = sources.map(\.relativePath)
        for item in items { item.status = .active }
        transfers.append(contentsOf: items)
        isSending = true
        statusText = "Sending \(items.count) file\(items.count == 1 ? "" : "s") to \(peer.name)"
        notify()

        log("sending \(items.count) file(s) to \(peer.name) over \(lanes.map(\.label).joined(separator: " + "))")

        sendQueue.async { [weak self] in
            guard let self else { return }
            let engine = SendEngine()
            do {
                let summary = try engine.send(
                    files: files,
                    paths: paths,
                    primary: lanes[0],
                    extraLanes: Array(lanes.dropFirst()),
                    socketsPerLane: 2,
                    progress: { progress in
                        // The engine reports a cumulative byte count across the
                        // whole batch, so subtract everything already finished
                        // to get this file's own progress bar.
                        guard let index = items.firstIndex(where: { $0.name == progress.fileName }) else { return }
                        let target = items[index]
                        let alreadyDone = items[..<index].reduce(Int64(0)) { $0 + $1.size }
                        let lanesSnapshot = progress.lanes
                        DispatchQueue.main.async {
                            target.sample(bytesDone: max(0, progress.bytesDone - alreadyDone), lanes: lanesSnapshot)
                            target.status = .active
                            self.notify()
                        }
                    },
                    log: { [weak self] message in
                        DispatchQueue.main.async { self?.log(message) }
                    },
                )

                DispatchQueue.main.async {
                    for item in items where !item.status.isTerminal {
                        item.status = .done
                        item.finish(bytesDone: item.size, lanes: summary.lanes, seconds: summary.seconds)
                    }
                    self.sentCount += items.count
                    self.isSending = false
                    self.statusText = "Sent \(items.count) file\(items.count == 1 ? "" : "s") · \(formattedRate(summary.bytesPerSec))"
                    self.log(String(
                        format: "done · %@ in %@ · %@",
                        formattedBytes(summary.bytes),
                        formattedDuration(summary.seconds),
                        formattedRate(summary.bytesPerSec),
                    ))
                    for (label, report) in summary.lanes.sorted(by: { $0.key < $1.key }) {
                        self.log("  \(label): \(formattedBytes(report.bytes)) · \(formattedRate(report.bytesPerSec))")
                    }
                    self.notify()
                    self.drainQueue()
                }
            } catch {
                DispatchQueue.main.async {
                    for item in items where !item.status.isTerminal {
                        item.status = .failed(error.localizedDescription)
                    }
                    self.isSending = false
                    self.statusText = "Send failed — \(error.localizedDescription)"
                    self.log("send failed: \(error.localizedDescription)")
                    self.notify()
                    self.drainQueue()
                }
            }
        }
    }

    /// Starts the next queued drop, if any. Called on the main thread after a
    /// send settles, so `isSending` is already false again.
    private func drainQueue() {
        guard !queuedURLs.isEmpty, !isSending else { return }
        let next = queuedURLs
        queuedURLs.removeAll()
        send(urls: next)
    }

    // MARK: - Receiving

    /// How long the receiver waits for a person to answer an incoming offer.
    /// Deliberately shorter than the sender's offer-response window so the
    /// decline reaches it as a decision instead of timing it out.
    private static let acceptPromptTimeout: TimeInterval = 100

    /// Shows the incoming-file prompt on the main thread and waits for it.
    /// Called from a receiver session thread, so the work is hopped to main and
    /// this thread parks on a semaphore until it is answered (or times out).
    private func askToAccept(path: String, size: Int64) -> Bool {
        func present() -> Bool {
            let alert = NSAlert()
            alert.messageText = "Incoming file"
            alert.informativeText = "\(path)\n\(formattedBytes(size))"
            alert.addButton(withTitle: "Accept")
            alert.addButton(withTitle: "Decline")
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }

        if Thread.isMainThread { return present() }

        let semaphore = DispatchSemaphore(value: 0)
        var answer = false
        DispatchQueue.main.async {
            answer = present()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + Self.acceptPromptTimeout) == .timedOut {
            log("no answer for \(path) — declined")
            return false
        }
        return answer
    }

    private func updateReceiveProgress(name: String, done: Int64, total: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let item: TransferItem
            if let existing = self.transfers.last(where: { $0.direction == .receive && $0.name == name && !$0.status.isTerminal }) {
                item = existing
            } else {
                item = TransferItem(name: name, size: total, direction: .receive, peerName: "incoming")
                item.status = .active
                self.transfers.append(item)
            }
            item.sample(bytesDone: done, lanes: [:])
            self.statusText = "Receiving \(name) · \(formattedRate(item.bytesPerSec))"
            self.notify()
        }
    }

    private func finishReceive(_ file: ReceivedFile) {
        if let item = transfers.last(where: { $0.direction == .receive && $0.name == file.name && !$0.status.isTerminal }) {
            item.status = .done
            item.finish(bytesDone: file.size, lanes: [:], seconds: max(file.seconds, 0.001))
        } else {
            let item = TransferItem(name: file.name, size: file.size, direction: .receive, peerName: "incoming")
            item.status = .done
            item.bytesDone = file.size
            transfers.append(item)
        }
        statusText = "Saved \(file.name)"
    }

    // MARK: - Plumbing

    func log(_ message: String) {
        let line = message
        if Thread.isMainThread {
            logs.append(line)
            if logs.count > 400 { logs.removeFirst(logs.count - 400) }
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.log(line) }
        }
    }

    private func notify() {
        onChange?()
    }
}

#if DEBUG
extension AppModel {
    /// A populated model for Xcode Previews, so the canvas shows a real window
    /// instead of an empty one. Only ever compiled into debug builds used by
    /// Previews — never into the shipping `-O` app.
    static func previewSeeded() -> AppModel {
        let model = AppModel.shared
        let pixel = Peer(name: "Pixel 9", host: "10.102.155.42", port: 44010, lastSeen: Date(), usbReachable: false)
        let phone = Peer(name: "CMF Phone 1", host: "10.102.155.108", port: 44010, lastSeen: Date(), usbReachable: true)
        model.peers = [phone, pixel]
        model.selectedPeerKey = phone.key
        model.usbLaneReady = true
        model.receiverReady = true
        model.receiveDirectory = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/HyperSend")
        model.localAddresses = [("en0", "10.102.155.240")]

        let movie = TransferItem(name: "Vacation/2024/beach.jpg", size: 314_572_800, direction: .send, peerName: "CMF Phone 1")
        movie.status = .active
        movie.bytesDone = 188_743_680
        movie.bytesPerSec = 68_800_000
        movie.laneRates = ["wifi": 36_200_000, "usb": 32_600_000]
        movie.lanes = [
            "wifi": LaneReport(bytes: 98_500_000, chunks: 47, bytesPerSec: 36_200_000),
            "usb": LaneReport(bytes: 90_243_680, chunks: 43, bytesPerSec: 32_600_000),
        ]

        let done = TransferItem(name: "notes/plan.txt", size: 4_400_000, direction: .send, peerName: "CMF Phone 1")
        done.status = .done
        done.bytesDone = 4_400_000
        done.seconds = 0.7
        done.bytesPerSec = 6_300_000

        let inbound = TransferItem(name: "screenshot.png", size: 2_100_000, direction: .receive, peerName: "Pixel 9")
        inbound.status = .done
        inbound.bytesDone = 2_100_000
        inbound.seconds = 0.3

        model.transfers = [movie, done, inbound]
        model.statusText = "Sending 3 files to CMF Phone 1"
        model.logs = [
            "CMF Phone 1 · 10.102.155.108",
            "USB lane up · 127.0.0.1:44013 → CMF Phone 1:44012",
            "sending 3 file(s) over wifi + usb",
            "data lanes: wifi ×2 + usb ×2",
            "✓ Vacation/2024/sunset.jpg · sha256 ok",
            "✓ Vacation/notes/plan.txt · sha256 ok",
        ]
        return model
    }
}
#endif

extension Peer {
    var key: String { "\(host):\(port)" }
}
