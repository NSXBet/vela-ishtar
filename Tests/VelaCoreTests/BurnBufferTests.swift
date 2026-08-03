// Tests/VelaCoreTests/BurnBufferTests.swift
// Verifies BurnBuffer's delta math (cumulative-spend -> per-poll deltas),
// the midnight-UTC reset clamp, capacity eviction, and normalization.
// Why: this buffer feeds the sparkline in the popover; wrong deltas or a
// missed reset would draw a nonsense spike at every UTC midnight.
// RELEVANT FILES: Sources/VelaCore/BurnBuffer.swift

import Testing
import Foundation
@testable import VelaCore

struct BurnBufferTests {
    @Test("first record after init stores a zero delta (no prior baseline)")
    func firstRecordIsZero() {
        var buffer = BurnBuffer()
        buffer.record(spentToday: 10.0, at: Date())
        #expect(buffer.slots == [0.0])
    }

    @Test("subsequent records store the delta from the previous cumulative spend")
    func deltaMath() {
        var buffer = BurnBuffer()
        let t0 = Date()
        buffer.record(spentToday: 10.0, at: t0)
        buffer.record(spentToday: 15.0, at: t0.addingTimeInterval(60))
        buffer.record(spentToday: 18.5, at: t0.addingTimeInterval(120))
        #expect(buffer.slots == [0.0, 5.0, 3.5])
    }

    @Test("a negative delta (midnight UTC reset) is clamped to zero but does not clear prior slots")
    func midnightResetClamp() {
        var buffer = BurnBuffer()
        let t0 = Date()
        buffer.record(spentToday: 20.0, at: t0)
        buffer.record(spentToday: 25.0, at: t0.addingTimeInterval(60))
        // spend dropped -> today's cumulative reset at UTC midnight.
        buffer.record(spentToday: 1.0, at: t0.addingTimeInterval(120))
        // The prior slots (0, 5) are real burned minutes and must survive;
        // only this poll's negative delta is clamped to 0, not wiped away.
        #expect(buffer.slots == [0.0, 5.0, 0.0])
    }

    @Test("accumulation resumes normally after a midnight-reset clamp")
    func postResetAccumulation() {
        var buffer = BurnBuffer()
        let t0 = Date()
        buffer.record(spentToday: 20.0, at: t0)
        buffer.record(spentToday: 25.0, at: t0.addingTimeInterval(60))
        // Midnight UTC reset: cumulative spend drops back down.
        buffer.record(spentToday: 1.0, at: t0.addingTimeInterval(120))
        // Spend resumes accumulating from the new (post-reset) baseline.
        buffer.record(spentToday: 3.0, at: t0.addingTimeInterval(180))
        #expect(buffer.slots == [0.0, 5.0, 0.0, 2.0])
    }

    @Test("all-zero buffer normalizes to nil")
    func allZeroNormalizesToNil() {
        var buffer = BurnBuffer()
        buffer.record(spentToday: 0.0, at: Date())
        #expect(buffer.normalized() == nil)
    }

    @Test("normalized divides every slot by the max slot")
    func normalizedDividesByMax() {
        var buffer = BurnBuffer()
        let t0 = Date()
        buffer.record(spentToday: 10.0, at: t0)
        buffer.record(spentToday: 15.0, at: t0.addingTimeInterval(60)) // delta 5
        buffer.record(spentToday: 25.0, at: t0.addingTimeInterval(120)) // delta 10
        let normalized = buffer.normalized()
        #expect(normalized != nil)
        #expect(normalized! == [0.0, 0.5, 1.0])
    }

    @Test("capacity evicts the oldest slot once 61 records have landed")
    func capacityEviction() {
        var buffer = BurnBuffer()
        let t0 = Date()
        // Record 61 times, spend increasing by 1 each time so deltas are
        // [0, 1, 1, 1, ...] (61 deltas total).
        for i in 0..<61 {
            buffer.record(spentToday: Double(i), at: t0.addingTimeInterval(Double(i) * 60))
        }
        #expect(buffer.slots.count == BurnBuffer.capacity)
        // The very first delta (0) should have been evicted; oldest
        // remaining slot is the second delta (1).
        #expect(buffer.slots.first == 1.0)
        #expect(buffer.slots.last == 1.0)
    }
}
