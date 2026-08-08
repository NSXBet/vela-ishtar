// Tests/VelaCoreTests/BorderDashTests.swift
// Verifies BorderDash's perimeter math, its dash-pattern rules at the
// boundary fractions (0, mid, near-full, full), and the amber/alarm levels.
// Why: the pill border animation is the app's signature visual; a wrong
// perimeter or off-by-one at f==1 would show a visible seam or gap, and a
// drifted threshold would warn too late to be useful.
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

    @Test("a high fraction scales the on-length, off stays full perimeter")
    func fractionNearFull() {
        // 0.85 is arbitrary here — the point is that `pattern` is pure
        // proportional math and knows nothing about the amber/alarm levels.
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

    // MARK: - alarm levels (v1.0.0: yellow past 50%, amber past 75%, red loop past 90%)

    @Test("the thresholds are 50% notice, 75% amber, 90% alarm")
    func thresholdValues() {
        // Pinned as VALUES, not just behaviour: these three numbers are a
        // product decision (warn early enough to act on), and a silent drift
        // back toward 85/100 would quietly un-fix the thing we changed.
        #expect(BorderDash.noticeThreshold == 0.50)
        #expect(BorderDash.amberThreshold == 0.75)
        #expect(BorderDash.alarmThreshold == 0.90)
    }

    @Test("the thresholds ascend, so every band is reachable")
    func thresholdsAscend() {
        // If these ever cross, a whole colour band becomes dead code and the
        // ramp silently loses a step — cheaper to assert than to notice.
        #expect(BorderDash.noticeThreshold < BorderDash.amberThreshold)
        #expect(BorderDash.amberThreshold < BorderDash.alarmThreshold)
        #expect(BorderDash.alarmThreshold <= 1.0)
    }

    @Test("no spend, or no budget, is the empty gauge")
    func levelEmpty() {
        #expect(BorderDash.level(forFraction: 0) == .empty)
        #expect(BorderDash.level(forFraction: -0.1) == .empty)
        // A disabled limit has nothing to trace against, at any fraction.
        #expect(BorderDash.level(forFraction: 0.5, limitEnabled: false) == .empty)
        #expect(BorderDash.level(forFraction: 0.95, limitEnabled: false) == .empty)
    }

    @Test("the first half of the budget traces in quiet ink")
    func levelTrace() {
        #expect(BorderDash.level(forFraction: 0.01) == .trace)
        #expect(BorderDash.level(forFraction: 0.25) == .trace)
        // Just under the halfway mark is still quiet.
        #expect(BorderDash.level(forFraction: 0.4999) == .trace)
    }

    @Test("yellow starts AT 50% and holds until amber")
    func levelNotice() {
        #expect(BorderDash.level(forFraction: 0.50) == .notice)   // inclusive
        #expect(BorderDash.level(forFraction: 0.60) == .notice)
        #expect(BorderDash.level(forFraction: 0.7499) == .notice)
    }

    @Test("amber starts AT 75% and holds until the alarm")
    func levelAmber() {
        #expect(BorderDash.level(forFraction: 0.75) == .amber)   // inclusive
        #expect(BorderDash.level(forFraction: 0.85) == .amber)   // the old amber line
        #expect(BorderDash.level(forFraction: 0.8999) == .amber)
    }

    @Test("the red loop starts AT 90%, not at 100%")
    func levelAlarm() {
        #expect(BorderDash.level(forFraction: 0.90) == .alarm)   // inclusive
        #expect(BorderDash.level(forFraction: 0.95) == .alarm)
        #expect(BorderDash.level(forFraction: 1.0) == .alarm)
        #expect(BorderDash.level(forFraction: 1.5) == .alarm)    // over budget stays alarm
    }

    @Test("the ramp escalates monotonically across the whole range")
    func rampIsMonotonic() {
        // Walk 1%..120% and assert the level never goes BACKWARDS. This is the
        // property that makes the border readable as one rising signal, and it
        // catches a mis-ordered comparison chain that spot-checks would miss.
        func rank(_ l: BorderDash.Level) -> Int {
            switch l {
            case .empty: return 0
            case .trace: return 1
            case .notice: return 2
            case .amber: return 3
            case .alarm: return 4
            }
        }
        var previous = 0
        for percent in 1...120 {
            let current = rank(BorderDash.level(forFraction: Double(percent) / 100.0))
            #expect(current >= previous, "level went backwards at \(percent)%")
            previous = current
        }
        // And all four spending bands actually occur somewhere in the range.
        let seen = Set((1...120).map { rank(BorderDash.level(forFraction: Double($0) / 100.0)) })
        #expect(seen == [1, 2, 3, 4])
    }

    @Test("the visual alarm and the factual 'budget spent' stay separate")
    func alarmIsNotTheSameAsFull() {
        // This is the invariant that keeps the earlier red loop honest: at 95%
        // the border shouts, but the app must NOT claim the budget is gone —
        // isFull drives content dimming and the exhausted pace verdict.
        #expect(BorderDash.level(forFraction: 0.95) == .alarm)
        #expect(BorderDash.isFull(0.95) == false)
        // And at 100% both agree.
        #expect(BorderDash.level(forFraction: 1.0) == .alarm)
        #expect(BorderDash.isFull(1.0) == true)
    }
}
