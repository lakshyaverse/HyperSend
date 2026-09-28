import AppKit
import SwiftUI

// HyperSend Settings.
//
// Built from the standard components rather than imitating them: a `.sidebar`
// List for the groups and a grouped `Form` for the detail. That is the same
// grammar the reference app has — grouped sidebar, card-stacked rows with
// right-aligned controls, tertiary footer text — because it *is* the macOS
// Settings grammar. The system draws it, so it stays correct in light mode, dark
// mode, and at every accessibility setting.
//
// The one deliberate departure is the toggle: `.glass` (Animations.swift)
// instead of the stock switch, so every window in the app wears the same
// material. Keyboard and VoiceOver behaviour still come from `Toggle` itself.

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, lanes, devices, receive, send, menuBar, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .lanes: return "Lanes"
        case .devices: return "Devices"
        case .receive: return "Receive"
        case .send: return "Send"
        case .menuBar: return "Menu bar"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .lanes: return "bolt.horizontal"
        case .devices: return "iphone"
        case .receive: return "tray.and.arrow.down"
        case .send: return "paperplane"
        case .menuBar: return "menubar.rectangle"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }

    var group: String {
        switch self {
        case .general, .lanes, .devices: return "Essentials"
        case .receive, .send: return "Files"
        case .menuBar, .advanced, .about: return "App"
        }
    }

    static let groups = ["Essentials", "Files", "App"]
}

