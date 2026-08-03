// Tests/VelaCoreTests/BorderDashTests.swift
// Verifies BorderDash's perimeter math and its dash-pattern rules at the
// boundary fractions (0, mid, near-full, full).
// Why: the pill border animation is the app's signature visual; a wrong
// perimeter or off-by-one at f==1 would show a visible seam or gap.
// RELEVANT FILES: Sources/VelaCore/BorderDash.swift

import Testing
@testable import VelaCore

struct BorderDashTests {
    // Rounded rect: w=100, h=20, r=6. Perimeter computed independently
    // (not by re-deriving the implementation's formula) so this test can't
    // just be checking the code against itself: 2*(100-12) + 2*(20-12) = 192
    // of straight edge, plus one full circle of radius 6 (2*pi*6) for the
    // four corners = 229.6991118430775.
    static let w = 100.0, h = 20.0, r = 6.0
    static let expectedPerimeter = 229.6991118430775

    @Test("perimeter matches straight edges plus corner circle")
    func perimeterMath() {
        let p = BorderDash.perimeter(width: Self.w, height: Self.h, cornerRadius: Self.r)
        #expect(abs(p - Self.expectedPerimeter) < 1e-9)
    }

    @Test("fraction 0 yields no pattern (nothing drawn)")
    func fractionZero() {
        #expect(BorderDash.pattern(forFraction: 0, perimeter: Self.expectedPerimeter) == nil)
    }

    @Test("fraction 0.5 yields half-on half-off pattern")
    func fractionHalf() {
        let pattern = BorderDash.pattern(forFraction: 0.5, perimeter: Self.expectedPerimeter)
        #expect(pattern != nil)
        #expect(abs(pattern!.on - Self.expectedPerimeter / 2) < 1e-9)
        #expect(pattern!.off == Self.expectedPerimeter)
    }

    @Test("fraction 0.85 scales the on-length, off stays full perimeter")
    func fractionNearFull() {
        let pattern = BorderDash.pattern(forFraction: 0.85, perimeter: Self.expectedPerimeter)
        #expect(pattern != nil)
        #expect(abs(pattern!.on - 0.85 * Self.expectedPerimeter) < 1e-9)
        #expect(pattern!.off == Self.expectedPerimeter)
    }

    @Test("zero-size rect has zero perimeter")
    func perimeterZeroSizeRect() {
        let p = BorderDash.perimeter(width: 0, height: 0, cornerRadius: 0)
        #expect(p == 0)
    }

    @Test("corner radius larger than half the shortest side is clamped to half the shortest side")
    func perimeterClampsOversizedCornerRadius() {
        // h=20, so half the shortest side is 10; r=15 must behave as r=10.
        let p = BorderDash.perimeter(width: 100, height: 20, cornerRadius: 15)
        let expected = 2 * (100.0 - 20.0) + 0 + 2 * Double.pi * 10
        #expect(abs(p - expected) < 1e-9)
    }

    @Test("fraction 1.0 yields nil (renderer draws a solid loop instead)")
    func fractionFull() {
        #expect(BorderDash.pattern(forFraction: 1.0, perimeter: 100) == nil)
    }

    @Test("isFull reports true only at or above 1.0")
    func isFullBoundary() {
        #expect(BorderDash.isFull(1.0) == true)
        #expect(BorderDash.isFull(1.0001) == true)
        #expect(BorderDash.isFull(0.9999) == false)
    }

    @Test("phase is zero regardless of perimeter, per the top-center clockwise convention")
    func phaseIsZero() {
        #expect(BorderDash.phase(perimeter: 192) == 0)
        #expect(BorderDash.phase(perimeter: 1) == 0)
    }
}
