import AppKit
import SwiftUI

// The window.
//
// This is a utility, so it is built like one. Three things matter, in order of
// how long they matter: which device you are sending to, whether you can drop
// something on it, and how far along the last thing got. Everything else is
// drawn only while it is true — the lane meter exists during a transfer and not
// for a second longer.
//
// Deliberately absent, each of which was in the previous build and each of
// which made a two-button job look like a dashboard: a sidebar for what is
// usually a single device, a stack of glass panels (glass over glass over
// glass), a full-window grain and vignette, and a dock of physics-driven icon
// buttons duplicating what the toolbar and File menu already did.
//
// The whole window is the drop target. That is the one interaction the app has,
// so it is not confined to a small well in the corner of a busy screen.

struct HyperSendView: View {
    @Bindable var model: AppModel
    @State private var dropActive = false

    init(model: AppModel = .shared) {
        self._model = Bindable(model)
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            Divider()
            content
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
        .frame(minWidth: 560, minHeight: 440)
    }

    @ViewBuilder
    private var content: some View {
        if model.transfers.isEmpty {
            EmptyState(model: model)
        } else {
            TransferList(model: model)
        }
    }
}

// MARK: - Header

/// The device you are talking to, and the one button that starts something.
///
/// The device name doubles as the picker's label so this row carries no
/// separate title: with a single device, "which device" is answered by looking
/// at it, and switching is one click when there is more than one.
private struct HeaderBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: UI.Space.xs) {
            Menu {
                if model.peers.isEmpty {
                    Text("No devices found yet")
                } else {
                    ForEach(model.peers, id: \.key) { peer in
                        Button {
                            model.selectedPeerKey = peer.key
                        } label: {
                            Label(peer.name, systemImage: peer.usbReachable ? "cable.connector" : "iphone")
                        }
                    }
                }
                Divider()
                Button("Add Device by IP Address…") { MenuActions.shared.addDevice(nil) }
            } label: {
                deviceLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer(minLength: UI.Space.s)

            Button {
                model.chooseAndSend()
            } label: {
                Text("Send Files…")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedPeer == nil)
            .help(model.selectedPeer == nil ? "No device to send to yet" : "Send files or folders")
        }
        .padding(.horizontal, UI.Space.m)
        .padding(.vertical, UI.Space.s)
    }

    private var deviceLabel: some View {
        HStack(spacing: UI.Space.xs) {
            Image(systemName: model.selectedPeer?.usbReachable == true ? "cable.connector" : "iphone")
                .font(.system(size: UI.Icon.inline, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.selectedPeer?.name ?? "No device selected")
                    .font(UI.Text.row)
                    .foregroundStyle(model.selectedPeer == nil ? .secondary : .primary)
                if let peer = model.selectedPeer {
                    Text(peer.host)
                        .font(UI.Text.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Empty state

/// Shown when nothing has been transferred yet. It is both the invitation and
/// the explanation of where things will go, so it names the device and the
/// lanes rather than saying "no data".
private struct EmptyState: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: UI.Space.m) {
            Image(systemName: "arrow.down")
                .font(.system(size: UI.Icon.hero, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(.quaternary))

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
        .padding(UI.Space.xl)
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

// MARK: - Transfer list

private struct TransferList: View {
    var model: AppModel

    var body: some View {
        List {
            ForEach(model.transfers.reversed()) { item in
                TransferRow(item: item)
                    .listRowSeparator(.visible)
                    .listRowInsets(EdgeInsets(
                        top: UI.Space.s,
                        leading: UI.Space.m,
                        bottom: UI.Space.s,
                        trailing: UI.Space.m,
                    ))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

/// One file. Three lines when it is moving, two when it is settled — the lane
/// meter is not kept around as decoration once it has nothing to say.
private struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        HStack(alignment: .top, spacing: UI.Space.s) {
            Image(systemName: item.direction == .send ? "arrow.up" : "arrow.down")
                .font(.system(size: UI.Icon.row, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.quaternary))

            VStack(alignment: .leading, spacing: UI.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: UI.Space.xs) {
                    Text(item.name)
                        .font(UI.Text.row)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: UI.Space.xs)
                    Text(trailingText)
                        .font(UI.Text.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if isRunning {
                    LaneBar(segments: segments, total: item.size)
                        .help(laneBreakdown)
                }

                if isRunning, segments.count > 1 {
                    laneLegend
                } else {
                    HStack(spacing: UI.Space.xxs) {
                        Text(statusText)
                            .font(UI.Text.tag)
                            .foregroundStyle(statusTint)
                        if let bytesText {
                            Text("·")
                                .font(UI.Text.caption)
                                .foregroundStyle(.tertiary)
                            Text(bytesText)
                                .font(UI.Text.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
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
        }
        .padding(.vertical, 2)
        .animation(.linear(duration: 0.2), value: item.bytesDone)
    }

    // MARK: Derived

    private var isRunning: Bool {
        item.status == .active || item.status == .verifying
    }

    /// Per-lane byte counts in a stable order. A received file has no lane
    /// breakdown — the receiving side sums it without tracking provenance — so
    /// it falls back to a single unlabelled segment.
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

    private var trailingText: String {
        switch item.status {
        case .active, .verifying: return formattedRate(item.bytesPerSec)
        case .done: return item.seconds > 0 ? formattedDuration(item.seconds) : ""
        default: return ""
        }
    }

    private var bytesText: String? {
        switch item.status {
        case .active, .verifying:
            return "\(formattedBytes(item.bytesDone)) of \(formattedBytes(item.size))"
        case .done:
            return formattedBytes(item.size)
        default:
            return nil
        }
    }

    private var statusText: String {
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
        case .failed: return Color(nsColor: .systemRed)
        case .active, .verifying: return .accentColor
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

/// The signature of the app, drawn small: one bar, split by which lane carried
/// what. The split *is* the feature — a single progress bar would be true but
/// would hide the only interesting thing happening.
///
/// Segments are laid out left to right in insertion order, so the widths are
/// literal byte shares of the file and the whole filled run equals the overall
/// progress. The 1.5 pt gap is the only thing that says "two lanes"; without it
/// the meter would read as one solid bar.
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

// MARK: - Status bar

/// One line, always in the same place: what the app is doing on the left, what
/// it is capable of on the right. The previous build repeated the lane state in
/// the sidebar, in the detail pane and in this bar.
private struct StatusBar: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
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
    }

    private var indicatorTint: Color {
        if model.activeTransfer != nil { return .accentColor }
        if model.receiverReady { return Color(nsColor: .systemGreen) }
        return .secondary
    }
}

// MARK: - Drop feedback

/// The whole window is the target, so the feedback is an inset outline rather
/// than a panel: it says "anywhere in here" without covering the content.
private struct DropTargetOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: UI.Radius.well, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: UI.Radius.well, style: .continuous)
                    .fill(Color.accentColor.opacity(0.07)),
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
        .frame(width: 620, height: 520)
}
#endif
