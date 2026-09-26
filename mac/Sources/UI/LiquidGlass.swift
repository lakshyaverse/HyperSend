import AppKit
import SwiftUI

// Custom Liquid Glass, using Apple's sample code parameters EXACTLY.
//
// From "Applying Liquid Glass to custom views"
// (developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
//
//   Text("Hello, World!")
//       .font(.title)
//       .padding()
//       .glassEffect()
//
//   Text("Hello, World!")
//       .font(.title)
//       .padding()
//       .glassEffect(in: .rect(cornerRadius: 16.0))
//
//   Text("Hello, World!")
//       .font(.title)
//       .padding()
//       .glassEffect(.regular.tint(.orange).interactive())
//
//   @State private var isExpanded: Bool = false
//   @Namespace private var namespace
//
//   var body: some View {
//       GlassEffectContainer(spacing: 40.0) {
//           HStack(spacing: 40.0) {
//               Image(systemName: "scribble.variable")
//                   .frame(width: 80.0, height: 80.0)
//                   .font(.system(size: 36))
//                   .glassEffect()
//                   .glassEffectID("pencil", in: namespace)
//
//               if isExpanded {
//                   Image(systemName: "eraser.fill")
//                       .frame(width: 80.0, height: 80.0)
//                       .font(.system(size: 36))
//                       .glassEffect()
//                       .glassEffectID("eraser", in: namespace)
//               }
//           }
//       }
//
//       Button("Toggle") {
//           withAnimation { isExpanded.toggle() }
//       }
//       .buttonStyle(.glass)
//   }
//
// Three details matter and all three were wrong before:
//   1. `glassEffect()` with no shape is a CAPSULE (DefaultGlassEffectShape).
//   2. `GlassEffectContainer(spacing:)` must match the inner stack's spacing —
//      that is what makes neighbouring shapes blend and morph into each other.
//   3. `glassEffectID(_:in:)` inside a `@Namespace`, driven by `withAnimation`,
//      is what makes them move.

// MARK: - Floating, morphing action cluster

// MARK: - Jiggle

/// Spring physics, not a crossfade.
///
/// A `keyframeAnimator` with `bouncy` springs on two tracks at once — scale and
/// rotation — each overshooting and settling at a different rate. Driving both
/// from one trigger is what makes it read as weight: the shape squashes, rocks
/// past its resting angle, then rocks back smaller each time. Bump `trigger` and
/// it plays; it is stateless, so nothing has to be reset afterwards.
struct Jiggle: ViewModifier {
    var trigger: Int
    var amount: Double = 0.09

    struct Wobble {
        var scale: Double = 1
        var angle: Double = 0
    }

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: Wobble(), trigger: trigger) { view, wobble in
            view
                .scaleEffect(wobble.scale, anchor: .bottomTrailing)
                .rotationEffect(.degrees(wobble.angle), anchor: .bottomTrailing)
        } keyframes: { _ in
            KeyframeTrack(\.scale) {
                SpringKeyframe(1 + amount, duration: 0.13, spring: .bouncy)
                SpringKeyframe(1 - amount * 0.45, duration: 0.15, spring: .bouncy)
                SpringKeyframe(1, duration: 0.24, spring: .bouncy)
            }
            KeyframeTrack(\.angle) {
                SpringKeyframe(amount * 52, duration: 0.12, spring: .bouncy)
                SpringKeyframe(-amount * 38, duration: 0.14, spring: .bouncy)
                SpringKeyframe(amount * 16, duration: 0.15, spring: .bouncy)
                SpringKeyframe(0, duration: 0.22, spring: .bouncy)
            }
        }
    }
}

extension View {
    /// Knocks a view like a physical object whenever `trigger` changes.
    func jiggle(on trigger: Int, amount: Double = 0.09) -> some View {
        modifier(Jiggle(trigger: trigger, amount: amount))
    }
}

/// The primary actions as one piece of glass that opens up and morphs.
/// Apple's example, verbatim parameters, applied to a real feature.
struct GlassActions: View {
    var model: AppModel

    var body: some View {
        if #available(macOS 26.0, *) {
            cluster
        }
    }

    @available(macOS 26.0, *)
    private var cluster: some View {
        GlassActionsCluster(model: model)
    }
}

@available(macOS 26.0, *)
private struct GlassActionsCluster: View {
    var model: AppModel
    @State private var expanded = false
    @State private var bounces = 0
    @Namespace private var namespace

    /// Matches the inner HStack, exactly as the sample does, so the shapes
    /// blend together instead of sitting as separate chips.
    private let spacing: CGFloat = 18.0
    private let size: CGFloat = 52.0

