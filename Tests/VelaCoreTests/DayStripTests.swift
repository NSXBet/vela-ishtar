// Tests/VelaCoreTests/DayStripTests.swift
// Verifies DayStrip.week: the 7-day window of day totals that backs the
// popover's hairline strip under the curve.
// Why: the strip is a comparison surface — a wrong total or a mis-ordered
// day reads as "you spent more/less than you did," so the extraction and
// ordering rules are pinned exactly.
// RELEVANT FILES: Sources/VelaCore/DayStrip.swift, Sources/VelaCore/HistoryStore.swift

import Testing
import Foundation
@testable import VelaCore

struct DayStripTests {
    private func makeDay(hours: [Int: Double], exhaustedAt: Date? = nil) -> DayRecord {
        var hourly: [Double?] = Array(repeating: nil, count: 24)
        for (hour, value) in hours { hourly[hour] = value }
        return DayRecord(hourly: hourly, limit: 100, exhaustedAt: exhaustedAt)
    }

    @Test("week returns the last 7 days ending at today, oldest first")
    func weekWindowAndOrder() {
        var days: [String: DayRecord] = [:]
        for i in 1...10 {
            days[String(format: "2026-08-%02d", i)] = makeDay(hours: [23: Double(i)])
        }
        let week = DayStrip.week(in: days, today: "2026-08-10")
        #expect(week.count == 7)
        #expect(week.map(\.key) == (4...10).map { String(format: "2026-08-%02d", $0) })
    }

    @Test("a day's total is its final non-nil hourly reading")
    func dayTotalIsFinalSlot() {
        let days: [String: DayRecord] = [
            "2026-08-10": makeDay(hours: [9: 30, 14: 55, 22: 42]),  // dip: final slot wins
        ]
        let week = DayStrip.week(in: days, today: "2026-08-10")
        #expect(week.last?.total == 42)
    }

    @Test("today's in-progress total comes from its latest slot")
    func todayInProgress() {
        let days: [String: DayRecord] = [
            "2026-08-10": makeDay(hours: [9: 12.5]),
        ]
        let week = DayStrip.week(in: days, today: "2026-08-10")
        #expect(week.last?.key == "2026-08-10")
        #expect(week.last?.total == 12.5)
        #expect(week.last?.isToday == true)
    }

    @Test("days with no readings keep their place with a nil total")
    func gapsStayGaps() {
        let days: [String: DayRecord] = [
            "2026-08-09": makeDay(hours: [20: 40]),
            "2026-08-10": makeDay(hours: [10: 5]),
        ]
        let week = DayStrip.week(in: days, today: "2026-08-10")
        // 7 slots regardless; the 5 unobserved days have nil totals.
        #expect(week.count == 7)
        #expect(week.filter { $0.total == nil }.count == 5)
        #expect(week[5].key == "2026-08-09" && week[5].total == 40)
    }

    @Test("the window crosses a month boundary by calendar math, not string math")
    func weekCrossesMonthBoundary() {
        var days: [String: DayRecord] = [:]
        // 2026-08-01 is a Saturday; the window back from it ends 2026-07-26.
        days["2026-07-31"] = makeDay(hours: [23: 31])
        days["2026-08-01"] = makeDay(hours: [10: 1])
        let week = DayStrip.week(in: days, today: "2026-08-01")
        #expect(week.first?.key == "2026-07-26")
        #expect(week.last?.key == "2026-08-01")
        #expect(week.first { $0.key == "2026-07-31" }?.total == 31)
    }

    @Test("an exhaustedAt day is flagged for the scar tick")
    func exhaustionFlag() {
        let crossed = ISODate.parse("2026-08-09T14:22:00Z")!
        let days: [String: DayRecord] = [
            "2026-08-09": makeDay(hours: [23: 160], exhaustedAt: crossed),
            "2026-08-10": makeDay(hours: [10: 5]),
        ]
        let week = DayStrip.week(in: days, today: "2026-08-10")
        #expect(week.first { $0.key == "2026-08-09" }?.exhausted == true)
        #expect(week.first { $0.key == "2026-08-10" }?.exhausted == false)
    }

    @Test("a full-ISO today key still resolves its 7-day window")
    func weekNormalizesFullISOToday() {
        var days: [String: DayRecord] = [:]
        for i in 4...10 {
            days[String(format: "2026-08-%02d", i)] = makeDay(hours: [23: Double(i)])
        }
        let week = DayStrip.week(in: days, today: "2026-08-10T00:00:00Z")
        #expect(week.count == 7)
        #expect(week.last?.key == "2026-08-10")
        #expect(week.last?.isToday == true)
        #expect(week.last?.total == 10)
    }

    @Test("sparse history yields the nil-slot count the v0.3.2 display gate keys on")
    func sparseWeekExposesNilSlots() {
        // The v0.3.2 gate hides the strip when fewer than 4 of 7 days have
        // data — a 3-day history renders as floating ticks. The App layer
        // reads `day.total != nil` per slot, so pin that a sparse history
        // produces exactly the nil distribution the gate counts: a week
        // window always has 7 slots, and days absent from history come
        // back with nil totals.
        var days: [String: DayRecord] = [:]
        days["2026-08-08"] = makeDay(hours: [23: 50])
        days["2026-08-09"] = makeDay(hours: [23: 60])
        days["2026-08-10"] = makeDay(hours: [23: 70])
        let week = DayStrip.week(in: days, today: "2026-08-10")
        #expect(week.count == 7)
        #expect(week.filter { $0.total != nil }.count == 3)   // below the >=4 gate
        // And crossing the gate: add a fourth day and the count flips.
        days["2026-08-05"] = makeDay(hours: [23: 40])
        let week4 = DayStrip.week(in: days, today: "2026-08-10")
        #expect(week4.filter { $0.total != nil }.count == 4)  // at the >=4 gate
    }
}
