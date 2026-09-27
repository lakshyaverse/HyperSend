import SwiftUI
import Observation

// MARK: - Keyframed glass animations
//
// One file owns every motion in the app so the feel stays one feel. The
// physics metaphor throughout: glass is a solid with a memory — it bends,
// overshoots, and rings down, never snapping.
//
// A drop is two coordinated systems:
//
//   * Whole-window refraction (`DropRefractionModifier` + `Shaders.metal`):
//     a Metal distortion effect warps the *rendered pixels* of everything —
//     scene, panels, glass, chrome — as a travelling ring wavefront from the
//     drop point. Light genuinely bends: the sky smears, rims bow, text
//     wobbles. A synced SwiftUI light layer paints the crest highlight, the
//     trough shadow and the impact bloom.
//   * Per-panel wobble (`DropRippleEffect`): each glass panel is physically
//     pushed, heaved and squash-and-stretched, strongest where the drop
//     landed, falling off with distance — the panels are objects floating on
//     the water that the shader ripples.
//
//   * Toggle — a custom `ToggleStyle` on real glass; the knob squishes and
//     aftershakes on a KeyframeTrack timeline.
//   * Entrances, press jiggle, sheen sweeps, status pulses — all keyframed.
//
// Nothing here touches AppModel: pure presentation, so the engine stays
// logic-free and the views stay read-and-draw.

// MARK: - Ripple bus

/// The drop event bus. Views read it to run their piece of the choreography;
/// `HyperSendView` fires it from the real drop handler (or the test hook).
/// One fire, whole-window response.
@Observable
final class RippleController {
    static let shared = RippleController()

    /// Counts up per drop; anything keyed on it re-plays.
    private(set) var impactID = 0
    /// Drop point in the window's own coordinate space (what
    /// `dropDestination` hands over).
    private(set) var origin: CGPoint = .zero
    /// When the drop landed — the shader's clock zero.
    private(set) var firedAt: Date = .distantPast

    var hasImpact: Bool { impactID > 0 }

    /// The wave's travel distance in points; the shader scales it for Retina.
    static let maxRadius: CGFloat = 430
    /// Seconds the full refraction choreography runs.
    static let duration: Double = 1.6

    func fire(at point: CGPoint) {
        origin = point
        firedAt = Date()
        impactID += 1
    }
}

// MARK: - Drop impact

/// Debug/tuning switches: the refraction is two independent systems (the
/// Metal warp on the backdrop, the light overlay above the glass), so each
/// can be silenced from the environment to attribute any visual artifact to
/// one or the other during screen recordings.
enum RefractionFlags {
    static let shaderDisabled = ProcessInfo.processInfo.environment["HS_NO_SHADER"] == "1"
    static let lightDisabled = ProcessInfo.processInfo.environment["HS_NO_LIGHT"] == "1"
    /// Bisecting the backdrop wash: is the grain overlay's view-level alpha
    /// the part that flattens badly inside the effect's offscreen?
    static let grainDisabled = ProcessInfo.processInfo.environment["HS_NO_GRAIN"] == "1"
    /// Composites the backdrop subtree into one layer before the warp.
    static let flattenBackdrop = ProcessInfo.processInfo.environment["HS_FLATTEN"] == "1"
}

/// The coordinate space drops are measured in: the main window's own.
enum RippleSpace {
    static let name = "HyperSendDropSpace"
}

/// One drop, identified: where it landed plus a counter, so two drops on the
/// same pixel still re-trigger the ripple.
struct DropImpact: Equatable, Hashable {
    var point: CGPoint
    var order: Int
}

extension Notification.Name {
    /// Testing hook: posted by the `HS_SIM_DROP` launch path to run the exact
    /// visual choreography of a real drop at a given point, without files.
    static let hyperSendSimDrop = Notification.Name("HyperSendSimDrop")
}

// MARK: - Drop wave maths

