import SwiftUI

// Liquid Glass, done the way Apple asks for it.
//
// "Adopting Liquid Glass" says two things this file obeys: use the system
// components and let *them* supply the material (that is the chrome — see
// HyperSendView, which is a real NavigationSplitView and a real .sidebar List
// with no hand-painted background anywhere in it), and keep custom glass to the
// few controls that matter.
//
// The other half is this file. There are two ideas in it:
//
//   1. `GlassSurface` — the real `glassEffect`, availability-wrapped so macOS
//      14–25 gets a material from the same binary.
//   2. `DissolveHalo` — the part most apps get wrong. A glass panel has a hard
//      edge, so whatever is behind it stops dead at the rounded rectangle. Real
//      glass does not work like that; the surface *gives way* to it. The halo
//      is a feathered layer of blurred material bleeding past every edge, so the
//      texture underneath fades out over ~14 points instead of being cut off.

enum GlassIntensity: String, CaseIterable, Identifiable {
    case off, regular, maximum

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .regular: return "Regular"
        case .maximum: return "Max"
        }
    }

    /// 0…1, for every strength derived from the setting: glass, halo, grain.
    var strength: Double {
        switch self {
        case .off: return 0
        case .regular: return 0.55
        case .maximum: return 1
        }
    }
}

private struct GlassIntensityKey: EnvironmentKey {
    static let defaultValue = GlassIntensity.maximum
}

extension EnvironmentValues {
    var glassIntensity: GlassIntensity {
        get { self[GlassIntensityKey.self] }
        set { self[GlassIntensityKey.self] = newValue }
    }
}

// MARK: - The glass itself

struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.glassIntensity) private var intensity

    var shape: S
    var tint: Color?
    var interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), intensity != .off {
            content.glassEffect(effect, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1))
        }
    }

    /// At Max every surface is interactive — glass that answers the pointer is
    /// the difference between a material and a picture of a material.
    @available(macOS 26.0, *)
    private var effect: Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        } else if intensity == .maximum {
            glass = glass.tint(Color.accentColor.opacity(0.08))
        }
        if interactive || intensity == .maximum {
            glass = glass.interactive()
        }
        return glass
    }
}

// MARK: - Where the texture gives way

/// Feathers the edge of a glass panel.
///
/// Two blurred layers of material sit behind the panel and bleed past its
/// bounds: a wide, faint one and a tighter, denser one. Because they are real
/// materials they sample the window texture behind them, so what you see at the
/// rim is the texture itself, progressively blurred out — the grain does not
/// stop at the glass, it dissolves into it.
struct DissolveHalo<S: InsettableShape>: ViewModifier {
    @Environment(\.glassIntensity) private var intensity

    var shape: S
    var bleed: CGFloat

    func body(content: Content) -> some View {
        let strength = intensity.strength

        return content.background {
            if strength > 0 {
                ZStack {
                    // Wide falloff: the outer half of the fade.
                    shape
                        .fill(.ultraThinMaterial)
                        .padding(-bleed)
                        .blur(radius: bleed * 0.72)

                    // Tighter and denser: keeps the fade from reading as a
                    // smudge, and gives the rim a defined shoulder.
                    shape
                        .fill(.thinMaterial)
                        .padding(-bleed * 0.40)
                        .blur(radius: bleed * 0.26)
                }
                .opacity(strength)
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// A dissolving glass panel with rounded corners.
    func glassPanel(
        cornerRadius: CGFloat = 14,
        tint: Color? = nil,
        interactive: Bool = false,
        bleed: CGFloat = 15,
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .modifier(DissolveHalo(shape: shape, bleed: bleed))
            .modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    /// A dissolving glass capsule — chips, pills, small controls.
    func glassCapsule(tint: Color? = nil, interactive: Bool = false, bleed: CGFloat = 11) -> some View {
        let shape = Capsule()
        return self
            .modifier(DissolveHalo(shape: shape, bleed: bleed))
            .modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    /// A dissolving glass circle — icon buttons.
    func glassCircle(tint: Color? = nil, interactive: Bool = false, bleed: CGFloat = 9) -> some View {
        let shape = Circle()
        return self
            .modifier(DissolveHalo(shape: shape, bleed: bleed))
            .modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }

    /// Transient floating feedback, where glass is at its most appropriate.
    func floatingGlass() -> some View {
        glassCapsule(bleed: 18)
    }
}

#if DEBUG
#Preview("Glass — the dissolve, up close") {
    ZStack {
        WindowTexture()
        VStack(spacing: 26) {
            Text("Off")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassPanel(cornerRadius: 14)
                .environment(\.glassIntensity, .off)

            Text("Regular — the texture fades past the edge")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassPanel(cornerRadius: 14)
                .environment(\.glassIntensity, .regular)

            Text("Max — deeper, interactive")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassPanel(cornerRadius: 14)
                .environment(\.glassIntensity, .maximum)
        }
        .padding(40)
    }
    .frame(width: 620, height: 420)
}
#endif