    /// The spring the shapes travel on. Low damping, so they arrive with a
    /// little too much enthusiasm and settle back.
    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.58)

    /// These are the *secondary* actions. Send deliberately lives in the
    /// toolbar — it is the primary action, and duplicating one control in two
    /// places is the kind of thing that makes a window feel unfinished.
    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                Button {
                    bounces += 1
                    withAnimation(spring) {
                        expanded.toggle()
                    }
                } label: {
                    Image(systemName: expanded ? "xmark" : "ellipsis")
                        .frame(width: size, height: size)
                        .font(.system(size: UI.Icon.control, weight: .semibold))
                }
                .buttonStyle(.glass)
                .glassEffectID("toggle", in: namespace)
                .help(expanded ? "Hide extra actions" : "More actions")

                if expanded {
                    CircleButton(symbol: "plus", size: size) {
                        MenuActions.shared.addDevice(nil)
                    }
                    .glassEffectID("add", in: namespace)
                    .ordered(0, spring: spring, active: expanded)
                    .help("Add a device by IP address")

                    CircleButton(symbol: "folder", size: size) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.receiveDirectory])
                    }
                    .glassEffectID("folder", in: namespace)
                    .ordered(1, spring: spring, active: expanded)
                    .help("Show the receive folder")

                    CircleButton(symbol: "gearshape", size: size) {
                        MenuActions.shared.openSettings(nil)
                    }
                    .glassEffectID("settings", in: namespace)
                    .ordered(2, spring: spring, active: expanded)
                    .help("Settings")
                }
            }
        }
        // The whole cluster takes the hit, so the wobble is the container's and
        // not three independent buttons bouncing out of sync.
        .jiggle(on: bounces)
    }
}

private extension View {
    /// In on a spring, from slightly small and nearly transparent, each button
    /// a beat behind the one before it so they land as a sequence.
    func ordered(_ index: Int, spring: Animation, active: Bool) -> some View {
        transition(.scale(scale: 0.55, anchor: .trailing).combined(with: .opacity))
            .animation(spring.delay(Double(index) * 0.045), value: active)
    }
}

@available(macOS 26.0, *)
private struct CircleButton: View {
    var symbol: String
    var size: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: size, height: size)
                .font(.system(size: UI.Icon.control))
        }
        .buttonStyle(.glass)
    }
}

/// macOS 14–25 fallback for the bonded pill: a plain material, same layout.
private struct PlainLaneChip: View {
    let symbol: String
    let tint: Color
    let rate: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: UI.Icon.lane))
                .foregroundStyle(tint)
            Text(formattedRate(rate))
                .font(UI.TypeScale.laneChip.monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Two lanes, one bonded path

/// Wi-Fi and the USB cable as a single fused capsule: `glassEffectUnion` merges
/// every effect that shares an id into one shape, which is exactly what bonding
/// two lanes does to the transfer.
struct BondedLaneIndicator: View {
    var wifiRate: Double
    var usbRate: Double
    var usbReady: Bool

    /// A lane joining or dropping out is a real event, so it lands as one: the
    /// capsule takes a hit each time the cable lane changes state.
    @State private var laneChanges = 0

    var body: some View {
        group
            .onChange(of: usbReady) { _, _ in laneChanges += 1 }
            .jiggle(on: laneChanges, amount: 0.06)
    }

    @ViewBuilder
    private var group: some View {
        if #available(macOS 26.0, *) {
            union
        } else {
            HStack(spacing: 10) {
                PlainLaneChip(symbol: "wifi", tint: .blue, rate: wifiRate)
                if usbReady {
                    PlainLaneChip(symbol: "cable.connector", tint: .green, rate: usbRate)
                }
            }
        }
    }

    @available(macOS 26.0, *)
    private var union: some View {
        BondedUnion(wifiRate: wifiRate, usbRate: usbRate, usbReady: usbReady)
    }
}

@available(macOS 26.0, *)
private struct BondedUnion: View {
    var wifiRate: Double
    var usbRate: Double
    var usbReady: Bool
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 20.0) {
            HStack(spacing: 20.0) {
                chip(symbol: "wifi", tint: .blue, rate: wifiRate, id: "wifi")
                if usbReady {
                    chip(symbol: "cable.connector", tint: .green, rate: usbRate, id: "wifi")
                }
            }
            .padding(6)
        }
    }

    private func chip(symbol: String, tint: Color, rate: Double, id: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: UI.Icon.lane))
                .foregroundStyle(tint)
            Text(formattedRate(rate))
                .font(UI.TypeScale.laneChip.monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular.interactive())
        .glassEffectUnion(id: id, namespace: namespace)
    }
}

// MARK: - Previews

// These are the "hit Resume in the canvas" surfaces: the morphing cluster and
// the bonded union, in isolation, so the motion is easy to watch.
#if DEBUG
#Preview("Liquid Glass — morphing actions + jiggle") {
    ZStack {
        WindowTexture()
        VStack(spacing: 40) {
            Text("Tap the ellipsis: it wobbles and the buttons spring in")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            GlassActions(model: .previewSeeded())
        }
        .padding(40)
    }
    .frame(width: 520, height: 380)
}

#Preview("Liquid Glass — bonded lanes") {
    ZStack {
        WindowTexture()
        BondedLaneIndicator(wifiRate: 36_200_000, usbRate: 32_600_000, usbReady: true)
    }
    .frame(width: 520, height: 220)
}
#endif
