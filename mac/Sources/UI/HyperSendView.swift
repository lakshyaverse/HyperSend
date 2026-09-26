import AppKit
import SwiftUI

// The window, rebuilt in the grammar of the macOS 26 "Icon Composer" window.
//
// One pastel sky scene fills the window. On it float three glass elements:
// a devices sidebar on the left, the transfer surface in the middle (a hero
// drop well when idle, glass transfer cards once things move), and an
// inspector on the right with grouped glass sections.
//
// The model, the engine, the menus and the CLI are untouched: this file only
// reads `AppModel` and draws it. Every behaviour the previous build had —
// whole-window drag-and-drop, queueing, per-lane meter, queue counts — is here.

struct HyperSendView: View {
    @Bindable var model: AppModel
    @State private var dropActive = false

    init(model: AppModel = .shared) {
        self._model = Bindable(model)
    }

    var body: some View {
        ZStack {
            SceneBackdrop()
                .ignoresSafeArea()

            HStack(spacing: UI.Space.s) {
                DeviceSidebar(model: model)
                    .frame(width: 208)

                TransferSurface(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Inspector(model: model)
                    .frame(width: 250)
            }
            .padding(UI.Space.s)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(model: model)
        }
        .overlay {
            if dropActive { DropTargetOutline() }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: dropActive)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.transfers.count)
        .dropDestination(for: URL.self) { urls, _ in
            model.send(urls: urls)
            return true
        } isTargeted: { targeted in
            dropActive = targeted
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - Scene backdrop

/// The pastel sky every glass panel refracts. Three warm blooms over a blue
/// vertical wash; in dark mode the same composition at night values. Faint
/// grain keeps large gradients from banding.
private struct SceneBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let sky = colorScheme == .dark ? Scene.skyStopsDark : Scene.skyStops
        let warm = colorScheme == .dark ? Scene.warmStopsDark : Scene.warmStops
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(
                    stops: sky.map { .init(color: $0.0, location: $0.1) },
                    startPoint: .top, endPoint: .bottom,
                )
                ForEach(Array(warm.enumerated()), id: \.offset) { _, stop in
                    RadialGradient(
                        colors: [stop.0.opacity(stop.1), .clear],
                        center: UnitPoint(x: stop.2.midX, y: stop.2.midY),
                        startRadius: 0,
                        endRadius: max(size.width, size.height) * max(stop.2.width, stop.2.height) * 0.9,
                    )
                    .frame(width: size.width * stop.2.width, height: size.height * stop.2.height)
                    .position(x: size.width * stop.2.midX, y: size.height * stop.2.midY)
                }
            }
            .overlay(Grain().opacity(0.05).allowsHitTesting(false))
        }
    }
}

/// Monochrome noise, generated once, tiled. Scaled down for a fine tooth.
private final class GrainGenerator {
    static let shared = GrainGenerator()
    let image: NSImage

    init() {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 90 ... 255) }
        let grey = bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue,
            )!.makeImage()!
        }
        image = NSImage(cgImage: grey, size: NSSize(width: side, height: side))
    }
}

private struct Grain: View {
    var body: some View {
        Canvas { context, size in
            let pattern = context.resolve(Image(nsImage: GrainGenerator.shared.image))
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    context.draw(pattern, at: CGPoint(x: x + 64, y: y + 64))
                    y += 128
                }
                x += 128
            }
        }
    }
}

// MARK: - Devices sidebar

