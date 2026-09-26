import SwiftUI

// The design tokens.
//
// Before this file every view picked its own sizes: fonts at 10, 11, 12, 13, 17
// and 30 points, radii at 14 and 18, icons at 13/15/17/19/24 in four different
// weights. Nothing was *wrong*, but nothing rhymed either — a lane title and a
// lane rate were the same size by coincidence, and changing one row's density
// meant hunting literals across six files.
//
// Two rules keep this honest:
//
//   1. Only *numeric* fonts live here. `.headline`, `.caption`, `.callout` and
//      friends are already tokens — the system's — and they track Dynamic Type
//      and accessibility sizes for free. Rewriting those as fixed point sizes
//      would be a regression, not a tidy-up.
//   2. A token names what a thing *is* (a row title, a counter), never how big
//      it is. `UI.Type.rate` can be resized once and every rate follows.

enum UI {

    // MARK: - Type

    /// 30 pt semibold — the combined-throughput figure. The only display type
    /// in the app, so it is allowed to be the loudest thing on screen.
    enum TypeScale {
        static let display = Font.system(size: 30, weight: .semibold)
        /// 13 pt semibold — transient emphasis: the drop target, alerts.
        static let emphasis = Font.system(size: 13, weight: .semibold)
        /// 12 pt semibold — the name of a lane.
        static let laneTitle = Font.system(size: 12, weight: .semibold)
        /// 12 pt — a lane's throughput.
        static let laneRate = Font.system(size: 12)
        /// 12 pt medium — the fused lane chip's throughput, a touch heavier
        /// than `laneRate` so it holds up against the chip's material.
        static let laneChip = Font.system(size: 12, weight: .medium)
        /// 12 pt medium — a transfer row's file name.
        static let rowTitle = Font.system(size: 12, weight: .medium)
        /// 11 pt — the status bar, and a row's throughput.
        static let rate = Font.system(size: 11)
        /// 10 pt medium — small state labels: "active", "verified", "2 queued".
        static let chip = Font.system(size: 10, weight: .medium)
        /// 10 pt — byte counters sitting next to a chip.
        static let counter = Font.system(size: 10)
    }

    // MARK: - Icons

    /// SF Symbols point sizes. Kept to four steps so stroke weight stays
    /// consistent — a 19 pt icon at `.semibold` next to a 15 pt icon at
    /// default weight reads as two different icon sets.
    enum Icon {
        static let row: CGFloat = 17
        static let lane: CGFloat = 15
        static let control: CGFloat = 19
        static let dock: CGFloat = 24
    }

    // MARK: - Shape

    enum Radius {
        /// Panels and cards.
        static let panel: CGFloat = 18
        /// List rows and sidebar cards.
        static let row: CGFloat = 14
    }

    // MARK: - Rhythm

    /// The spacing steps actually used more than once. Anything narrower than
    /// 4 pt is optical nudging and stays inline where it happens.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 14
        static let l: CGFloat = 20
    }

    // MARK: - Measure

    /// How wide a column of prose may run before the eye loses the line. Only
    /// applies to the detail column: the sidebar and list are already bounded
    /// by their own widths.
    static let readableWidth: CGFloat = 720
}
