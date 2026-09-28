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
//
// Motion lives in `Animations.swift` and follows one rule: glass is a solid
// with a memory. It bends, overshoots, and rings down; it never snaps. A drop
// sends a radial ripple through every panel from the exact landing point, the
// toggle's knob squishes and aftershakes, cards settle in with a keyframed
// entrance, and idle glass breathes.

struct HyperSendView: View {
    @Bindable var model: AppModel
    @State private var dropActive = false
    /// The last drop: landing point (in window space) plus an order counter,
    /// so two drops on the same pixel still re-trigger the ripple.
    @State private var dropImpact: DropImpact?
    @State private var dropOrder = 0
    /// Increments every time a send is queued — drives the send button's
    /// keyframed sheen sweep.
    @State private var sendPulse = 0

    init(model: AppModel = .shared) {
        self._model = Bindable(model)
    }

    var body: some View {
        ZStack {
            // The water: while a drop ripple runs, the backdrop's light
            // sources are displaced by the travelling wave and the crest
            // rings sweep beneath the glass — see SceneBackdrop.
            SceneBackdrop()
                .ignoresSafeArea()

            // One container for every glass shape in the window: neighbouring
            // panels lens as a group, the way the system's own chrome does.
            // (Local containers still nest inside — the magnetic button keeps
            // its own so its chrome flexes on press.)
            Group {
                if #available(macOS 26.0, *) {
                    GlassEffectContainer {
                        content
                    }
                } else {
                    content
                }
            }
            .padding(UI.Space.s)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar(model: model)
        }
        // The named space sits on the same node `dropDestination` measures
        // its location against, so panels convert the drop point with no
        // offset — one event, window-wide jiggle.
        .coordinateSpace(name: RippleSpace.name)
        .overlay {
            ZStack {
                if dropActive { DropTargetOutline() }
                // The splash: expanding ring, droplet crown, core flash at
                // the exact landing point. The wave itself lives behind the
                // glass, in the backdrop.
                if let impact = dropImpact {
                    RefractionBurst(impact: impact)
                        .position(x: impact.point.x, y: impact.point.y)
                        .id(impact)
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: dropActive)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: model.transfers.count)
        .dropDestination(for: URL.self) { urls, location in
            // `location` arrives in this view's own coordinates — the named
            // ripple space — in points. Panels read it directly; the shader
            // scales it to pixels itself.
            dropOrder += 1
            let impact = DropImpact(point: location, order: dropOrder)
            dropImpact = impact
            // The bus drives the whole-window Metal refraction; `dropImpact`
            // drives the per-panel wobble and the splash.
            RippleController.shared.fire(at: location)
            sendPulse += 1
            model.send(urls: urls)
            return true
        } isTargeted: { targeted in
            dropActive = targeted
        }
        .onChange(of: dropActive) {
            // A completed drag does not always deliver a final `false`, and a
            // highlight that outlives the drag reads as a broken window. A
            // new drag starting also clears the last impact's stale rings.
            if dropActive { dropImpact = nil }
        }
        .frame(minWidth: 760, minHeight: 480)
        // Testing hook (HS_SIM_DROP): runs the identical visual path a real
        // drop runs — impact bus, panel wobble, splash — at a posted point.
        .onReceive(NotificationCenter.default.publisher(for: .hyperSendSimDrop)) { note in
            guard let point = note.userInfo?["point"] as? CGPoint else { return }
            dropOrder += 1
            dropImpact = DropImpact(point: point, order: dropOrder)
            RippleController.shared.fire(at: point)
            sendPulse += 1
        }
    }

    /// Everything that floats on the scene, extracted so the availability
    /// branch above stays a one-liner.
    private var content: some View {
        HStack(spacing: UI.Space.s) {
            DeviceSidebar(model: model, sendPulse: sendPulse)
                .frame(width: 208)
                .glassRipple(impact: dropImpact, intensity: 0.7)

            TransferSurface(model: model, impact: dropImpact)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassRipple(impact: dropImpact)

            Inspector(model: model)
                .frame(width: 250)
                .glassRipple(impact: dropImpact, intensity: 0.6)
        }
    }
}

