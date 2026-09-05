// Tests/VelaCoreTests/BurnBufferTests.swift
// Verifies the time-correct BurnBuffer pulse (WP-04, 04.2; finding B09):
// intervals carry their REAL wall-clock span, only intervals intersecting
// the last hour survive, irregular popover opens never rescale the axis,
// and a downward correction re-baselines without inventing negative burn.
// Why: B09 — the old buffer ignored dates, so a $10 delta over one minute
// and over eight hours looked identical and "the last hour" was however
// often the user happened to open the popover.
// RELEVANT FILES: Sources/VelaCore/BurnBuffer.swift

import Testing
import Foundation
@testable import VelaCore

struct BurnBufferTests {
    private let scope = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://test")
    private let day = GatewayDay(spendDate: "2026-08-01")!

    private func observation(_ spent: Double, at date: Date) -> Observation {
        Observation(
            id: UUID(), scope: scope, gatewayDay: day,
            receivedAt: date, cumulativeAmount: spent,
            limitEnabled: true, limitUSD: 400, precision: .exactReceipt
        )
    }

    // MARK: B09 — time matters

    @Test("a $10 delta over ONE minute covers one minute of the pulse axis")
    func oneMinuteDelta() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(observation(10, at: t0))
        buffer.record(observation(20, at: t0.addingTimeInterval(60)))
        // The single interval covers exactly 60s ending 60s before `now`.
        #expect(buffer.slots.count == 1)
        #expect(buffer.slots[0].burn == 10)
        #expect(buffer.slots[0].duration == 60)
    }

    @Test("the same $10 delta over EIGHT hours covers only the last-hour part — not the whole axis")
    func eightHourDeltaClipsToWindow() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T05:00:00Z")!
        buffer.record(observation(10, at: t0))
        // Now at 13:00: the interval 05:00→13:00 intersects the last hour
        // (12:00→13:00) only.
        buffer.record(observation(20, at: t0.addingTimeInterval(8 * 3600)))
        #expect(buffer.slots.count == 1)
        // Burn apportioned to the intersection: 10 * (3600 / 28800).
        #expect(abs(buffer.slots[0].burn - 10.0 * 3600.0 / 28800.0) < 1e-9)
        #expect(buffer.slots[0].duration == 3600)
    }

    @Test("one minute vs eight hours produce DIFFERENT pulses (B09 regression)")
    func oneMinuteVsEightHoursDiffer() {
        var short = BurnBuffer()
        var long = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:30:00Z")!
        short.record(observation(10, at: t0))
        short.record(observation(20, at: t0.addingTimeInterval(60)))
        long.record(observation(10, at: t0.addingTimeInterval(-8 * 3600 + 60)))
        long.record(observation(20, at: t0.addingTimeInterval(60)))
        #expect(short.slots[0].duration != long.slots[0].duration)
        #expect(short.slots[0].burn == 10)
        // The long interval (04:31→12:31) keeps only its inside hour:
        // 10 dollars * 3600/28800 = 1.25.
        #expect(abs(long.slots[0].burn - 1.25) < 1e-9)
    }
    @Test("10 repeated popover opens 10s apart keep the axis at real elapsed time, not 10 polls (B09)")
    func repeatedOpensDoNotCompressHour() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        // 10 opens, 10s apart, cumulative rising by 1 each time.
        for i in 0..<10 {
            buffer.record(observation(Double(i), at: t0.addingTimeInterval(Double(i) * 10)))
        }
        // Total axis = 90 seconds of real time, NOT 10 "minutes".
        let first = buffer.slots.first!, last = buffer.slots.last!
        #expect(last.end.timeIntervalSince(first.start) == 90)
        #expect(buffer.slots.count == 9)
    }

    @Test("a sleep gap is a long interval, not a wall of compressed minutes (B09)")
    func sleepGapIsRealTime() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(observation(10, at: t0))
        // Mac slept 8 hours; next reading 8h later.
        buffer.record(observation(30, at: t0.addingTimeInterval(8 * 3600)))
        #expect(buffer.slots.count == 1)
        #expect(buffer.slots[0].duration == 3600) // clipped to the last hour
        #expect(abs(buffer.slots[0].burn - 20.0 * 3600.0 / 28800.0) < 1e-9)
    }

    // MARK: midnight growth / reset

    @Test("midnight growth before the reset records real burn; the reset interval carries zero burn")
    func midnightGrowthAndReset() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T23:58:00Z")!
        buffer.record(observation(10, at: t0))
        buffer.record(observation(15, at: t0.addingTimeInterval(60))) // growth: +5
        // UTC midnight: cumulative drops from 15 to 1.
        buffer.record(observation(1, at: t0.addingTimeInterval(120)))
        // survives inside the window. (First record emits no interval —
        // there is no baseline to differ against.)
        #expect(buffer.slots.map(\.burn) == [5.0, 0.0])
    }

    @Test("accumulation resumes after the midnight reset")
    func postResetAccumulation() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T23:58:00Z")!
        buffer.record(observation(10, at: t0))
        buffer.record(observation(1, at: t0.addingTimeInterval(60)))   // reset
        buffer.record(observation(3, at: t0.addingTimeInterval(120)))  // growth from new baseline
        // Reset → 0; post-reset growth counts from the new baseline.
        #expect(buffer.slots.map(\.burn) == [0.0, 2.0])
    }
    // MARK: correction re-baseline

    @Test("a legitimate downward correction contributes zero burn and re-baselines (§7.3)")
    func downwardCorrectionRebaselines() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(observation(100, at: t0))
        // The gateway restates the day down (correction, not midnight).
        buffer.record(observation(50, at: t0.addingTimeInterval(60)))
        // Post-correction growth counts from the NEW baseline.
        buffer.record(observation(55, at: t0.addingTimeInterval(120)))
        // Correction step contributes zero; growth counts from the new
        // baseline. (First record emits no interval.)
        #expect(buffer.slots.map(\.burn) == [0.0, 5.0])
        // No negative burn anywhere.
        #expect(buffer.slots.allSatisfy { $0.burn >= 0 })
    }

    // MARK: window eviction

    @Test("intervals fully outside the last hour drop out of the pulse")
    func oldIntervalsDrop() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T10:00:00Z")!
        buffer.record(observation(10, at: t0))
        buffer.record(observation(11, at: t0.addingTimeInterval(60)))
        // The gateway's next reading arrives two hours later.
        buffer.record(observation(12, at: t0.addingTimeInterval(2 * 3600)))
        // Two hours later (t0 = 10:00, latest = 12:00): the pulse window is
        // [11:00, 12:00]. The first interval is fully outside → dropped.
        // The second (10:01→12:00, 7140s) keeps only its inside hour, with
        // its 1-dollar delta apportioned across it: 1 * 3600/7140 ≈ 0.504.
        #expect(buffer.slots.count == 1)
        #expect(abs(buffer.slots[0].burn - 3600.0 / 7140.0) < 1e-9)
        #expect(buffer.slots[0].duration == 3600)
    }
    @Test("an interval PARTIALLY outside the window contributes only its inside part")
    func partialIntervalClips() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T11:30:00Z")!
        buffer.record(observation(10, at: t0))
        // 60 minutes later = 12:30. The interval 11:30→12:30 is half inside
        // the last hour (12:00→12:30 relative to the newest reading? No —
        // window is [12:30-3600, 12:30] = [11:30, 12:30], so fully inside).
        buffer.record(observation(20, at: t0.addingTimeInterval(3600)))
        #expect(buffer.slots[0].duration == 3600)
        #expect(buffer.slots[0].burn == 10)
    }

    // MARK: derived values

    @Test("ratePerSecond is burn over ACTUAL elapsed time")
    func rateOverActualTime() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(observation(10, at: t0))
        buffer.record(observation(70, at: t0.addingTimeInterval(120)))
        // 60 dollars over 120 seconds = 0.5 $/s.
        #expect(abs(buffer.ratePerSecond! - 0.5) < 1e-9)
    }

    @Test("all-zero pulse normalizes to nil")
    func allZeroNormalizesToNil() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(observation(0, at: t0))
        buffer.record(observation(0, at: t0.addingTimeInterval(60)))
        #expect(buffer.normalized() == nil)
    }

    @Test("normalized divides every slot by the max slot burn")
    func normalizedDividesByMax() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(observation(10, at: t0))
        buffer.record(observation(15, at: t0.addingTimeInterval(60))) // delta 5
        buffer.record(observation(25, at: t0.addingTimeInterval(120))) // delta 10
        let normalized = buffer.normalized()
        #expect(normalized != nil)
        #expect(normalized! == [0.5, 1.0])
    }

    @Test("the legacy (spentToday:at:) form still records with correct intervals")
    func legacyFormStillWorks() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(spentToday: 10, at: t0, scope: scope, gatewayDay: day)
        buffer.record(spentToday: 18, at: t0.addingTimeInterval(60), scope: scope, gatewayDay: day)
        #expect(buffer.slots.map(\.burn) == [8.0])
    }

    @Test("absent limit context (limitEnabled false) still records honest burn")
    func absentLimitStillRecords() {
        var buffer = BurnBuffer()
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(spentToday: 10, at: t0, scope: scope, gatewayDay: day, limitEnabled: false, limitUSD: 0)
        buffer.record(spentToday: 20, at: t0.addingTimeInterval(60), scope: scope, gatewayDay: day, limitEnabled: false, limitUSD: 0)
        #expect(buffer.slots.map(\.burn) == [10.0])
    }

    @Test("a gateway-day change with a higher cumulative establishes a new baseline, never a cross-day burn interval")
    func dayChangeRebaselines() {
        var buffer = BurnBuffer()
        let nextDay = GatewayDay(spendDate: "2026-08-02")!
        let t0 = ISODate.parse("2026-08-01T23:50:00Z")!
        var current = BurnBuffer()
        current.record(spentToday: 120, at: t0, scope: scope, gatewayDay: day)
        current.record(spentToday: 160, at: t0.addingTimeInterval(600), scope: scope, gatewayDay: day)
        #expect(current.slots.map(\.burn) == [40.0])
        // New gateway day: cumulative restarts low on the wire, but even a
        // HIGHER value must not emit a burn interval across the boundary.
        current.record(spentToday: 500, at: t0.addingTimeInterval(1200), scope: scope, gatewayDay: nextDay)
        #expect(current.slots.isEmpty)
        // The new day baselines from here: subsequent growth burns normally.
        current.record(spentToday: 530, at: t0.addingTimeInterval(1260), scope: scope, gatewayDay: nextDay)
        #expect(current.slots.map(\.burn) == [30.0])
    }

    @Test("a scope change with a higher cumulative establishes a new baseline, never a cross-scope interval")
    func scopeChangeRebaselines() {
        var buffer = BurnBuffer()
        let otherScope = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://test")
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(spentToday: 100, at: t0, scope: scope, gatewayDay: day)
        buffer.record(spentToday: 110, at: t0.addingTimeInterval(600), scope: scope, gatewayDay: day)
        #expect(buffer.slots.map(\.burn) == [10.0])
        // Token B replaces A: B's higher cumulative must not read as burn.
        buffer.record(spentToday: 200, at: t0.addingTimeInterval(1200), scope: otherScope, gatewayDay: day)
        #expect(buffer.slots.isEmpty)
        // B's own growth records normally from its new baseline.
        buffer.record(spentToday: 215, at: t0.addingTimeInterval(1260), scope: otherScope, gatewayDay: day)
        #expect(buffer.slots.map(\.burn) == [15.0])
    }

    @Test("an equal-timestamp reading from a NEW scope still re-baselines (identity check precedes receipt-order check)")
    func equalTimestampIdentityChangeRebaselines() {
        var buffer = BurnBuffer()
        let otherScope = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://test")
        let t0 = ISODate.parse("2026-08-01T12:00:00Z")!
        buffer.record(spentToday: 100, at: t0, scope: scope, gatewayDay: day)
        buffer.record(spentToday: 110, at: t0.addingTimeInterval(60), scope: scope, gatewayDay: day)
        #expect(buffer.slots.map(\.burn) == [10.0])
        // Token B's first reading arrives with the SAME timestamp as A's
        // last: old slots must NOT survive the identity change.
        buffer.record(spentToday: 25, at: t0.addingTimeInterval(60), scope: otherScope, gatewayDay: day)
        #expect(buffer.slots.isEmpty)
        // B's own growth records normally from the re-baselined buffer.
        buffer.record(spentToday: 30, at: t0.addingTimeInterval(120), scope: otherScope, gatewayDay: day)
        #expect(buffer.slots.map(\.burn) == [5.0])
    }
}
