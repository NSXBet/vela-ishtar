// Sources/VelaCore/ModelShare.swift
// The per-model share of spend shown inline on each model row as `name · 62%`
// (v0.5.0). Why this exists: the row used to carry a 2pt bar whose width was
// proportional to cost — decoration that restated what the cost column already
// says, and its variable right edge was half of the column-raggedness problem.
// Replacing it with a number keeps the "which model dominates" answer but as
// information, not ornament. The rounding rules below are specified, not
// guessed: a nonzero cost must always show at least 1% (presence is visible),
// and a zero/negative total must never divide by zero.
// RELEVANT FILES: Tests/VelaCoreTests/ModelShareTests.swift, Sources/App/PopoverView.swift

import Foundation

public enum ModelShare {
    /// `cost` as a whole-number percentage of `total`, rounded to nearest.
    /// A nonzero cost floors at 1 so a small-but-real share doesn't vanish;
    /// a zero cost is exactly 0; a zero or negative total (degenerate input)
    /// yields 0 rather than a divide-by-zero or a meaningless huge number.
    public static func percent(cost: Double, total: Double) -> Int {
        guard total > 0 else { return 0 }
        guard cost > 0 else { return 0 }
        let raw = (cost / total) * 100
        let rounded = Int(raw.rounded())
        return max(1, min(100, rounded))
    }
}