/// The floating glass sidebar: app title, the device list, add-by-IP. The
/// selected device shows its host; the cable glyph marks a USB-capable peer.
private struct DeviceSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: UI.Space.m) {
            HStack(spacing: UI.Space.xs) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor),
                    )
                Text("HyperSend")
                    .font(UI.Text.section)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("DEVICES")
                    .font(UI.Text.tag)
                    .foregroundStyle(.secondary)

                if model.peers.isEmpty {
                    Text("Scanning for devices on this network…")
                        .font(UI.Text.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.peers, id: \.key) { peer in
                        DeviceRow(
                            peer: peer,
                            selected: model.selectedPeerKey == peer.key,
                        ) {
                            model.selectedPeerKey = peer.key
                        }
                    }
                }

                Button {
                    MenuActions.shared.addDevice(nil)
                } label: {
                    Label("Add by IP Address", systemImage: "plus")
                        .font(UI.Text.caption)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: UI.Space.xxs) {
                Text("Send Files")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("or drop them anywhere")
                    .font(UI.Text.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, UI.Space.s)
            .padding(.vertical, UI.Space.s)
            .background(
                RoundedRectangle(cornerRadius: UI.Radius.control, style: .continuous)
                    .fill(Color.accentColor.opacity(model.selectedPeer == nil ? 0.45 : 1.0)),
            )
            .contentShape(RoundedRectangle(cornerRadius: UI.Radius.control, style: .continuous))
            .onTapGesture { model.chooseAndSend() }
            .disabled(model.selectedPeer == nil)
            .help(model.selectedPeer == nil ? "No device to send to yet" : "Send files or folders")
        }
        .padding(UI.Space.s)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }
}

private struct DeviceRow: View {
    let peer: Peer
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: UI.Space.xs) {
                Image(systemName: peer.usbReachable ? "cable.connector" : "iphone")
                    .font(.system(size: UI.Icon.inline, weight: .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(peer.name)
                        .font(UI.Text.row)
                        .lineLimit(1)
                    Text(peer.host)
                        .font(UI.Text.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, UI.Space.xs)
            .padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: UI.Radius.control, style: .continuous)
                        .fill(Color.white.opacity(0.55))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transfer surface

/// The middle of the window: the hero drop well when idle, transfer cards when
/// something is moving.
private struct TransferSurface: View {
    var model: AppModel

    var body: some View {
        if model.transfers.isEmpty {
            DropWell(model: model)
        } else {
            TransferList(model: model)
        }
    }
}

/// The hero: a tall clear-glass well with the concentric-circle motif from the
/// reference, an arrow, and two lines of copy that name the device and the lanes.
private struct DropWell: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: UI.Space.m) {
            ConcentricRings()
                .frame(width: 168, height: 168)

            VStack(spacing: UI.Space.xxs) {
                Text(headline)
                    .font(UI.Text.hero)
                Text(detail)
                    .font(UI.Text.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: UI.measure)
            }

            if model.selectedPeer == nil {
                Button("Add a Device by IP Address…") {
                    MenuActions.shared.addDevice(nil)
                }
                .buttonStyle(.link)
                .font(UI.Text.body)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassHero(cornerRadius: UI.Radius.panel)
    }

    private var headline: String {
        model.selectedPeer == nil ? "No device yet" : "Drop files to send"
    }

    private var detail: String {
        guard let peer = model.selectedPeer else {
            return "HyperSend is listening for another HyperSend device on this network. You can also add one by its IP address."
        }
        let lanes = model.usbLaneReady ? "Wi-Fi and the USB cable" : "Wi-Fi"
        return "They go to \(peer.name) over \(lanes), and every byte is SHA-256 verified before it is written."
    }
}

/// Concentric frosted rings around a glowing core — the reference image's
/// mark, drawn with materials so the scene refracts through it.
private struct ConcentricRings: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                .frame(width: 160, height: 160)
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
                .frame(width: 108, height: 108)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.95), .white.opacity(0.25)],
                        center: .top, startRadius: 4, endRadius: 64,
                    ),
                )
                .frame(width: 56, height: 56)
                .shadow(color: .white.opacity(0.65), radius: 14)
            Image(systemName: "arrow.down")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
        }
    }
}

// MARK: - Transfer list

private struct TransferList: View {
    var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: UI.Space.xs) {
                ForEach(model.transfers.reversed()) { item in
                    TransferCard(item: item)
                }
            }
            .padding(UI.Space.xxs)
        }
    }
}

