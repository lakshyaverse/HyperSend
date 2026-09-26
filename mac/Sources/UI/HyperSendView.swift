import AppKit
import SwiftUI

// The main window.
//
// Apple's "Adopting Liquid Glass" is explicit: use the standard components and
// let the system supply the material, and strip custom backgrounds out of
// navigation elements so they cannot interfere with it. So this is a real
// NavigationSplitView with a real .sidebar List, a real .toolbar and a real
// safe-area status bar — no hand-painted glass anywhere in the chrome.
//
// Custom glass is used only where Apple says it is appropriate: small floating
// controls, sparingly.

struct HyperSendView: View {
    @Bindable var model: AppModel
    @AppStorage(Pref.glassIntensity) private var glassIntensity = GlassIntensity.maximum.rawValue
    @State private var dropActive = false
    @State private var columns = NavigationSplitViewVisibility.all

    init(model: AppModel = .shared) {
        self._model = Bindable(model)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarColumn(model: model)
                .navigationSplitViewColumnWidth(min: 208, ideal: 236, max: 320)
        } content: {
            TransfersColumn(model: model)
                .navigationSplitViewColumnWidth(min: 320, ideal: 392, max: 560)
        } detail: {
            LanesColumn(model: model)
        }
        .navigationTitle("HyperSend")
        .navigationSubtitle(subtitle)
        // Behind *every* column, so the system's own sidebar and toolbar
        // material has real tooth to refract. Glass over flat grey reads as
        // grey no matter how strong the effect is.
        .background { WindowTexture() }
        .frame(minWidth: 940, minHeight: 620)
        .environment(\.glassIntensity, GlassIntensity(rawValue: glassIntensity) ?? .maximum)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                MagneticDock(items: dockActions)
                    .padding(.vertical, 6)
                StatusBar(model: model)
            }
        }
        .overlay {
            if dropActive {
                // The one place custom glass is appropriate: a transient,
                // important piece of feedback floating over the content.
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Drop to send over \(model.usbLaneReady ? "Wi-Fi + USB" : "Wi-Fi")")
                }
                .font(UI.TypeScale.emphasis)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .floatingGlass()
                .jiggle(on: dropActive ? 1 : 0, amount: 0.055)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: dropActive)
        .dropDestination(for: URL.self) { urls, _ in
            model.send(urls: urls)
            return true
        } isTargeted: { targeted in
            dropActive = targeted
        }
        // One native primary action. Secondary actions live in the magnetic
        // dock below — nothing is offered twice.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.chooseAndSend()
                } label: {
                    Label("Send Files", systemImage: "paperplane.fill")
                }
                .disabled(model.selectedPeer == nil)
                .help("Send files or folders")
            }
        }
    }

    /// The buttons the magnetic dock hosts. Order = launch order.
    var dockActions: [MagneticDockView.Item] {
        [
            .init(symbol: "paperplane.fill", help: "Send files or folders") {
                model.chooseAndSend()
            },
            .init(symbol: "plus", help: "Add a device by IP address") {
                MenuActions.shared.addDevice(nil)
            },
            .init(symbol: "folder", help: "Show the receive folder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.receiveDirectory])
            },
            .init(symbol: "gearshape", help: "Settings") {
                MenuActions.shared.openSettings(nil)
            },
        ]
    }

    private var subtitle: String {
        if model.isSending, let peer = model.selectedPeer {
            return "Sending to \(peer.name) over \(model.usbLaneReady ? "Wi-Fi + USB" : "Wi-Fi")"
        }
        let total = model.sentCount + model.receivedCount
        return total > 0 ? "\(model.sentCount) sent · \(model.receivedCount) received" : "Drop files anywhere"
    }
}

// MARK: - Sidebar (a real .sidebar List)

private struct SidebarColumn: View {
    @Bindable var model: AppModel

    private var peers: [Peer] {
        model.peers.filter { $0.name != model.deviceName }
    }

