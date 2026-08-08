// Tests/VelaCoreTests/ModelShareTests.swift
// Pins the per-model share-of-spend percentage shown inline on each model row
// (v0.5.0 replaces the 2pt bar with `name · 62%`). The share is information,
// not decoration — so its rounding rules are specified here, not guessed in
// the view.
// RELEVANT FILES: Sources/VelaCore/ModelShare.swift, Sources/App/PopoverView.swift

import Testing
@testable import VelaCore

@Suite("ModelShare.percent")
struct ModelShareTests {

    @Test("a clean share rounds to the nearest whole percent")
    func cleanShare() {
        #expect(ModelShare.percent(cost: 62.0, total: 100.0) == 62)
        #expect(ModelShare.percent(cost: 1.0, total: 3.0) == 33)   // 33.3…
    }

    @Test("half a percent rounds up")
    func halfRoundsUp() {
        #expect(ModelShare.percent(cost: 12.5, total: 100.0) == 13)
    }

    @Test("a nonzero cost never shows 0% — presence must be visible")
    func floorIsOne() {
        #expect(ModelShare.percent(cost: 0.1, total: 100.0) == 1)
        #expect(ModelShare.percent(cost: 0.004, total: 100.0) == 1)
    }

    @Test("zero cost shows 0, not the floor")
    func zeroCost() {
        #expect(ModelShare.percent(cost: 0, total: 100.0) == 0)
    }

    @Test("a zero or negative total (degenerate) shows 0, never a divide-by-zero")
    func zeroTotal() {
        #expect(ModelShare.percent(cost: 50.0, total: 0) == 0)
        #expect(ModelShare.percent(cost: 50.0, total: -10) == 0)
    }

    @Test("a full share is 100, never 101 from rounding")
    func fullShare() {
        #expect(ModelShare.percent(cost: 100.0, total: 100.0) == 100)
    }

    @Test("a non-finite cost (overflowed to infinity, or NaN) shows 0, never traps")
    func nonFiniteCost() {
        // 1e999 overflows Double to +inf. It passes the `cost > 0` guard, so
        // `raw` is inf and `Int(inf.rounded())` is a fatal trap — the whole
        // popover dies because one model's cost column overflowed. NaN is the
        // same shape of garbage (0/0 upstream) and must degrade the same way.
        #expect(ModelShare.percent(cost: 1e999, total: 100.0) == 0)
        #expect(ModelShare.percent(cost: .nan, total: 100.0) == 0)
    }

    @Test("an infinite total still floors a finite nonzero cost at 1%")
    func infiniteTotal() {
        // 50/inf is a finite 0, so the floor-at-1 rule applies: a real cost
        // against an unbounded total is a real (if tiny) share, and presence
        // stays visible. Not the infinity trap — pinned so the two cases
        // can't be confused.
        #expect(ModelShare.percent(cost: 50.0, total: 1e999) == 1)
    }

    @Test("a finite-but-huge share (beyond Int64.max) clamps to 100, never traps")
    func finiteHugeShareClamps() {
        // 1e17/1.0 = 1e19 percent — finite, so it passes the isFinite guard,
        // but 1e19 > Int64.max (~9.2e18) and Int(raw.rounded()) traps just
        // as fatally as the infinite case. The percentage must be clamped to
        // the 0...100 range BEFORE the Int conversion, not after.
        #expect(ModelShare.percent(cost: 1e17, total: 1.0) == 100)
    }
}