/// The travelling wavefront, evaluated on the CPU. The scene's blooms (its
/// light sources) are displaced along this wave and the crest/trough rings
/// sweep with it — the glass above lenses a scene whose light visibly
/// moves, which reads as the glass bending. Pure maths, no shader: SwiftUI's
/// effect pipelines mangle colour on this OS build (a measured uniform
/// double-gamma wash, independent of input), and this wave is simple enough
/// to evaluate per frame on the CPU.
enum DropWave {
    /// Wavefront radius and remaining energy at `elapsed` seconds.
    static func state(at elapsed: Double) -> (radius: CGFloat, energy: Double) {
        let clamped = min(elapsed / 1.5, 1.0)
        // Fast start, long ease-out tail.
        let radius = RippleController.maxRadius * (1 - pow(1 - clamped, 3))
        // Exponential decay with a hard cut.
        let energy = exp(-elapsed * 2.1) * (1 - smoothstep(0, 1.45, elapsed))
        return (radius, energy)
    }

    /// Displaces a point along the wave: a Gaussian-windowed sine ring
    /// centred on the wavefront, the shape a water ring makes.
    static func displaced(_ point: CGPoint, origin: CGPoint, radius: CGFloat, energy: Double) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let d = max((dx * dx + dy * dy).squareRoot(), 1)
        let x = d - radius
        let width: CGFloat = 24
        let envelope = exp(-x * x / (2 * width * width))
        let offset = CGFloat(sin(x / width * 2.4)) * envelope * 18 * CGFloat(energy)
        return CGPoint(x: point.x + dx / d * offset, y: point.y + dy / d * offset)
    }

    /// GL-style smoothstep, for the same falloff shapes throughout.
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Per-panel wobble

/// Physically displaces a panel as a damped radial wave radiating from where
/// the file landed. `animatableData` is the animated phase: as it sweeps
/// 0→1, SwiftUI re-evaluates `effectValue` on every frame, producing the
/// wave. Falloff is measured from the panel's nearest edge to the drop
/// point, so the panel under the file jolts hardest and neighbours move as
/// the wave reaches them — objects floating on the water the shader ripples.
///
/// Presentation only: it never changes layout, so drop handling, hit testing
/// and VoiceOver geometry are untouched.
struct DropRippleEffect: GeometryEffect {
    /// Animated 0 → 1 by the host; back to 0 at rest (identity transform).
    var progress: CGFloat
    /// Drop point in this panel's own coordinate space.
    var origin: CGPoint
    /// Panel size, for the wave's centre and edge falloff.
    var bounds: CGSize
    var intensity: CGFloat = 1

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard progress > 0.0001, progress < 0.9999, intensity > 0,
              bounds.width > 1, bounds.height > 1
        else { return ProjectionTransform(.identity) }

        // Falloff: distance from the panel's nearest edge to the drop point,
        // so the panel the file actually lands in gets the full jolt no
        // matter where inside it the point sits.
        let nearestX = min(max(origin.x, 0), bounds.width)
        let nearestY = min(max(origin.y, 0), bounds.height)
        let edgeDistance = ((origin.x - nearestX) * (origin.x - nearestX)
            + (origin.y - nearestY) * (origin.y - nearestY)).squareRoot()
        let reach: CGFloat = 360
        let u = min(1, edgeDistance / reach)
        let falloff = (1 - u) * (1 - u)

        // The wave: three visible oscillations decaying to rest — glass
        // heaved by the impact and ringing down.
        let decay = pow(1 - progress, 1.3)
        let wave = sin(progress * .pi * 6) * decay
        let amplitude = 13.0 * intensity * falloff
        let squash = amplitude * wave * 0.016
        let push = amplitude * sin(progress * .pi) * 0.9

        // Push direction: from the panel's centre toward the drop point, so
        // panels lean toward the impact like surface tension pulling.
        let centreX = origin.x - bounds.width / 2
        let centreY = origin.y - bounds.height / 2
        let centreDistance = max((centreX * centreX + centreY * centreY).squareRoot(), 1)
        let dirX = centreDistance > 1 ? centreX / centreDistance : 0
        let dirY = centreDistance > 1 ? centreY / centreDistance : -1

        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: dirX * push, y: dirY * push)
        // Squash about the panel centre so the edges breathe in and out.
        transform = transform
            .translatedBy(x: bounds.width / 2, y: bounds.height / 2)
            .scaledBy(x: 1 + squash, y: 1 - squash)
            .translatedBy(x: -bounds.width / 2, y: -bounds.height / 2)
        return ProjectionTransform(transform)
    }
}