/// One file as a glass card. Three lines when it is moving, two when it is
/// settled — the lane meter disappears once it has nothing to say.
private struct TransferCard: View {
    let item: TransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: UI.Space.xs) {
            HStack(alignment: .center, spacing: UI.Space.xs) {
                Image(systemName: item.direction == .send ? "arrow.up" : "arrow.down")
                    .font(.system(size: UI.Icon.row, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.accentColor.opacity(0.85)))

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name)
                        .font(UI.Text.row)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.peerName)
                        .font(UI.Text.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: UI.Space.xs)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(statusText)
                        .font(UI.Text.tag)
                        .foregroundStyle(statusTint)
                    if let bytesText {
                        Text(bytesText)
                            .font(UI.Text.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isRunning {
                LaneBar(segments: segments, total: item.size)
                    .help(laneBreakdown)
                if segments.count > 1 {
                    laneLegend
                }
            }

            if let reason = failureReason {
                Text(reason)
                    .font(UI.Text.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(reason)
            }
        }
        .padding(UI.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .animation(.linear(duration: 0.2), value: item.bytesDone)
    }

    // MARK: Derived

    private var isRunning: Bool {
        item.status == .active || item.status == .verifying
    }

    private var segments: [LaneSegment] {
        let lanes = item.lanes
        guard !lanes.isEmpty else {
            return [LaneSegment(label: "", bytes: max(item.bytesDone, 0))]
        }
        let known = UI.Lane.order.filter { lanes[$0] != nil }
        let others = lanes.keys.filter { !UI.Lane.order.contains($0) }.sorted()
        return (known + others).compactMap { key in
            lanes[key].map { LaneSegment(label: key, bytes: $0.bytes) }
        }
    }

    private var laneLegend: some View {
        HStack(spacing: UI.Space.s) {
            ForEach(segments) { segment in
                HStack(spacing: 5) {
                    Circle()
                        .fill(UI.Lane.tint(segment.label))
                        .frame(width: 6, height: 6)
                    Text(UI.Lane.name(segment.label))
                        .font(UI.Text.caption)
                        .foregroundStyle(.secondary)
                    Text(formattedRate(item.laneRates[segment.label] ?? 0))
                        .font(UI.Text.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var laneBreakdown: String {
        segments
            .map { "\(UI.Lane.name($0.label)) \(formattedBytes($0.bytes))" }
            .joined(separator: " · ")
    }

    private var bytesText: String? {
        switch item.status {
        case .active, .verifying:
            return "\(formattedBytes(item.bytesDone)) of \(formattedBytes(item.size))"
        case .done:
            return item.seconds > 0
                ? "\(formattedBytes(item.size)) · \(formattedDuration(item.seconds))"
                : formattedBytes(item.size)
        default:
            return nil
        }
    }

    private var statusText: String {
        switch item.status {
        case .queued: return "Queued"
        case .active: return formattedRate(item.bytesPerSec)
        case .verifying: return "Verifying"
        case .done: return "Verified"
        case .failed: return "Failed"
        }
    }

    private var statusTint: Color {
        switch item.status {
        case .failed: return Color(nsColor: .systemRed)
        case .active, .verifying: return .accentColor
        case .done: return .primary
        default: return .secondary
        }
    }

    private var failureReason: String? {
        guard case .failed(let reason) = item.status, !reason.isEmpty else { return nil }
        return reason
    }
}

// MARK: - Lane meter

private struct LaneSegment: Identifiable {
    let label: String
    let bytes: Int64
    var id: String { label }
}

/// One bar, split by which lane carried what. The split *is* the feature.
private struct LaneBar: View {
    let segments: [LaneSegment]
    let total: Int64

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let denominator = CGFloat(max(total, 1))
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(UI.Lane.tint(segment.label))
                        .frame(width: max(0, width * CGFloat(segment.bytes) / denominator))
                }
            }
        }
        .frame(height: 5)
        .background(Rectangle().fill(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: UI.Radius.bar, style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Inspector

/// The right-hand glass panel: transfer activity, then "Lanes" and "Receive"
/// sections in the reference window's grouped-card grammar.
private struct Inspector: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UI.Space.s) {
                inspectorSection("Activity") {
                    if model.transfers.isEmpty {
                        Text("Nothing in flight.")
                            .font(UI.Text.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        let active = model.transfers.filter { !$0.status.isTerminal }
                        let done = model.transfers.filter(\.status.isTerminal)
                        HStack {
                            Text("\(active.count) active")
                                .font(UI.Text.caption)
                            Spacer()
                            Text("\(done.count) done")
                                .font(UI.Text.caption)
                                .foregroundStyle(.secondary)
                        }
                        if model.queuedCount > 0 {
                            Text("\(model.queuedCount) queued")
                                .font(UI.Text.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                inspectorSection("Lanes") {
                    laneRow("Wi-Fi", ready: true, detail: "always available")
                    laneRow(
                        "USB cable",
                        ready: model.usbLaneReady,
                        detail: model.usbLaneReady ? "tunnel open" : "not connected",
                    )
                }

                inspectorSection("Receive") {
                    HStack {
                        Text("Folder")
                            .font(UI.Text.caption)
                        Spacer()
                        Text(model.receiveDirectory.lastPathComponent)
                            .font(UI.Text.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                            .buttonStyle(.link)
                            .font(UI.Text.caption)
                    }
                    HStack {
                        Text("Received")
                            .font(UI.Text.caption)
                        Spacer()
                        Text("\(model.receivedCount)")
                            .font(UI.Text.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Accept automatically", isOn: $model.autoAccept)
                        .font(UI.Text.caption)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            .padding(UI.Space.s)
        }
        .glassPanel()
    }

    private func inspectorSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: UI.Space.xs) {
            Text(title)
                .font(UI.Text.section)
            content()
        }
        .padding(UI.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func laneRow(_ name: String, ready: Bool, detail: String) -> some View {
        HStack {
            Text(name)
                .font(UI.Text.caption)
            Spacer()
            Circle()
                .fill(ready ? Color(nsColor: .systemGreen) : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(detail)
                .font(UI.Text.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = model.receiveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.receiveDirectory = url
        UserDefaults.standard.set(url.path, forKey: Pref.receivePath)
        model.log("receive folder → \(url.path)")
    }
}

// MARK: - Status bar

/// One line at the bottom: what the app is doing, what it is capable of. Drawn
/// on the scene, no material of its own.
private struct StatusBar: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: UI.Space.xs) {
            Circle()
                .fill(indicatorTint)
                .frame(width: 6, height: 6)

            Text(model.statusText)
                .font(UI.Text.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: UI.Space.xs)

            if model.queuedCount > 0 {
                Text("\(model.queuedCount) queued")
                    .font(UI.Text.caption)
                    .foregroundStyle(.secondary)
            }

            Text(model.usbLaneReady ? "Wi-Fi + USB" : "Wi-Fi")
                .font(UI.Text.caption)
                .foregroundStyle(model.usbLaneReady ? .primary : .secondary)
                .help(model.usbLaneReady
                      ? "The USB cable is acting as a second lane"
                      : "Only the Wi-Fi lane is up")
        }
        .padding(.horizontal, UI.Space.m)
        .padding(.vertical, UI.Space.xs)
    }

    private var indicatorTint: Color {
        if model.activeTransfer != nil { return .accentColor }
        if model.receiverReady { return Color(nsColor: .systemGreen) }
        return .secondary
    }
}

// MARK: - Drop feedback

/// The whole window is the target; an inset glass-bright outline says
/// "anywhere in here" without covering the content.
private struct DropTargetOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: UI.Radius.panel, style: .continuous)
            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: UI.Radius.panel, style: .continuous)
                    .fill(.white.opacity(0.10)),
            )
            .padding(5)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("HyperSend") {
    HyperSendView(model: .previewSeeded())
        .frame(width: 860, height: 560)
}
#endif
