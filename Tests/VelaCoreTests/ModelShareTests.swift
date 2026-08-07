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
}
