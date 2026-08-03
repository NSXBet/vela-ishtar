// Sources/VelaCore/BorderDash.swift
// Math for animating the pill's border as a dashed loop that fills in as
// budget is spent — perimeter of a rounded rect, and the on/off dash
// pattern for a given "fraction spent".
// Why: kept separate from any rendering code so it stays pure Foundation
// and unit-testable without AppKit/CoreGraphics.
// Convention: the border path starts at top-center and runs clockwise,
// so its dash phase is always 0 (no rotation offset needed).
// RELEVANT FILES: Tests/VelaCoreTests/BorderDashTests.swift, Sources/App (renderer)

import Foundation

public enum BorderDash {
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

    /// True once spend reaches or exceeds 100% of budget.
    public static func isFull(_ f: Double) -> Bool {
        f >= 1
    }

    /// Dash phase for the border path. Always 0 under the top-center,
    /// clockwise path convention documented above.
    public static func phase(perimeter p: Double) -> Double {
        0
    }
}