/// Applies the drop wobble to one view (a panel). The host exists from first
/// render — with a sentinel impact when none has happened yet — so the first
/// real drop is an `onChange` on an existing view and always fires. The
/// point arrives in `RippleSpace`; each host converts it into its own
/// coordinates, which is what lets every panel compute its own falloff from
/// the same event.
struct GlassRipple: ViewModifier {
    var impact: DropImpact?
    var intensity: CGFloat = 1

    func body(content: Content) -> some View {
        RippleHost(impact: impact, intensity: intensity, content: content)
    }
}

extension View {
    /// Jiggle this view as a damped radial wave from the drop point, whenever
    /// a new `DropImpact` arrives.
    func glassRipple(impact: DropImpact?, intensity: CGFloat = 1) -> some View {
        modifier(GlassRipple(impact: impact, intensity: intensity))
    }
}

private struct RippleHost<Content: View>: View {
    var impact: DropImpact?
    var intensity: CGFloat
    var content: Content

    /// Whole-number steps; the fractional part is the wave's progress.
    @State private var phase: CGFloat = 0
    /// This host's frame in the named ripple space, captured by a background
    /// reader — the content's layout is never touched by the measurement.
    @State private var frameInSpace: CGRect = .zero

    var body: some View {
        // The sentinel keeps the host (and its captured frame) alive from
        // first render, so the first drop is always a change on an existing
        // view — never a lost birth animation.
        let effective = impact ?? DropImpact(point: .zero, order: -1)
        content
            .modifier(DropRippleEffect(
                progress: phase - phase.rounded(.down),
                origin: CGPoint(
                    x: effective.point.x - frameInSpace.minX,
                    y: effective.point.y - frameInSpace.minY,
                ),
                bounds: frameInSpace.size,
                intensity: intensity,
            ))
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { frameInSpace = proxy.frame(in: .named(RippleSpace.name)) }
                        .onChange(of: proxy.frame(in: .named(RippleSpace.name))) { _, frame in
                            frameInSpace = frame
                        }
                }
            }
            .onAppear {
                // A view born *out of* a drop — a transfer card materialising
                // from it — settles at the landing point.
                if impact != nil { fire() }
            }
            .onChange(of: impact) { fire() }
    }

    private func fire() {
        withAnimation(.easeOut(duration: 1.0)) { phase += 1 }
    }
}

// MARK: - Glass toggle style

/// A Liquid Glass toggle: clear-glass track with a bright rim, a specular
/// glass knob that travels on an overshooting spring and — on every state
/// change — squishes along its travel and rings through a keyframed
/// aftershake, the way glass deforms and recovers. Replaces `.switch`,
/// which is stock AppKit chrome.
struct GlassToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: UI.Space.xs) {
            configuration.label
            Spacer(minLength: 0)
            GlassToggleTrack(isOn: configuration.isOn) {
                configuration.isOn.toggle()
            }
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}

extension ToggleStyle where Self == GlassToggleStyle {
    /// `.toggleStyle(.glass)`
    static var glass: GlassToggleStyle { .init() }
}

private struct GlassToggleTrack: View {
    let isOn: Bool
    let action: () -> Void

    @State private var pressCount = 0

    var body: some View {
        Button(action: action) {
            ZStack {
                track
                GlassToggleKnob(trigger: pressCount)
                    .frame(width: 20, height: 20)
                    .offset(x: isOn ? 10 : -10)
                    .animation(.spring(response: 0.34, dampingFraction: 0.6), value: isOn)
            }
            .frame(width: 44, height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // A real Button keeps Space/Return and VoiceOver activation working;
        // the glass is only the face of the control.
        .onChange(of: isOn) { pressCount += 1 }
    }

    private var track: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.35)) : AnyShapeStyle(Color.clear))
            .background {
                if #available(macOS 26.0, *) {
                    Capsule()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: Capsule())
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0.55 : 0.28), lineWidth: 1))
            .overlay {
                // On-state bloom behind the knob: light pooling in the glass.
                Capsule()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(isOn ? 0.5 : 0), .clear],
                            center: UnitPoint(x: isOn ? 0.82 : 0.18, y: 0.5),
                            startRadius: 1, endRadius: 26,
                        ),
                    )
                    .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isOn)
                    .allowsHitTesting(false)
            }
    }
}

/// The knob. `keyframeAnimator(trigger:)` runs a squash-and-settle timeline
/// on every state change: stretch along travel, squash into the landing rim,
/// then a damped aftershake — jelly, not a stock switch.
private struct GlassToggleKnob: View {
    let trigger: Int

