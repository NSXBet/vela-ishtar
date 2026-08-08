// Sources/VelaCore/BorderDash.swift
// Math for animating the pill's border as a dashed loop that fills in as
// budget is spent — perimeter of a rounded rect, the on/off dash pattern for a
// given "fraction spent", and which alarm LEVEL that fraction has reached
// (ink → yellow at 50% → amber at 75% → red loop at 90%).
// Why: kept separate from any rendering code so it stays pure Foundation
// and unit-testable without AppKit/CoreGraphics.
// Convention: the border path starts at top-center and runs clockwise,
// so its dash phase is always 0 (no rotation offset needed).
// RELEVANT FILES: Tests/VelaCoreTests/BorderDashTests.swift, Sources/App (renderer)

import Foundation

public enum BorderDash {

    /// How loud the border should be at a given fraction spent. The renderer
    /// switches on this instead of comparing magic numbers inline, so the
    /// thresholds live in exactly one place and are pinned by tests.
    ///
    /// The ramp is deliberately monotonic in loudness — ink → yellow → amber →
    /// red — so the border reads as one escalating signal rather than four
    /// unrelated states.
    public enum Level: Equatable, Sendable {
        /// Nothing spent yet (or no limit): the faint empty-gauge outline only.
        case empty
        /// Spending, still comfortable: an ink trace over the faint outline.
        case trace
        /// Past `noticeThreshold`: the trace turns yellow — "half your day is
        /// gone", a heads-up, not a warning.
        case notice
        /// Past `amberThreshold`: the trace turns amber.
        case amber
        /// Past `alarmThreshold`: a solid closed red loop, no dash.
        case alarm
    }

    /// Where the trace turns yellow. v1.0.0: the first waypoint on the ramp —
    /// past half your daily budget you should know it, but there is nothing to
    /// act on yet, so this is the quietest possible colour change rather than a
    /// warning.
    public static let noticeThreshold = 0.50

    /// Where the trace turns amber. v1.0.0 moved this 0.85 → 0.75: at 85% of a
    /// daily budget there is often less than an hour of normal burn left, which
    /// is too late for the warning to change what you do. 75% still leaves room
    /// to act.
    public static let amberThreshold = 0.75

    /// Where the border becomes a closed red loop. v1.0.0 moved this 1.00 →
    /// 0.90, so the alarm fires while there is still budget to protect rather
    /// than only once it's gone.
    ///
    /// Deliberately NOT the same question as `isFull`: this is the VISUAL alarm,
    /// while `isFull` is the FACTUAL "budget is spent". Keeping them separate is
    /// what lets the border shout at 90% without the app claiming your budget is
    /// exhausted when a tenth of it remains.
    public static let alarmThreshold = 0.90

    /// The alarm level for a fraction spent. `limitEnabled: false` is always
    /// `.empty` — with no budget there is nothing to trace against.
    /// Ordered high-to-low so each band's upper edge belongs to the louder
    /// level, making every threshold inclusive.
    public static func level(forFraction f: Double, limitEnabled: Bool = true) -> Level {
        guard limitEnabled, f > 0 else { return .empty }
        if f >= alarmThreshold { return .alarm }
        if f >= amberThreshold { return .amber }
        if f >= noticeThreshold { return .notice }
        return .trace
    }

    /// Perimeter of a rounded rectangle: two straight edges of each side
    /// (shortened by the corner radius on both ends) plus the four corners,
    /// which together sweep one full circle of radius `cornerRadius`.
    public static func perimeter(width w: Double, height h: Double, cornerRadius r: Double) -> Double {
        // A corner radius bigger than half the shortest side is geometrically
        // impossible (the two corners on that side would overlap), so clamp
        // it down rather than let the straight-edge term go negative.
        let r = min(r, min(w, h) / 2)
        let straightEdges = 2 * (w - 2 * r) + 2 * (h - 2 * r)
        let corners = 2 * Double.pi * r
        return straightEdges + corners
    }

    /// Dash pattern for drawing `fraction` of the perimeter as "on" (spent)
    /// and the rest as gap. `off` is always the full perimeter so the gap
    /// segment never wraps back around and overlaps the on segment.
    /// - f <= 0: nothing to draw yet -> nil.
    /// - f >= 1: budget fully spent -> nil (caller should draw a solid loop instead).
    public static func pattern(forFraction f: Double, perimeter p: Double) -> (on: Double, off: Double)? {
        guard f > 0, f < 1 else { return nil }
        return (on: f * p, off: p)
    }

    /// True once spend reaches or exceeds 100% of budget — the FACTUAL
    /// "budget is spent", used for content dimming and the exhausted verdict.
    /// The border's red loop fires earlier, at `alarmThreshold`; see `level`.
    public static func isFull(_ f: Double) -> Bool {
        f >= 1
    }

    /// Dash phase for the border path. Always 0 under the top-center,
    /// clockwise path convention documented above.
    public static func phase(perimeter p: Double) -> Double {
        0
    }
}