    var body: some View {
        List(selection: $model.selectedPeerKey) {
            Section("Devices") {
                if peers.isEmpty {
                    Text("Looking for devices…")
                        .foregroundStyle(.secondary)
                }
                ForEach(peers, id: \.key) { peer in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(peer.name)
                            Text(peer.usbReachable ? "\(peer.host) · cable lane" : peer.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: peer.usbReachable ? "cable.connector" : "iphone")
                    }
                    .tag(peer.key)
                }
            }

            Section("This Mac") {
                LabeledContent("Name") { Text(model.deviceName).foregroundStyle(.secondary) }
                LabeledContent("Address") {
                    Text(model.localAddresses.first?.address ?? "—")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Receiver") {
                    Text(model.receiverReady ? "ready" : "off")
                        .foregroundStyle(model.receiverReady ? Color.green : Color.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        // Let the window's texture through: a List paints an opaque background
        // of its own otherwise, and the sidebar ends up flat grey next to a
        // textured workspace. The grain goes back on underneath the rows, so
        // the system still supplies the material and we only give it tooth.
        .scrollContentBackground(.hidden)
        .background { SurfaceGrain() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([model.receiveDirectory])
                } label: {
                    Label("Receive Folder", systemImage: "folder")
                }
                .buttonStyle(.link)
                // Was a plain `Text` worded like a link: it looked actionable
                // and did nothing. Now it goes somewhere real.
                Link(destination: AppLinks.repository) {
                    Label("Star HyperSend on GitHub", systemImage: "star")
                }
                .font(.caption2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: UI.Radius.row)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - Content column

private struct TransfersColumn: View {
    var model: AppModel

    var body: some View {
        Group {
            if model.transfers.isEmpty {
                ContentUnavailableView(
                    "No Transfers Yet",
                    systemImage: "arrow.up.arrow.down",
                    description: Text("Drag files or whole folders in. They go out over every lane at once."),
                )
            } else {
                List(model.transfers.reversed()) { item in
                    TransferRow(item: item)
                        .padding(10)
                        .glassPanel(cornerRadius: UI.Radius.row)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TransferRow: View {
    var item: TransferItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .send ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: UI.Icon.row))
                .foregroundStyle(item.direction == .send ? Color.accentColor : Color.green)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                        .font(UI.TypeScale.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: UI.Space.xs)
                    Text(formattedRate(item.bytesPerSec))
                        .font(UI.TypeScale.rate.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if item.status == .active {
                    ProgressView(value: item.fraction).progressViewStyle(.linear)
                }
                HStack(spacing: 5) {
                    Text(statusLabel)
                        .font(UI.TypeScale.chip)
                        .foregroundStyle(statusTint)
                    Text("· \(formattedBytes(item.bytesDone)) of \(formattedBytes(item.size))")
                        .font(UI.TypeScale.counter.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // The engine goes to real trouble to explain a failure —
                // "sha256 mismatch — file discarded", "data streams ended
                // early". The row used to collapse all of that to the word
                // "Failed" and drop the reason on the floor.
                if let failureReason {
                    Text(failureReason)
                        .font(UI.TypeScale.counter)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(failureReason)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// The reason a transfer failed, when it did.
    private var failureReason: String? {
        guard case .failed(let reason) = item.status, !reason.isEmpty else { return nil }
        return reason
    }

    private var statusLabel: String {
        switch item.status {
        case .queued: return "Queued"
        case .active: return "Transferring"
        case .verifying: return "Verifying"
        case .done: return "Verified"
        case .failed: return "Failed"
        }
    }

    private var statusTint: Color {
        switch item.status {
        case .done: return .green
        case .failed: return .red
        case .queued: return .secondary
        default: return .accentColor
        }
    }
}

// MARK: - Detail column

private struct LanesColumn: View {
    var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.activeTransfer?.name ?? "No transfer in flight")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.activeTransfer == nil
                         ? "Add a lane and chunks are handed to whichever path is free — no scheduler to configure."
                         : laneSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // The two lanes fused into one capsule — the same union the
                // transfer itself performs.
                BondedLaneIndicator(
                    wifiRate: laneRate("wifi"),
                    usbRate: laneRate("usb"),
                    usbReady: model.usbLaneReady,
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Live Lanes").font(.headline)
                    VStack(spacing: 14) {
                        LaneRow(
                            symbol: "wifi",
                            tint: .blue,
                            title: "Wi-Fi",
                            subtitle: model.selectedPeer?.host ?? "discovering…",
                            rate: laneRate("wifi"),
                            fraction: laneFraction("wifi"),
                            active: model.isSending && laneRate("wifi") > 0,
                        )
                        Divider()
                        LaneRow(
                            symbol: "cable.connector",
                            tint: .green,
                            title: "USB cable",
                            subtitle: model.usbLaneReady ? "tunnel 127.0.0.1:\(Proto.usbLocalPort) → :\(Proto.usbDataPort)" : "not connected",
                            rate: laneRate("usb"),
                            fraction: laneFraction("usb"),
                            active: model.isSending && laneRate("usb") > 0,
                        )
                    }
                    .padding(.vertical, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: UI.Radius.panel)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Negative tracking: large type needs its letters pulled in
                    // or it reads as loose and unfinished next to 11 pt body.
                    Text(formattedRate(combinedRate))
                        .font(UI.TypeScale.display.monospacedDigit())
                        .tracking(-0.5)
                    Text("combined").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: UI.Radius.panel)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity").font(.headline)
                    VStack(alignment: .leading, spacing: 3) {
                        if model.logs.isEmpty {
                            Text("Nothing yet.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.logs.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(cornerRadius: UI.Radius.panel)
            }
            .padding(UI.Space.l)
            // Bound the measure, then pin it left: prose and the display figure
            // stop stretching on a wide window, but the column stays anchored.
            .frame(maxWidth: UI.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 56) // room for the dock strip so content never scrolls under it
    }

    private var laneSummary: String {
        let lanes = (model.activeTransfer?.laneRates ?? [:])
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \(formattedRate($0.value))" }
        return lanes.isEmpty ? "scheduling chunks…" : lanes.joined(separator: " + ")
    }

    private func laneRate(_ label: String) -> Double {
        model.activeTransfer?.laneRates[label] ?? 0
    }

    private func laneFraction(_ label: String) -> Double {
        guard let active = model.activeTransfer else { return 0 }
        let laneBytes = active.lanes[label]?.bytes ?? 0
        return active.size > 0 ? min(1, Double(laneBytes) / Double(active.size)) : 0
    }

    private var combinedRate: Double {
        model.activeTransfer?.bytesPerSec ?? 0
    }
}

private struct LaneRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let rate: Double
    let fraction: Double
    let active: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: UI.Icon.lane))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(UI.TypeScale.laneTitle)
                    Text(active ? "active" : (rate > 0 ? "idle" : "standby"))
                        .font(.caption2)
                        .foregroundStyle(active ? tint : Color.secondary)
                    Spacer(minLength: UI.Space.xs)
                    Text(formattedRate(rate))
                        .font(UI.TypeScale.laneRate.monospacedDigit())
                        .foregroundStyle(rate > 0 ? Color.primary : Color.secondary)
                }
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(tint)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Text(model.statusText)
                .font(UI.TypeScale.rate)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if model.queuedCount > 0 {
                Text("\(model.queuedCount) queued")
                    .font(UI.TypeScale.chip.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            Text(model.usbLaneReady ? "USB lane up" : "Wi-Fi only")
                .font(UI.TypeScale.chip)
                .foregroundStyle(model.usbLaneReady ? Color.green : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassCapsule()
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("HyperSend") {
    HyperSendView(model: .previewSeeded())
        .frame(width: 1080, height: 700)
}
#endif
