// Tests/VelaCoreTests/BorderDashTests.swift
// Verifies BorderDash's perimeter math and its dash-pattern rules at the
// boundary fractions (0, mid, near-full, full).
// Why: the pill border animation is the app's signature visual; a wrong
// perimeter or off-by-one at f==1 would show a visible seam or gap.
// RELEVANT FILES: Sources/VelaCore/BorderDash.swift

import Testing
@testable import VelaCore

struct BorderDashTests {
    // Rounded rect: w=100, h=20, r=6.
    // Straight edges: 2*(100-12) + 2*(20-12) = 176 + 16 = 192.
    // Four corners = one full circle of radius r: 2*pi*6.
    static let w = 100.0, h = 20.0, r = 6.0
    static let expectedPerimeter = 2 * (w - 2 * r) + 2 * (h - 2 * r) + 2 * Double.pi * r

    @Test("perimeter matches straight edges plus corner circle")
    func perimeterMath() {
        let p = BorderDash.perimeter(width: Self.w, height: Self.h, cornerRadius: Self.r)
        #expect(abs(p - Self.expectedPerimeter) < 0.0001)
    }

    @Test("fraction 0 yields no pattern (nothing drawn)")
    func fractionZero() {
        #expect(BorderDash.pattern(forFraction: 0, perimeter: 100) == nil)
    }

    @Test("fraction 0.5 yields half-on half-off pattern")
    func fractionHalf() {
        let pattern = BorderDash.pattern(forFraction: 0.5, perimeter: 100)
        #expect(pattern != nil)
        #expect(pattern!.on == 50)
        #expect(pattern!.off == 100)
    }

    @Test("fraction 0.85 scales the on-length, off stays full perimeter")
    func fractionNearFull() {
        let pattern = BorderDash.pattern(forFraction: 0.85, perimeter: 100)
        #expect(pattern != nil)
        #expect(abs(pattern!.on - 85) < 0.0001)
        #expect(pattern!.off == 100)
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