struct SettingsView: View {
    @State private var section: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SettingsSection.groups, id: \.self) { group in
                    Section(group) {
                        ForEach(SettingsSection.allCases.filter { $0.group == group }) { item in
                            Label(item.title, systemImage: item.symbol)
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 260)
        } detail: {
            detail
                .navigationTitle(section.title)
        }
        .frame(width: 880, height: 620)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .general: generalSection
        case .lanes: lanesSection
        case .devices: devicesSection
        case .receive: receiveSection
        case .send: sendSection
        case .menuBar: menuBarSection
        case .advanced: advancedSection
        case .about: aboutSection
        }
    }

    // MARK: General

    @AppStorage(Pref.launchAtLogin) private var launchAtLogin = false
    @AppStorage(Pref.appearance) private var appearance = "system"
    @AppStorage(Pref.deviceName) private var deviceName = ""

    private var generalSection: some View {
        Form {
            Section {
                LabeledContent("Launch at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.glass)
                        .onChange(of: launchAtLogin) { _, wanted in
                            // If the system refuses, snap the switch back rather
                            // than showing a state that is not true.
                            let actual = LaunchAtLogin.set(wanted)
                            if actual != wanted { launchAtLogin = actual }
                        }
                }
                LabeledContent("Language") {
                    Picker("", selection: .constant("en")) {
                        Text("English (US)").tag("en")
                    }
                    .labelsHidden()
                }
                LabeledContent("Appearance") {
                    Picker("", selection: $appearance) {
                        ForEach(AppearancePref.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    .onChange(of: appearance) { _, value in AppearancePref.apply(value) }
                }
                LabeledContent("Device name") {
                    TextField(AppModel.shared.deviceName, text: $deviceName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            } footer: {
                Text("The device name is what other machines see when they discover this Mac. It applies the next time HyperSend starts.")
            }

            Section {
                Text("HyperSend splits a file into 2 MiB chunks and hands each one to whichever lane is free, so lanes never need configuring by hand.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Lanes

    @AppStorage(Pref.socketsPerLane) private var socketsPerLane = 2
    @AppStorage(Pref.usbLaneEnabled) private var usbLaneEnabled = true

    private var lanesSection: some View {
        Form {
            Section {
                LabeledContent("Wi-Fi") {
                    LaneStatus(ready: true, detail: "always available")
                }
                LabeledContent("Bond USB lane") {
                    Picker("Bond USB lane", selection: $usbLaneEnabled) {
                        Text("When available").tag(true)
                        Text("Wi-Fi only").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .labelsHidden()
                }
                LabeledContent("USB cable") {
                    LaneStatus(
                        ready: AppModel.shared.usbLaneReady,
                        detail: AppModel.shared.usbLaneReady ? "tunnel open" : "not connected",
                    )
                }
                LabeledContent("Sockets per lane") {
                    Stepper(value: $socketsPerLane, in: 1 ... 8) {
                        Text("\(socketsPerLane)").monospacedDigit()
                    }
                    .frame(width: 110)
                }
            } footer: {
                Text("More sockets per lane help on a lossy link; two is plenty on a healthy one.")
            }

            // These are the developer's figures, not the user's. Labelling them
            // "Measured on this Mac" made a claim about their hardware that was
            // simply untrue on any other machine.
            Section {
                LabeledContent("Bonded result") { Value("314.6 MB in 4.6 s · 68.8 MB/s") }
                LabeledContent("Wi-Fi lane") { Value("36.2 MB/s") }
                LabeledContent("USB cable lane") { Value("32.6 MB/s") }
            } header: {
                Text("Reference throughput")
            } footer: {
                Text("Measured by the developer on an Apple Silicon Mac over a 480 Mbps hotspot to a CMF Phone 1. Your numbers depend on your radio and cable — the real rate is reported while a transfer runs.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Devices

    private var devicesSection: some View {
        Form {
            Section {
                let peers = AppModel.shared.peers.filter { $0.name != AppModel.shared.deviceName }
                if peers.isEmpty {
                    LabeledContent("Devices") {
                        Text("none yet — waiting for a beacon").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(peers, id: \.key) { peer in
                        LabeledContent(peer.name) {
                            Text(peer.usbReachable ? "\(peer.host) · cable" : peer.host)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("Devices announce themselves on the local network. If one never appears, add it by IP from the File menu.")
            }

            Section("Receive folder") {
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text(AppModel.shared.receiveDirectory.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = AppModel.shared.receiveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppModel.shared.receiveDirectory = url
        UserDefaults.standard.set(url.path, forKey: Pref.receivePath)
        AppModel.shared.log("receive folder → \(url.path)")
    }

    // MARK: Receive

    @AppStorage(Pref.autoAccept) private var autoAccept = true
    @AppStorage(Pref.openAfterReceive) private var openAfterReceive = false
    @AppStorage(Pref.revealInFinder) private var revealInFinder = true

    private var receiveSection: some View {
        Form {
            Section {
                LabeledContent("Accept automatically") {
                    Toggle("", isOn: $autoAccept)
                        .labelsHidden()
                        .toggleStyle(.glass)
                        .onChange(of: autoAccept) { _, value in AppModel.shared.autoAccept = value }
                }
                // Both of these are read by the receiver when a file lands, so
                // the model has to be told as well as UserDefaults — otherwise
                // the switch moves and nothing changes until the next launch.
                LabeledContent("Open after receiving") {
                    Toggle("", isOn: $openAfterReceive)
                        .labelsHidden()
                        .toggleStyle(.glass)
                        .onChange(of: openAfterReceive) { _, value in AppModel.shared.openAfterReceive = value }
                }
                LabeledContent("Reveal in Finder") {
                    Toggle("", isOn: $revealInFinder)
                        .labelsHidden()
                        .toggleStyle(.glass)
                        .onChange(of: revealInFinder) { _, value in AppModel.shared.revealInFinder = value }
                }
            } footer: {
                Text("With automatic acceptance off, every incoming file is offered to you first. Transfers are always SHA-256 verified before a file is written into place. Opening a received file launches it with its default app, so it is off by default — leave it off unless you trust the sender.")
            }

            Section("Status") {
                LabeledContent("Receiver") {
                    LaneStatus(
                        ready: AppModel.shared.receiverReady,
                        detail: AppModel.shared.receiverReady ? "listening" : "off",
                    )
                }
                LabeledContent("Files received") { Value("\(AppModel.shared.receivedCount)") }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Send

    private var sendSection: some View {
        Form {
            Section {
                LabeledContent("Target") {
                    Text(AppModel.shared.selectedPeer?.name ?? "none selected")
                        .foregroundStyle(AppModel.shared.selectedPeer == nil ? .secondary : .primary)
                }
                LabeledContent("Lanes in use") {
                    Text(AppModel.shared.usbLaneReady ? "Wi-Fi + USB cable" : "Wi-Fi only")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Sent") {
                    Value("\(AppModel.shared.sentCount) file\(AppModel.shared.sentCount == 1 ? "" : "s")")
                }
            } footer: {
                Text("Drop files or folders anywhere in the main window, or use Send Files… (⌘O). Folders are walked recursively and arrive with their structure intact.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Menu bar

    @AppStorage(Pref.showMenuBarIcon) private var showMenuBarIcon = false

    private var menuBarSection: some View {
        Form {
            Section {
                LabeledContent("Show menu bar icon") {
                    Toggle("", isOn: $showMenuBarIcon)
                        .labelsHidden()
                        .toggleStyle(.glass)
                        .onChange(of: showMenuBarIcon) { _, visible in
                            MenuBarItem.shared.setVisible(visible)
                        }
                }
            } footer: {
                Text("If HyperSend's icon disappears, macOS can hide menu bar icons when the bar runs out of room — common on Macs with a notch. Reopen HyperSend from Applications or Spotlight: that rebuilds the icon and, if it is still hidden, opens this window.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Form {
            Section {
                LabeledContent("Control") { Value("\(Proto.controlPort)") }
                LabeledContent("Data") { Value("\(Proto.usbDataPort)") }
                LabeledContent("USB lane (local)") { Value("\(Proto.usbLocalPort)") }
                LabeledContent("Discovery") { Value("\(Proto.discoveryPort)") }
            } header: {
                Text("Ports")
            } footer: {
                Text("Ports are fixed on purpose: a stable data port is the only reason the USB cable can act as its own path, and the receiver must be listening before a sender connects.")
            }

            Section {
                LabeledContent("Launch trace") {
                    HStack(spacing: 8) {
                        Value(LaunchTrace.enabled ? "on" : "off")
                        Button("Reveal Log") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                URL(fileURLWithPath: "/tmp/hypersend-launch.log"),
                            ])
                        }
                    }
                }
                LabeledContent("adb") {
                    Text(ADBBridge.adbPath() ?? "not found")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Chunk size") { Value(formattedBytes(Int64(Proto.chunkSize))) }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Set HS_LAUNCH_TRACE=1 before launching to write a line-by-line log of window construction — the fastest way to diagnose a window that never appears.")
            }

            Section {
                LabeledContent("Preferences") {
                    Button("Reset to Defaults") { resetPreferences() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func resetPreferences() {
        // Destructive and one click away, so it asks first.
        let alert = NSAlert()
        alert.messageText = "Reset all preferences?"
        alert.informativeText = "Device name, receive folder, appearance, glass and lane settings go back to their defaults. Received files and transfers are not touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let domain = Bundle.main.bundleIdentifier ?? "com.hypersend.mac"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        Pref.registerDefaults()
        AppearancePref.apply("system")
        MenuBarItem.shared.setVisible(false)
        AppModel.shared.log("preferences reset to defaults")
    }

    // MARK: About

    private var aboutSection: some View {
        Form {
            Section {
                LabeledContent("Version") { Value(Self.versionString) }
                LabeledContent("Protocol") { Value("v\(Proto.version)") }
                LabeledContent("Licence") { Value("MIT") }
                LabeledContent("Source") { Value(AppLinks.repository.absoluteString) }
            } header: {
                Text("HyperSend")
            } footer: {
                Text("Multipath transfer between a Mac and an Android phone. Every byte is SHA-256 verified; nothing goes through a server.\n\nMade with love by Lakshya.")
            }

            Section {
                Button {
                    NSWorkspace.shared.open(AppLinks.issues)
                } label: {
                    Label("Report an issue", systemImage: "bubble.left")
                }
                Button {
                    NSWorkspace.shared.open(AppLinks.repository)
                } label: {
                    Label("View source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .formStyle(.grouped)
    }

    private static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

// MARK: - Small parts

/// A right-aligned read-only value.
private struct Value: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

private struct LaneStatus: View {
    let ready: Bool
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    SettingsView()
}
#endif

// MARK: - Window

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    convenience init() {
        let hosting = NSHostingView(rootView: SettingsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = "HyperSend Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func present() {
        guard let window else { return }
        window.center()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
