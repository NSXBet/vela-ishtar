// Tests/VelaCoreTests/ColdOpenSnapshotTests.swift
// Regression tests for the cold-open numbers jump (v0.3.4): on a cold start
// the popover used to show a blank/spinner for 0.5–1s because the loading
// branch suppresses all data until the first fetch lands. coldOpenSnapshot
// rehydrates the last TODAY reading from history so the hero shows instantly.
// Why: the one hard invariant is "never show yesterday as today" — a stale
// day-keyed record must yield nil, or the popover would present old spend as
// the current day's at midnight.
// RELEVANT FILES: Sources/VelaCore/PollStateMachine.swift, Sources/VelaCore/HistoryStore.swift

import Testing
import Foundation
@testable import VelaCore

struct ColdOpenSnapshotTests {
    static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaColdOpenTests-\(UUID().uuidString)")
    }

    /// Builds the minimal UsageResponse that makes ingest() record one
    /// history reading for `spendDate` at `date`.
    private static func response(spent: Double, limit: Double, spendDate: String) -> UsageResponse {
        UsageResponse(
            tokenId: "tok",
            dailyBudget: DailyBudget(limitUSD: limit, spentUSD: spent, remainingUSD: limit - spent, usedPercent: 100 * spent / limit, limitEnabled: true, spendDate: spendDate),
            currentMonth: MonthStats(totalCostUSD: spent, totalTokens: 0, requests: 0),
            topModels: []
        )
    }

    @Test("a record keyed to today returns spent, limit, and age since the hour slot")
    func todayKeyedRecordReturnsSnapshot() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        // 14:23 UTC; ingest keys the record by the GATEWAY's day (spendDate),
        // which at 14:23 is unambiguously today.
        let now = ISODate.parse("2026-08-07T14:23:00Z")!
        machine.ingest(.success(Self.response(spent: 42.5, limit: 400, spendDate: "2026-08-07")), at: now)

        let snapshot = machine.coldOpenSnapshot(now: now)
        #expect(snapshot != nil)
        #expect(snapshot!.spentUSD == 42.5)
        #expect(snapshot!.limitUSD == 400)
        // Age is measured from the START of the recorded hour slot (the poll
        // that wrote slot 14 happened at ~14:00), so at 14:23 the reading is
        // 23 minutes old — the honest "last reading" age, not zero.
        #expect(snapshot!.ageMinutes == 23)
    }

    @Test("only-yesterday records return nil — never show yesterday as today")
    func onlyYesterdayRecordsReturnNil() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        // Now is 00:30 UTC on Aug 7. History holds only Aug 6 — a day that
        // has rolled over. Showing it would present yesterday's total as
        // today's at the midnight seam.
        machine.ingest(.success(Self.response(spent: 87, limit: 400, spendDate: "2026-08-06")), at: ISODate.parse("2026-08-06T23:10:00Z")!)
        let now = ISODate.parse("2026-08-07T00:30:00Z")!

        #expect(machine.coldOpenSnapshot(now: now) == nil)
    }

    @Test("empty history returns nil — true first run keeps the spinner")
    func emptyHistoryReturnsNil() {
        let machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        let now = ISODate.parse("2026-08-07T09:00:00Z")!
        #expect(machine.coldOpenSnapshot(now: now) == nil)
    }

    @Test("age counts whole minutes since the last observed hour")
    func ageReflectsLastObservedHour() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        // Reading recorded at 14:00 UTC (hour slot 14); now is 15:45 UTC.
        // The snapshot is 1h45m old = 105 minutes.
        machine.ingest(.success(Self.response(spent: 10, limit: 400, spendDate: "2026-08-07")), at: ISODate.parse("2026-08-07T14:00:00Z")!)
        let now = ISODate.parse("2026-08-07T15:45:00Z")!

        let snapshot = machine.coldOpenSnapshot(now: now)
        #expect(snapshot != nil)
        #expect(snapshot!.ageMinutes == 105)
    }

    @Test("a reading in a FUTURE hour slot is never shown as the current reading")
    func futureSlotIsRefused() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        // Clock skew / a hand-edited history can leave a reading stamped in an
        // hour later than "now". Ingest at 14:00 writes slot 14; asking for a
        // snapshot at 09:00 (same UTC day) must NOT surface that future slot
        // as "just now" — the only honest answer is nil (nothing yet today).
        machine.ingest(.success(Self.response(spent: 99, limit: 400, spendDate: "2026-08-07")), at: ISODate.parse("2026-08-07T14:00:00Z")!)
        let skewedNow = ISODate.parse("2026-08-07T09:00:00Z")!

        #expect(machine.coldOpenSnapshot(now: skewedNow) == nil)
    }
}