    private struct Deform {
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: CGFloat = 0
    }

    var body: some View {
        face
            .keyframeAnimator(initialValue: Deform(), trigger: trigger) { content, deform in
                content
                    .scaleEffect(x: deform.scaleX, y: deform.scaleY)
                    .rotationEffect(.degrees(deform.rotation))
            } keyframes: { _ in
                KeyframeTrack(\.scaleX) {
                    SpringKeyframe(0.80, duration: 0.09)
                    SpringKeyframe(1.16, duration: 0.17)
                    SpringKeyframe(0.96, duration: 0.10)
                    SpringKeyframe(1.00, duration: 0.09)
                }
                KeyframeTrack(\.scaleY) {
                    SpringKeyframe(1.22, duration: 0.09)
                    SpringKeyframe(0.86, duration: 0.17)
                    SpringKeyframe(1.04, duration: 0.10)
                    SpringKeyframe(1.00, duration: 0.09)
                }
                KeyframeTrack(\.rotation) {
                    SpringKeyframe(-6, duration: 0.09)
                    SpringKeyframe(4, duration: 0.17)
                    SpringKeyframe(-2, duration: 0.10)
                    SpringKeyframe(0, duration: 0.09)
                }
            }
    }

    private var face: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(0.97), .white.opacity(0.60)],
                    startPoint: .top, endPoint: .bottom,
                ),
            )
            .overlay {
                // Specular dot — the bright point a light source makes on a
                // curved glass bead.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white, .white.opacity(0)],
                            center: UnitPoint(x: 0.35, y: 0.28),
                            startRadius: 0.5, endRadius: 7,
                        ),
                    )
                    .blendMode(.plusLighter)
            }
            .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)
    }
}

// MARK: - Press jiggle

private struct PressDeform {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var dip: CGFloat = 0
}

extension View {
    /// Keyframed squish-and-settle for a control that was just pressed:
    /// glass compresses down, springs past rest, and rings out.
    func pressJiggle(trigger: Int) -> some View {
        keyframeAnimator(initialValue: PressDeform(), trigger: trigger) { content, deform in
            content
                .scaleEffect(x: deform.scaleX, y: deform.scaleY)
                .offset(y: deform.dip)
        } keyframes: { _ in
            KeyframeTrack(\.scaleX) {
                SpringKeyframe(1.05, duration: 0.10)
                SpringKeyframe(0.99, duration: 0.16)
                SpringKeyframe(1.00, duration: 0.10)
            }
            KeyframeTrack(\.scaleY) {
                SpringKeyframe(0.95, duration: 0.10)
                SpringKeyframe(1.01, duration: 0.16)
                SpringKeyframe(1.00, duration: 0.10)
            }
            KeyframeTrack(\.dip) {
                SpringKeyframe(1.5, duration: 0.10)
                SpringKeyframe(-0.6, duration: 0.16)
                SpringKeyframe(0, duration: 0.10)
            }
        }
    }
}

// MARK: - Entrance

private struct Entrance {
    var opacity: Double = 0
    var rise: CGFloat = 12
    var scaleX: CGFloat = 0.96
    var scaleY: CGFloat = 0.94
}

/// One-shot entrance for anything that appears in a list: rise, unfade, and
/// a glass settling squish. Runs once per appearance — rows entering the
/// device list, cards when a transfer starts.
struct GlassEntrance: ViewModifier {
    var delay: Double = 0

    @State private var show = false

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: Entrance(), trigger: show) { view, value in
                view
                    .opacity(value.opacity)
                    .offset(y: value.rise)
                    .scaleEffect(x: value.scaleX, y: value.scaleY)
            } keyframes: { _ in
                // A hold of `delay` staggers rows; zero-duration keyframes are
                // degenerate, so the hold is clamped to a hair above zero.
                let hold = max(delay, 0.01)
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.0, duration: hold)
                    LinearKeyframe(1.0, duration: 0.26)
                }
                KeyframeTrack(\.rise) {
                    LinearKeyframe(12, duration: hold)
                    SpringKeyframe(0, duration: 0.40, spring: .bouncy)
                }
                KeyframeTrack(\.scaleX) {
                    LinearKeyframe(0.96, duration: hold)
                    SpringKeyframe(1.025, duration: 0.28, spring: .bouncy)
                    SpringKeyframe(1.00, duration: 0.16)
                }
                KeyframeTrack(\.scaleY) {
                    LinearKeyframe(0.94, duration: hold)
                    SpringKeyframe(0.99, duration: 0.28, spring: .bouncy)
                    SpringKeyframe(1.00, duration: 0.16)
                }
            }
            .onAppear { show = true }
    }
}