// MARK: - Scene backdrop

/// Bisect helper kept for recordings: flattens a subtree into one layer.
struct BackdropFlatten: ViewModifier {
    func body(content: Content) -> some View {
        if RefractionFlags.flattenBackdrop {
            content.compositingGroup()
        } else {
            content
        }
    }
}

/// The pastel sky every glass panel refracts.
///
/// At rest it draws live gradients. While a drop ripple runs, a Canvas
/// redraws the same scene with the wave applied in *light*: each bloom (the
/// scene's light source) is displaced by the travelling wavefront, and a
/// bright crest ring with a dark trough sweep outward beneath the glass —
/// the panels lens a scene whose light is visibly moving, which reads as the
/// glass bending.
///
/// This is drawn directly rather than through a Metal effect deliberately:
/// SwiftUI's `distortionEffect`/`layerEffect` pipelines mangle colour on
/// this OS build (a measured, uniform double-gamma wash, independent of
/// input), and the wave is simple enough to evaluate on the CPU per frame.
private struct SceneBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    var controller: RippleController = .shared

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let sky = colorScheme == .dark ? Scene.skyStopsDark : Scene.skyStops
            let warm = colorScheme == .dark ? Scene.warmStopsDark : Scene.warmStops

            if !RefractionFlags.shaderDisabled {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !controller.hasImpact)) { timeline in
                    let elapsed = controller.hasImpact
                        ? timeline.date.timeIntervalSince(controller.firedAt)
                        : 0.0
                    let running = controller.hasImpact
                        && elapsed >= 0
                        && elapsed < RippleController.duration
                    ZStack {
                        rippleCanvas(sky: sky, warm: warm, size: size, elapsed: running ? elapsed : nil)
                        if !RefractionFlags.grainDisabled {
                            Grain().opacity(0.05).allowsHitTesting(false)
                        }
                    }
                }
            } else {
                rippleCanvas(sky: sky, warm: warm, size: size, elapsed: nil)
                    .overlay {
                        if !RefractionFlags.grainDisabled {
                            Grain().opacity(0.05).allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    /// The scene, with the drop wave applied when `elapsed` is non-nil.
    /// Blooms are the scene's light: displacing them along the wavefront is
    /// what makes the glass above read as bending.
    private func rippleCanvas(sky: [(Color, CGFloat)], warm: [(Color, CGFloat, CGRect)], size: CGSize, elapsed: Double?) -> some View {
        Canvas { context, canvasSize in
            // Sky: the vertical wash, as always.
            context.fill(
                Path(CGRect(origin: .zero, size: canvasSize)),
                with: .linearGradient(
                    Gradient(stops: sky.map { .init(color: $0.0, location: $0.1) }),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: canvasSize.height),
                ),
            )

            if let elapsed {
                let (radius, energy) = DropWave.state(at: elapsed)
                // Crest + trough rings: the wavefront's body, sweeping out
                // beneath the glass.
                if RefractionFlags.lightDisabled == false, energy > 0.004 {
                    let troughRect = CGRect(
                        x: controller.origin.x - radius + 24,
                        y: controller.origin.y - radius + 24,
                        width: (radius - 24) * 2,
                        height: (radius - 24) * 2,
                    )
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 10))
                        layer.stroke(
                            Path(ellipseIn: troughRect),
                            with: .color(.black.opacity(0.07 * energy)),
                            lineWidth: 16,
                        )
                    }
                    let crestRect = CGRect(
                        x: controller.origin.x - radius,
                        y: controller.origin.y - radius,
                        width: radius * 2,
                        height: radius * 2,
                    )
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 12))
                        layer.stroke(
                            Path(ellipseIn: crestRect),
                            with: .color(.white.opacity(0.15 * energy)),
                            lineWidth: 24,
                        )
                    }
                }
                // Blooms ride the wave: displaced along the direction from
                // the impact, by the ring's displacement at their centre.
                for stop in warm {
                    let centre = CGPoint(x: stop.2.midX * canvasSize.width, y: stop.2.midY * canvasSize.height)
                    let shifted = DropWave.displaced(centre, origin: controller.origin, radius: radius, energy: energy)
                    drawBloom(context: context, stop: stop, centre: shifted, size: canvasSize)
                }
            } else {
                for stop in warm {
                    let centre = CGPoint(x: stop.2.midX * canvasSize.width, y: stop.2.midY * canvasSize.height)
                    drawBloom(context: context, stop: stop, centre: centre, size: canvasSize)
                }
            }
        }
    }

    /// One full-bleed bloom: a radial wash centred where its rect sits, with
    /// a mid stop melting the falloff so it fades into the sky instead of
    /// stopping at a border. Framing these used to clip the gradient while
    /// it was still visibly coloured — the boxy edges.
    private func drawBloom(context: GraphicsContext, stop: (Color, CGFloat, CGRect), centre: CGPoint, size: CGSize) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: stop.0.opacity(stop.1), location: 0),
                    .init(color: stop.0.opacity(stop.1 * 0.35), location: 0.4),
                    .init(color: .clear, location: 1.0),
                ]),
                center: centre,
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.75,
            ),
        )
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
    /// Drives the send button's keyframed sheen sweep; owned by the root so a
    /// drop can fire it too.
    var sendPulse: Int = 0

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

                Spacer(minLength: 0)

                // Settings live in this window's face, not only in the menu
                // bar: nobody finds ⌘, on their own.
                Button {
                    MenuActions.shared.openSettings(nil)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassChip(cornerRadius: UI.Radius.control)
                .help("Settings")
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
                    ForEach(Array(model.peers.enumerated()), id: \.element.key) { index, peer in
                        DeviceRow(
                            peer: peer,
                            selected: model.selectedPeerKey == peer.key,
                        ) {
                            model.selectedPeerKey = peer.key
                        }
                        .glassEntrance(delay: Double(index) * 0.05)
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

            // Magnetic glass send button: real Liquid Glass, and it leans a
            // few points toward the cursor while tracked, snapping back on
            // exit. The physics is feedback, not decoration.
            MagneticGlassButton {
                model.chooseAndSend()
            } label: {
                VStack(alignment: .leading, spacing: UI.Space.xxs) {
                    Text("Send Files")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("or drop them anywhere")
                        .font(UI.Text.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, UI.Space.s)
                .padding(.vertical, UI.Space.s)
            }
            .disabled(model.selectedPeer == nil)
            .opacity(model.selectedPeer == nil ? 0.55 : 1)
            .modifier(SheenSweep(trigger: sendPulse, cornerRadius: UI.Radius.control))
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
        button
            .selectionPop(trigger: selected)
    }

    private var button: some View {
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
            // Selected rows are their own floating lens over the panel glass,
            // the way the system marks selection in its chrome. The glass goes
            // on a clear host — a shape here would paint its own fill on top.
            .background {
                if selected {
                    Color.clear
                        .glassSelection(cornerRadius: UI.Radius.control)
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
    var impact: DropImpact?

    var body: some View {
        if model.transfers.isEmpty {
            DropWell(model: model)
        } else {
            TransferList(model: model, impact: impact)
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
                .ambientBreath(depth: 0.014)
                .bob(amplitude: 3, period: 1.15)

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
    var impact: DropImpact?

    var body: some View {
        ScrollView {
            VStack(spacing: UI.Space.xs) {
                ForEach(Array(model.transfers.reversed().enumerated()), id: \.element.id) { index, item in
                    TransferCard(item: item, impact: impact)
                        .glassEntrance(delay: Double(index) * 0.05)
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
    var impact: DropImpact?
    /// Counts up on every status change — triggers the verified sheen sweep.
    @State private var statusCount = 0

    var body: some View {
        card
            .glassRipple(impact: impact, intensity: 0.45)
    }

    private var card: some View {
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
                    .overlay(LaneShimmer().clipShape(RoundedRectangle(cornerRadius: UI.Radius.bar, style: .continuous)))
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
        .modifier(SheenSweep(trigger: statusCount, cornerRadius: UI.Radius.card))
        .onChange(of: item.status) {
            // Every milestone — queued → active, active → verifying, verifying
            // → done/failed — sends one sweep of light across the card.
            statusCount += 1
        }
    }

    // MARK: Derived

    private var isRunning: Bool {
        item.status == .active || item.status == .verifying
    }

    private var segments: [LaneSegment] {
        TransferDisplay.laneSegments(item)
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
                        .modifier(StatusPulse(trigger: item.laneRates[segment.label] ?? 0))
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
        meter
            // A late segment joining the split slides the existing ones over
            // instead of teleporting them.
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: segments.map(\.label))
    }

    private var meter: some View {
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
                    ActivityCounter(model: model)
                }

                inspectorSection("In flight") {
                    if model.transfers.isEmpty {
                        Text("Nothing in flight.")
                            .font(UI.Text.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: UI.Space.s) {
                            ForEach(Array(model.transfers.reversed().prefix(4).enumerated()), id: \.element.id) { index, item in
                                TransferProgressRow(item: item)
                                    .glassEntrance(delay: Double(index) * 0.05)
                            }
                        }
                    }
                }

                inspectorSection("Lanes") {
                    laneRow("Wi-Fi", ready: true, detail: "always available")
                    laneRow(
                        "USB cable",
                        ready: model.usbLaneReady && model.usbLaneEnabled,
                        detail: !model.usbLaneEnabled
                            ? "switched off — Wi-Fi only"
                            : model.usbLaneReady ? "tunnel open" : "not connected",
                    )
                    .modifier(StatusPulse(trigger: model.usbLaneReady && model.usbLaneEnabled))
                    Toggle("Bond USB lane", isOn: $model.usbLaneEnabled)
                        .font(UI.Text.caption)
                        .toggleStyle(.glass)
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
                        .toggleStyle(.glass)
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
                .modifier(StatusPulse(trigger: ready))
            Text(detail)
                .font(UI.Text.caption)
                .foregroundStyle(.secondary)
                .modifier(StatusPulse(trigger: detail))
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

/// One line at the bottom: what the app is doing, what it is capable of. The
/// right side carries the footer credit and the one honest way to support the
/// work, because both belong where the eye already goes.
private struct StatusBar: View {
    var model: AppModel
    @State private var hoverCoffee = false

    var body: some View {
        HStack(spacing: UI.Space.xs) {
            Circle()
                .fill(indicatorTint)
                .frame(width: 6, height: 6)
                .modifier(StatusPulse(trigger: indicatorTint))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: indicatorTint)

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

            Text("·")
                .foregroundStyle(.tertiary)

            Text("Made with love by Lakshya")
                .font(UI.Text.caption)
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Link(destination: URL(string: "https://buymeacoffee.com/lakshyaverse")!) {
                HStack(spacing: 4) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text("Buy me a coffee")
                        .font(UI.Text.caption)
                }
                .foregroundStyle(hoverCoffee ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    if hoverCoffee {
                        Capsule().fill(.white.opacity(0.14))
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hoverCoffee = $0 }
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

// MARK: - Activity counter

/// "N active · N done". Extracted so it owns its own pulse trigger: the
/// counts pop in place whenever activity changes, instead of silently
/// swapping digits. Reads the model; owns no behaviour.
private struct ActivityCounter: View {
    var model: AppModel

    var body: some View {
        Group {
            if model.transfers.isEmpty {
                Text("Nothing in flight.")
                    .font(UI.Text.caption)
                    .foregroundStyle(.secondary)
            } else {
                let active = model.transfers.filter { !$0.status.isTerminal }
                let done = model.transfers.filter(\.status.isTerminal)
                VStack(alignment: .leading, spacing: UI.Space.xxs) {
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
                .modifier(StatusPulse(trigger: model.transfers.map(\.status)))
            }
        }
    }
}

// MARK: - In-flight progress

/// Derived display values shared by the transfer card and the inspector's
/// in-flight rows, so both surfaces always agree on what a transfer says.
private enum TransferDisplay {
    static func percentText(_ item: TransferItem) -> String {
        "\(Int((item.fraction * 100).rounded()))%"
    }

    static func laneSegments(_ item: TransferItem) -> [LaneSegment] {
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
}

/// One line per file in flight: direction glyph, name, lane meter, percent
/// right-aligned — the transfer card's grammar at the inspector's scale, so
/// progress is readable at a glance without watching the middle of the
/// window. Reads the model; owns no behaviour.
private struct TransferProgressRow: View {
    let item: TransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: UI.Space.xxs) {
                Image(systemName: item.direction == .send ? "arrow.up" : "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color.accentColor.opacity(0.85)))

                Text(item.name)
                    .font(UI.Text.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: UI.Space.xxs)

                Text(TransferDisplay.percentText(item))
                    .font(UI.Text.caption.monospacedDigit())
                    .foregroundStyle(statusTint)
            }

            LaneBar(segments: TransferDisplay.laneSegments(item), total: item.size)

            HStack {
                Text(item.peerName)
                    .font(UI.Text.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(statusText)
                    .font(UI.Text.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(StatusPulse(trigger: item.status))
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
}

// MARK: - Liquid Glass button + magnetic feel

/// A button on real system Liquid Glass. On macOS 26+ the label is wrapped in
/// a GlassEffectContainer with `.buttonStyle(.glass)` chrome so the material
/// refracts the scene behind it; earlier systems get the frosted fallback.
struct MagneticGlassButton<Action: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Action

    @State private var hover = false
    @State private var lean: CGSize = .zero
    @State private var pressCount = 0

    var body: some View {
        base
            .pressJiggle(trigger: pressCount)
    }

    private var base: some View {
        Group {
            if #available(macOS 26.0, *) {
                glass(button)
            } else {
                button
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: UI.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: UI.Radius.control, style: .continuous)
                            .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                    }
            }
        }
        .scaleEffect(hover ? 1.02 : 1)
        .offset(lean)
        .onHover { hovering in
            hover = hovering
            // Lean subtly upward while hovered; springs snap it back on exit.
            lean = hovering ? CGSize(width: 0, height: -2) : .zero
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: lean)
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func glass<Content: View>(_ content: Content) -> some View {
        GlassEffectContainer {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: UI.Radius.control, style: .continuous))
        }
    }

    /// A real `Button`, not a tap gesture: Space and Return fire it once it is
    /// focused, `.disabled` from the caller actually stops the action, and
    /// VoiceOver reads it as a button.
    private var button: some View {
        Button {
            pressCount += 1
            action()
        } label: {
            label()
                .contentShape(RoundedRectangle(cornerRadius: UI.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private extension CGSize {
    /// Clamp both axes so the lean stays subtle.
    func clamped(to limit: CGFloat) -> CGSize {
        CGSize(width: min(max(width, -limit), limit), height: min(max(height, -limit), limit))
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

// MARK: - Drop splash

/// The splash at the impact point, drawn above everything: an expanding ring,
/// a crown of droplets bursting outward, and the core flash. The refraction
/// (the bending itself) is the Metal layer; this is the water answering —
/// fast, bright, gone. Every piece is keyframed once per drop; `.id(impact)`
/// at the call site re-inserts the whole burst per drop.
private struct RefractionBurst: View {
    let impact: DropImpact

    var body: some View {
        ZStack {
            SplashRing()
            ForEach(SplashDroplet.crown) { droplet in
                SplashDropletView(droplet: droplet)
            }
            SplashCore()
        }
        .frame(width: 220, height: 220)
        .allowsHitTesting(false)
    }
}

/// One droplet's ballistic angle, range, size and stagger. Hand-laid so the
/// crown is identical every time — designed, not noisy.
private struct SplashDroplet: Identifiable {
    let id: Int
    let angle: Double
    let distance: CGFloat
    let size: CGFloat
    let delay: Double

    static let crown: [SplashDroplet] = [
        SplashDroplet(id: 0, angle: 0.00, distance: 40, size: 4.5, delay: 0.00),
        SplashDroplet(id: 1, angle: 0.85, distance: 30, size: 3.0, delay: 0.02),
        SplashDroplet(id: 2, angle: 1.65, distance: 44, size: 5.0, delay: 0.01),
        SplashDroplet(id: 3, angle: 2.45, distance: 28, size: 3.5, delay: 0.04),
        SplashDroplet(id: 4, angle: 3.20, distance: 42, size: 4.0, delay: 0.00),
        SplashDroplet(id: 5, angle: 4.00, distance: 32, size: 3.0, delay: 0.03),
        SplashDroplet(id: 6, angle: 4.80, distance: 46, size: 5.5, delay: 0.02),
        SplashDroplet(id: 7, angle: 5.60, distance: 30, size: 3.5, delay: 0.05),
    ]
}

/// The expanding ring: the wavefront's birth, brighter and faster than the
/// shader crest it hands off to.
private struct SplashRing: View {
    private struct RingShape {
        var scale: CGFloat = 0.12
        var opacity: Double = 0.85
    }

    @State private var play = 0

    var body: some View {
        Circle()
            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
            .frame(width: 120, height: 120)
            .keyframeAnimator(initialValue: RingShape(), trigger: play) { ring, value in
                ring
                    .scaleEffect(value.scale)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.85, duration: 0.05)
                    LinearKeyframe(0.0, duration: 0.45)
                }
            }
            .onAppear { play += 1 }
    }
}

/// A droplet popping outward along its angle and fading as it flies.
private struct SplashDropletView: View {
    let droplet: SplashDroplet

    private struct Flight {
        var progress: CGFloat = 0
        var opacity: Double = 0
    }

    @State private var play = 0

    var body: some View {
        Circle()
            .fill(.white.opacity(0.9))
            .frame(width: droplet.size, height: droplet.size)
            .shadow(color: .white.opacity(0.6), radius: 2)
            .keyframeAnimator(initialValue: Flight(), trigger: play) { drop, value in
                drop
                    .offset(
                        x: cos(droplet.angle) * droplet.distance * value.progress,
                        y: sin(droplet.angle) * droplet.distance * value.progress,
                    )
                    .opacity(value.opacity)
                    .scaleEffect(1 - 0.4 * value.progress)
            } keyframes: { _ in
                KeyframeTrack(\.progress) {
                    LinearKeyframe(0, duration: droplet.delay)
                    SpringKeyframe(1.0, duration: 0.42, spring: .bouncy)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1.0, duration: droplet.delay + 0.04)
                    LinearKeyframe(0.0, duration: 0.38)
                }
            }
            .onAppear { play += 1 }
    }
}

/// The core flash where the drop landed — brightest at t=0, gone in a third
/// of a second.
private struct SplashCore: View {
    private struct Flash {
        var scale: CGFloat = 0.3
        var opacity: Double = 0
    }

    @State private var play = 0

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white.opacity(0.95), .white.opacity(0)],
                    center: .center, startRadius: 1, endRadius: 26,
                ),
            )
            .frame(width: 52, height: 52)
            .keyframeAnimator(initialValue: Flash(), trigger: play) { core, value in
                core
                    .scaleEffect(value.scale)
                    .opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1.0, duration: 0.05)
                    LinearKeyframe(0.0, duration: 0.3)
                }
            }
            .onAppear { play += 1 }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("HyperSend") {
    HyperSendView(model: .previewSeeded())
        .frame(width: 860, height: 560)
}
#endif
