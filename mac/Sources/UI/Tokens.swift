import SwiftUI
import QuartzCore

// The window's design system, rebuilt around Apple's Liquid Glass.
//
// The reference is the macOS 26 "Icon Composer" window: a pastel scene behind
// the whole window, and every panel — sidebar, inspector, toolbar chips —
// floating on it as frosted glass with a bright specular edge. This file owns
// three things:
//
//   1. The scene palette. A soft sky that the glass refracts; without it the
//      glass reads as grey blur, not as glass.
//   2. Radius + spacing tokens. One radius system, applied everywhere.
//   3. The glass helpers. On macOS 26+ they apply the system's *real* Liquid
//      Glass material (`glassEffect`, `Glass.regular/.clear`, NSGlassEffectView
//      — not a CSS-style fake). Below 26 they fall back to HUD materials, so
//      the app still runs on macOS 14/15 with slightly less shimmer.

// MARK: - Scene palette

enum Scene {
    /// Stops of the pastel sky behind the glass, top to bottom.
    static let skyStops: [(Color, CGFloat)] = [
        (Color(red: 0.62, green: 0.83, blue: 0.99), 0.00),
        (Color(red: 0.58, green: 0.78, blue: 0.99), 0.32),
        (Color(red: 0.47, green: 0.71, blue: 0.99), 0.62),
        (Color(red: 0.42, green: 0.62, blue: 0.98), 0.85),
        (Color(red: 0.39, green: 0.58, blue: 0.98), 1.00),
    ]

    /// Warm accents that break the blue so the scene reads as weather, not wallpaper.
    static let warmStops: [(Color, CGFloat, CGRect)] = [
        (Color(red: 1.00, green: 0.88, blue: 0.60), 0.55, CGRect(x: 0.05, y: 0.02, width: 0.55, height: 0.42)),
        (Color(red: 0.98, green: 0.72, blue: 0.66), 0.45, CGRect(x: 0.55, y: 0.30, width: 0.45, height: 0.50)),
        (Color(red: 0.86, green: 0.85, blue: 1.00), 0.45, CGRect(x: -0.10, y: 0.45, width: 0.50, height: 0.55)),
    ]

    /// Dark-mode sky: same composition, night shift.
    static let skyStopsDark: [(Color, CGFloat)] = [
        (Color(red: 0.10, green: 0.14, blue: 0.26), 0.00),
        (Color(red: 0.09, green: 0.12, blue: 0.24), 0.40),
        (Color(red: 0.07, green: 0.10, blue: 0.21), 0.75),
        (Color(red: 0.06, green: 0.08, blue: 0.18), 1.00),
    ]

    static let warmStopsDark: [(Color, CGFloat, CGRect)] = [
        (Color(red: 0.16, green: 0.22, blue: 0.42), 0.35, CGRect(x: 0.05, y: 0.02, width: 0.55, height: 0.42)),
        (Color(red: 0.22, green: 0.16, blue: 0.34), 0.30, CGRect(x: 0.55, y: 0.30, width: 0.45, height: 0.50)),
        (Color(red: 0.13, green: 0.17, blue: 0.35), 0.30, CGRect(x: -0.10, y: 0.45, width: 0.50, height: 0.55)),
    ]
}

// MARK: - Tokens

enum UI {

    enum Text {
        /// The hero headline over the drop well.
        static let hero = Font.system(size: 17, weight: .semibold)
        /// A transfer row's file name.
        static let row = Font.system(size: 13, weight: .medium)
        /// Section labels in the inspector ("Color", "Liquid Glass").
        static let section = Font.system(size: 12, weight: .semibold)
        /// Supporting prose.
        static let body = Font.system(size: 12)
        /// Metadata, addresses, byte counts.
        static let caption = Font.system(size: 11)
        /// State words: Verified, Transferring.
        static let tag = Font.system(size: 11, weight: .medium)
    }

    enum Icon {
        static let hero: CGFloat = 24
        static let row: CGFloat = 12
        static let inline: CGFloat = 12
    }

    /// One radius system for everything, echoing the reference window's
    /// continuous rounded glass.
    enum Radius {
        /// Big glass panels: sidebar, inspector, drop well.
        static let panel: CGFloat = 22
        /// Rows and cards inside a panel.
        static let card: CGFloat = 14
        /// Buttons, chips, the lane meter.
        static let control: CGFloat = 9
        /// The lane meter itself, a thin strip.
        static let bar: CGFloat = 3
        /// Pills (toolbar capsule, status capsule).
        static let pill: CGFloat = 16
    }

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 22
        static let xl: CGFloat = 40
    }

    // MARK: Lanes

    /// The only saturated colour in the chrome, and it belongs to the data.
    enum Lane {
        static let order = ["wifi", "usb"]

        static func tint(_ label: String) -> Color {
            switch label {
            case "usb": return Color(red: 0.20, green: 0.78, blue: 0.55)
            default: return Color(red: 0.36, green: 0.52, blue: 0.98)
            }
        }

        static func name(_ label: String) -> String {
            switch label {
            case "wifi": return "Wi-Fi"
            case "usb": return "USB cable"
            default: return label.capitalized
            }
        }
    }

    /// Longest a line of prose runs before the eye loses it.
    static let measure: CGFloat = 420
}

// MARK: - Glass helpers
//
// Each helper compiles to two bodies: the macOS 26+ body applies the real
// system Liquid Glass; the earlier body layers HUD materials. Callers never
// branch on availability themselves.

extension View {

    /// A floating glass panel (sidebar, inspector, drop well).
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = UI.Radius.panel) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.regularMaterial, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
    }

    /// A smaller glass card inside a panel (settings row cluster, transfer card).
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = UI.Radius.card) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.thinMaterial, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                }
        }
    }

    /// Toolbar chips and buttons.
    @ViewBuilder
    func glassChip(cornerRadius: CGFloat = UI.Radius.control) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.30), lineWidth: 1)
                }
        }
    }

    /// The hero element: clear glass so the scene keeps moving behind it.
    @ViewBuilder
    func glassHero(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.clear, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                }
        }
    }
}
