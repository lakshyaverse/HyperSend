import SwiftUI

// The window's design system.
//
// Three rules this file exists to enforce:
//
//   1. Colour is scarce. The accent marks the one thing that is live or
//      actionable and is otherwise absent from the chrome. The lane tints are
//      the single deliberate exception, and they live in `Lane` so that colour
//      belongs to the data rather than to the interface.
//   2. Structure comes from hairlines and space, never from boxes. Nothing in
//      this file provides a drop shadow, a gradient or a second material.
//   3. A token names a role, never a size. Retuning the window means editing
//      this file, not hunting literals through six views.

enum UI {

    // MARK: - Type
    //
    // The system face, because on macOS SF *is* the correct answer: it tracks
    // Dynamic Type, respects the user's size setting, and sits correctly beside
    // every other window. Hierarchy comes from size and weight, not colour.

    enum Text {
        /// The empty state's one line of headline.
        static let hero = Font.system(size: 17, weight: .semibold)
        /// A transfer row's file name.
        static let row = Font.system(size: 13, weight: .medium)
        /// Supporting prose.
        static let body = Font.system(size: 12)
        /// Metadata, addresses, byte counts.
        static let caption = Font.system(size: 11)
        /// State words: Verified, Transferring, 2 queued.
        static let tag = Font.system(size: 11, weight: .medium)
    }

    enum Icon {
        /// The empty state's glyph.
        static let hero: CGFloat = 22
        /// A row's direction arrow.
        static let row: CGFloat = 11
        /// Icons sitting inline with text.
        static let inline: CGFloat = 12
    }

    // MARK: - Shape
    //
    // Crisp, not pill-shaped. Large radii read as decoration; these are kept
    // small enough to look structural.

    enum Radius {
        /// The drop target.
        static let well: CGFloat = 12
        /// The lane meter.
        static let bar: CGFloat = 3
    }

    // MARK: - Rhythm

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let xl: CGFloat = 40
    }

    // MARK: - Lanes
    //
    // The only colour in the window besides the accent, and it is only ever
    // drawn inside the lane meter. Two lanes, two tints, no third hue.

    enum Lane {
        /// Draw order: Wi-Fi is the lane that is always there, so it leads.
        static let order = ["wifi", "usb"]

        static func tint(_ label: String) -> Color {
            switch label {
            case "usb": return Color(nsColor: .systemGreen)
            default: return Color.accentColor
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

    // MARK: - Measure

    /// Longest a line of prose is allowed to run before the eye loses it.
    static let measure: CGFloat = 420
}
