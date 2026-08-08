// Tests/VelaCoreTests/DayStripTests.swift
// Verifies DayStrip.week: the Monday–Sunday calendar week of day totals that
// backs the popover's cell strip, plus the per-day hover readout.
// Why: the strip is a comparison surface — a wrong total, a mis-ordered day,
// or a future day counted as real reads as "you spent more/less than you did,"
// so the extraction and ordering rules are pinned exactly.
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

    // Reference week used across these tests: Mon 2026-08-03 … Sun 2026-08-09.
    // Thu 2026-08-06 is the canonical "today lands mid-week" anchor (index 3,
    // with three future days after it).
    private let mondayFirstWeek = [
        "2026-08-03", "2026-08-04", "2026-08-05",
        "2026-08-06", "2026-08-07", "2026-08-08", "2026-08-09",
    ]

    @Test("week returns the calendar week Monday-first, not a rolling window")
    func weekIsMondayFirstCalendarWeek() {
        var days: [String: DayRecord] = [:]
        for i in 1...10 {
            days[String(format: "2026-08-%02d", i)] = makeDay(hours: [23: Double(i)])
        }
        // Thursday. A rolling 7-day window would have ended here (07-31…08-06);
        // the calendar week starts on Monday and runs to Sunday instead.
        let week = DayStrip.week(in: days, today: "2026-08-06")
        #expect(week.count == 7)
        #expect(week.map(\.key) == mondayFirstWeek)
    }

    @Test("today sits mid-week wherever it falls, not at the last slot")
    func todayLandsMidWeek() {
        let days: [String: DayRecord] = [
            "2026-08-06": makeDay(hours: [9: 12.5]),
        ]
        let week = DayStrip.week(in: days, today: "2026-08-06")
        // Thursday is index 3 of Mon…Sun — the GitHub-style "now" edge advances
        // through a fixed row rather than always pinning to the right end.
        #expect(week.map(\.isToday) == [false, false, false, true, false, false, false])
        #expect(week[3].key == "2026-08-06")
        #expect(week[3].total == 12.5)
    }

    @Test("Monday and Sunday anchor correctly at both ends of the week")
    func weekAnchorsAtBothEnds() {
        let days: [String: DayRecord] = [:]
        // Monday is index 0 and its week runs FORWARD from it.
        let fromMonday = DayStrip.week(in: days, today: "2026-08-03")
        #expect(fromMonday.first?.key == "2026-08-03")
        #expect(fromMonday.first?.isToday == true)
        #expect(fromMonday.last?.key == "2026-08-09")
        // Sunday is index 6 — it closes the week it belongs to, and must NOT
        // roll into the next one (the classic off-by-one on a Sunday=1 calendar).
        let fromSunday = DayStrip.week(in: days, today: "2026-08-09")
        #expect(fromSunday.map(\.key) == mondayFirstWeek)
        #expect(fromSunday.last?.isToday == true)
    }

    @Test("days after today this week are future — nil, like a no-data day")
    func futureDaysAreNil() {
        var days: [String: DayRecord] = [:]
        // Every day of the week has a record, INCLUDING the three after today.
        // (Clock skew or a spend_date running ahead can genuinely produce this.)
        for key in mondayFirstWeek { days[key] = makeDay(hours: [23: 50]) }
        let week = DayStrip.week(in: days, today: "2026-08-06")
        // Mon…Thu are real; Fri/Sat/Sun read as the gap they are.
        #expect(week.prefix(4).allSatisfy { $0.total == 50 })
        #expect(week.suffix(3).allSatisfy { $0.total == nil })
        // A day that hasn't happened must not join the week's max, or every
        // other cell gets bucketed against a phantom.
        #expect(week.compactMap(\.total).count == 4)
    }

    @Test("a day's total is its final non-nil hourly reading")
    func dayTotalIsFinalSlot() {
        let days: [String: DayRecord] = [
            "2026-08-06": makeDay(hours: [9: 30, 14: 55, 22: 42]),  // dip: final slot wins
        ]
        let week = DayStrip.week(in: days, today: "2026-08-06")
        #expect(week[3].total == 42)
    }

    @Test("days with no readings keep their place with a nil total")
    func gapsStayGaps() {
        let days: [String: DayRecord] = [
            "2026-08-04": makeDay(hours: [20: 40]),
            "2026-08-06": makeDay(hours: [10: 5]),
        ]
        let week = DayStrip.week(in: days, today: "2026-08-06")
        // 7 slots regardless: 2 observed, 2 past gaps (Mon, Wed), 3 future.
        #expect(week.count == 7)
        #expect(week.filter { $0.total == nil }.count == 5)
        #expect(week[1].key == "2026-08-04" && week[1].total == 40)
    }

    @Test("the week crosses a month boundary by calendar math, not string math")
    func weekCrossesMonthBoundary() {
        var days: [String: DayRecord] = [:]
        // 2026-08-01 is a Saturday, so its week starts Monday 2026-07-27 —
        // a key no amount of arithmetic on "2026-08-01" would produce.
        days["2026-07-31"] = makeDay(hours: [23: 31])
        days["2026-08-01"] = makeDay(hours: [10: 1])
        let week = DayStrip.week(in: days, today: "2026-08-01")
        #expect(week.first?.key == "2026-07-27")
        #expect(week.last?.key == "2026-08-02")
        #expect(week[5].key == "2026-08-01" && week[5].isToday == true)
        #expect(week.first { $0.key == "2026-07-31" }?.total == 31)
    }

    @Test("the week crosses a YEAR boundary the same way")
    func weekCrossesYearBoundary() {
        // Thu 2026-01-01 — its Monday is 2025-12-29, a different year.
        let days: [String: DayRecord] = ["2025-12-30": makeDay(hours: [23: 12])]
        let week = DayStrip.week(in: days, today: "2026-01-01")
        #expect(week.first?.key == "2025-12-29")
        #expect(week[3].key == "2026-01-01" && week[3].isToday == true)
        #expect(week[1].total == 12)
    }

    @Test("an exhaustedAt day is flagged for the scar tick")
    func exhaustionFlag() {
        let crossed = ISODate.parse("2026-08-04T14:22:00Z")!
        let days: [String: DayRecord] = [
            "2026-08-04": makeDay(hours: [23: 160], exhaustedAt: crossed),
            "2026-08-06": makeDay(hours: [10: 5]),
        ]
        let week = DayStrip.week(in: days, today: "2026-08-06")
        #expect(week.first { $0.key == "2026-08-04" }?.exhausted == true)
        #expect(week.first { $0.key == "2026-08-06" }?.exhausted == false)
    }

    @Test("a full-ISO today key still resolves its calendar week")
    func weekNormalizesFullISOToday() {
        var days: [String: DayRecord] = [:]
        for key in mondayFirstWeek { days[key] = makeDay(hours: [23: 7]) }
        let week = DayStrip.week(in: days, today: "2026-08-06T00:00:00Z")
        #expect(week.count == 7)
        #expect(week.map(\.key) == mondayFirstWeek)
        #expect(week[3].isToday == true)
        #expect(week[3].total == 7)
    }

    // MARK: - GatewayDay (label, not instant)

    @Test("a non-UTC-midnight spend_date label anchors the week, not the UTC instant")
    func weekAnchorsOnLabelNotInstant() {
        // "2026-08-07T00:00:00+03:00" is the gateway's label for Fri Aug 7.
        // Parsed as an INSTANT and reformatted in UTC it is Aug 6 21:00 — a
        // Thursday — which would shift today onto the wrong weekday and slide
        // the whole Mon–Sun window back a day. Anchoring on the LABEL keeps
        // today on Friday Aug 7 (index 4).
        var days: [String: DayRecord] = [:]
        for key in mondayFirstWeek { days[key] = makeDay(hours: [23: 7]) }
        let week = DayStrip.week(in: days, today: "2026-08-07T00:00:00+03:00")
        #expect(week.count == 7)
        #expect(week.map(\.key) == mondayFirstWeek)          // week NOT shifted
        #expect(week[4].key == "2026-08-07")
        #expect(week[4].isToday == true)                     // Friday, not Thursday
        #expect(week[4].total == 7)                          // today's cell filled
    }

    @Test("sparse history yields the nil-slot count the display gate keys on")
    func sparseWeekExposesNilSlots() {
        // The display gate hides the strip when fewer than 4 days carry data —
        // a 3-day history renders as floating cells. The App layer reads
        // `day.total != nil` per slot, so pin that a sparse history produces
        // exactly the nil distribution the gate counts. With a Monday-first
        // week the gate now counts Mon..today, so future days can never help
        // it across the line.
        var days: [String: DayRecord] = [:]
        days["2026-08-04"] = makeDay(hours: [23: 50])
        days["2026-08-05"] = makeDay(hours: [23: 60])
        days["2026-08-06"] = makeDay(hours: [23: 70])
        let week = DayStrip.week(in: days, today: "2026-08-06")
        #expect(week.count == 7)
        #expect(week.filter { $0.total != nil }.count == 3)   // below the >=4 gate
        // And crossing the gate: add Monday and the count flips.
        days["2026-08-03"] = makeDay(hours: [23: 40])
        let week4 = DayStrip.week(in: days, today: "2026-08-06")
        #expect(week4.filter { $0.total != nil }.count == 4)  // at the >=4 gate
    }

    @Test("a Monday can never pass the gate on future days alone")
    func gateCannotBeMetByFutureDays() {
        // The regression the Monday-first window could have introduced: on a
        // Monday only ONE day of the week has happened, so a history full of
        // records for the days ahead must still leave the strip gated off.
        var days: [String: DayRecord] = [:]
        for key in mondayFirstWeek { days[key] = makeDay(hours: [23: 50]) }
        let week = DayStrip.week(in: days, today: "2026-08-03")
        #expect(week.filter { $0.total != nil }.count == 1)   // Monday alone
    }

    // MARK: - hover readout (v1.0.0 per-day hover)

    @Test("hover speaks that day's cost and nothing else")
    func hoverTextIsCostOnly() {
        #expect(DayStrip.hoverText(total: 42.18) == "$42.18")
        #expect(DayStrip.hoverText(total: 7) == "$7.00")       // always two decimals
        #expect(DayStrip.hoverText(total: 1234.5) == "$1234.50")
    }

    @Test("a no-data day hovers silently rather than claiming $0.00")
    func hoverTextIsNilForGaps() {
        // nil covers both a past gap and a future day. "$0.00" would be a
        // different claim — "you spent nothing" vs "we have no reading."
        #expect(DayStrip.hoverText(total: nil) == nil)
        // An OBSERVED zero is a real reading and does speak.
        #expect(DayStrip.hoverText(total: 0) == "$0.00")
    }

    // MARK: - intensity bucketing (v0.5.2 GitHub-style cells)

    @Test("a gap day is level 0 — the flat empty cell")
    func intensityGapIsZero() {
        #expect(DayStrip.intensity(total: nil, maxTotal: 160) == 0)
    }

    @Test("an observed but zero day floors at level 1 — data happened")
    func intensityZeroFloorsAtOne() {
        #expect(DayStrip.intensity(total: 0, maxTotal: 160) == 1)
    }

    @Test("the week's biggest day is always full strength")
    func intensityMaxIsFour() {
        #expect(DayStrip.intensity(total: 160, maxTotal: 160) == 4)
        // Weird contaminated data (total above the week's max) clamps, not crashes.
        #expect(DayStrip.intensity(total: 500, maxTotal: 160) == 4)
    }

    @Test("a tiny real day still reads as a filled cell, not a smudge")
    func intensityFloorKeepsSmallDaysVisible() {
        // $13 next to $160 = 0.081 — without the floor this is level 0 and
        // reads as "nothing happened," the same lie the bar floor guarded.
        #expect(DayStrip.intensity(total: 13, maxTotal: 160) == 1)
    }

    @Test("a quarter of the max is still the lowest step — the ramp is ceil-bucketed")
    func intensityQuarterBoundary() {
        // 0.25 * 4 = 1.0 exactly → ceil stays 1; just above tips to 2.
        #expect(DayStrip.intensity(total: 25, maxTotal: 100) == 1)
        #expect(DayStrip.intensity(total: 26, maxTotal: 100) == 2)
    }

    @Test("mid-range days spread across the middle steps")
    func intensityMiddleSteps() {
        #expect(DayStrip.intensity(total: 30, maxTotal: 100) == 2)  // 0.30 → ceil(1.2)
        #expect(DayStrip.intensity(total: 60, maxTotal: 100) == 3)  // 0.60 → ceil(2.4)
        #expect(DayStrip.intensity(total: 99, maxTotal: 100) == 4)  // near-max reads full
    }

    @Test("a degenerate maxTotal never crashes or divides by zero")
    func intensityDegenerateMax() {
        #expect(DayStrip.intensity(total: 0, maxTotal: 0) == 1)   // observed zero, no max
        #expect(DayStrip.intensity(total: nil, maxTotal: 0) == 0) // gap with no max
    }
}