extension View {
    func glassEntrance(delay: Double = 0) -> some View {
        modifier(GlassEntrance(delay: delay))
    }
}

// MARK: - Selection pop

extension View {
    /// Small spring pop when a row becomes the selected lens.
    func selectionPop(trigger: Bool) -> some View {
        keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                SpringKeyframe(1.035, duration: 0.14)
                SpringKeyframe(0.995, duration: 0.12)
                SpringKeyframe(1.00, duration: 0.10)
            }
        }
    }
}

// MARK: - Status pulse

/// A text or glyph pulse when its status changes — the label answers the
/// state transition instead of silently swapping strings.
struct StatusPulse<Value: Equatable>: ViewModifier {
    var trigger: Value

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { content, scale in
                content
                    .scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack(\.self) {
                    SpringKeyframe(1.10, duration: 0.12)
                    SpringKeyframe(0.98, duration: 0.14)
                    SpringKeyframe(1.00, duration: 0.10)
                }
            }
    }
}

// MARK: - Sheen sweep

/// One sweep of light glancing across a glass surface, played when `trigger`
/// changes. The sheen is invisible at rest; the keyframes carry it from
/// off-left to off-right while fading in and out.
struct SheenSweep<Value: Equatable>: ViewModifier {
    var trigger: Value
    /// Corner radius to mask the sweep to; nil clips to bounds.
    var cornerRadius: CGFloat?

    private struct Sweep {
        var x: CGFloat = -0.4
        var opacity: Double = 0
    }

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                LinearGradient(
                    colors: [.clear, .white.opacity(0.6), .clear],
                    startPoint: .leading, endPoint: .trailing,
                )
                .frame(width: width * 0.38)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                .keyframeAnimator(initialValue: Sweep(), trigger: trigger) { sheen, value in
                    sheen
                        .offset(x: value.x * width)
                        .opacity(value.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.x) {
                        LinearKeyframe(-0.4, duration: 0.02)
                        LinearKeyframe(1.05, duration: 0.50)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0.0, duration: 0.02)
                        LinearKeyframe(0.9, duration: 0.16)
                        LinearKeyframe(0.9, duration: 0.20)
                        LinearKeyframe(0.0, duration: 0.14)
                    }
                }
            }
            .mask {
                if let cornerRadius {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                } else {
                    Rectangle()
                }
            }
        }
    }
}

// MARK: - Ambient motion

extension View {
    /// Slow glass breathing: the surface is never fully still, like real
    /// material under light. A repeating keyframe timeline drives a sine, so
    /// the loop point is invisible (both ends sit at phase 0).
    func ambientBreath(depth: CGFloat = 0.012) -> some View {
        keyframeAnimator(initialValue: CGFloat(0)) { content, phase in
            content.scaleEffect(1 + sin(phase) * depth)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                LinearKeyframe(0, duration: 1.4)
                LinearKeyframe(.pi, duration: 1.4)
            }
        }
    }

    /// A gentle bob on a different period than `ambientBreath`, so the two
    /// drift in and out of phase — weather, not machinery.
    func bob(amplitude: CGFloat = 3, period: Double = 1.1) -> some View {
        keyframeAnimator(initialValue: CGFloat(0)) { content, phase in
            content.offset(y: -sin(phase) * amplitude)
        } keyframes: { _ in
            KeyframeTrack(\.self) {
                LinearKeyframe(0, duration: period)
                LinearKeyframe(.pi, duration: period)
            }
        }
    }
}

// MARK: - Lane shimmer

/// A highlight riding the lane meter while bytes move — light travelling
/// along the glass tube. Lives only while a transfer runs, so it stops with
/// the meter.
struct LaneShimmer: View {
    @State private var running = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            LinearGradient(
                colors: [.clear, .white.opacity(0.5), .clear],
                startPoint: .leading, endPoint: .trailing,
            )
            .frame(width: width * 0.35)
            .offset(x: running ? width : -width * 0.35)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    running = true
                }
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}
