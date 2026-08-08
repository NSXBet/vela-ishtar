// Tests/VelaCoreTests/PaceEngineTests.swift
// Verifies every PaceEngine.verdict() branch (in the documented rule order)
// and the exact PaceEngine.sentence() strings, including the UTC-midnight
// ETA clamp.
// Why: this is the copy the user sees in the menu bar every poll; a wrong
// branch or a mis-clamped ETA reads as a confident lie about their budget.
// RELEVANT FILES: Sources/VelaCore/PaceEngine.swift, Sources/VelaCore/Models.swift

import Testing
import Foundation
@testable import VelaCore

struct PaceEngineTests {
    // MARK: - verdict() rule order

    @Test("limitEnabled false always wins, even if spend already exceeds limit")
    func cruisingNoLimitBeatsExhausted() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let verdict = PaceEngine.verdict(spent: 500, limit: 100, limitEnabled: false, now: now)
        #expect(verdict == .cruisingNoLimit)
    }

    @Test("spend at or above limit is exhausted, defaulting reachedAt to now when no exhaustedAt is passed")
    func exhaustedAtLimit() {
        let now = ISODate.parse("2026-08-01T18:40:00Z")!
        #expect(PaceEngine.verdict(spent: 100, limit: 100, limitEnabled: true, now: now) == .exhausted(reachedAt: now))
        #expect(PaceEngine.verdict(spent: 150, limit: 100, limitEnabled: true, now: now) == .exhausted(reachedAt: now))
    }

    @Test("exhausted uses the passed exhaustedAt instead of now, so the reported time is the true first crossing")
    func exhaustedUsesPassedExhaustedAt() {
        let firstCrossing = ISODate.parse("2026-08-01T09:15:00Z")!
        let now = ISODate.parse("2026-08-01T18:40:00Z")!
        let verdict = PaceEngine.verdict(spent: 150, limit: 100, limitEnabled: true, now: now, exhaustedAt: firstCrossing)
        #expect(verdict == .exhausted(reachedAt: firstCrossing))
    }

    @Test("zero or negative spend is idle")
    func idleWhenNoSpend() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        #expect(PaceEngine.verdict(spent: 0, limit: 100, limitEnabled: true, now: now) == .idle)
    }

    @Test("less than 60 seconds since midnight UTC with real spend is a generic pace, not a false idle")
    func paceGenericWhenTooEarlyInTheDayWithSpend() {
        let now = ISODate.parse("2026-08-01T00:00:30Z")!
        let verdict = PaceEngine.verdict(spent: 5, limit: 100, limitEnabled: true, now: now)
        let nextMidnightUTC = ISODate.parse("2026-08-02T00:00:00Z")!
        #expect(verdict == .pace(eta: nextMidnightUTC))
        // Since the eta is exactly next midnight (not before it), sentence()
        // must render the honest generic line, not a fabricated projection.
        #expect(PaceEngine.sentence(for: verdict, now: now) == "On pace to stay under budget today.")
    }

    @Test("pace is projected from the burn rate since midnight UTC")
    func paceProjectsETA() {
        // now = noon UTC -> 43200s elapsed since midnight UTC.
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        // rate = 100 / 43200s. remaining = 50. secondsToLimit = 50 / rate = 21600s (6h).
        let verdict = PaceEngine.verdict(spent: 100, limit: 150, limitEnabled: true, now: now)
        guard case .pace(let eta) = verdict else {
            Issue.record("expected .pace, got \(verdict)")
            return
        }
        let expectedETA = now.addingTimeInterval(21600)
        #expect(abs(eta.timeIntervalSince(expectedETA)) < 0.001)
    }

    @Test("pace still returns an eta even when it lands past midnight UTC")
    func paceETACanCrossMidnight() {
        // now = noon UTC; a very slow burn rate pushes the projected ETA
        // days into the future, well past the next UTC midnight.
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let verdict = PaceEngine.verdict(spent: 1, limit: 1000, limitEnabled: true, now: now)
        guard case .pace(let eta) = verdict else {
            Issue.record("expected .pace, got \(verdict)")
            return
        }
        let nextMidnightUTC = ISODate.parse("2026-08-02T00:00:00Z")!
        #expect(eta > nextMidnightUTC)
    }

    // MARK: - sentence() exact strings

    @Test("idle sentence")
    func idleSentence() {
        #expect(PaceEngine.sentence(for: .idle) == "No spend yet today.")
    }

    @Test("cruising with no limit sentence")
    func cruisingSentence() {
        #expect(PaceEngine.sentence(for: .cruisingNoLimit) == "No daily limit on your account.")
    }

    @Test("exhausted sentence includes the local reached-at time")
    func exhaustedSentence() throws {
        let reachedAt = ISODate.parse("2026-08-01T18:40:00Z")!
        let sentence = PaceEngine.sentence(for: .exhausted(reachedAt: reachedAt))
        #expect(sentence.hasPrefix("Reached at "))
        #expect(sentence.hasSuffix(" · resets at midnight"))
        #expect(try sentence.contains(Regex(#"\b\d{1,2}:\d{2} [ap]m\b"#)))
    }

    @Test("pace sentence before next midnight UTC gives the projected time")
    func paceSentenceBeforeMidnight() throws {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let eta = now.addingTimeInterval(21600) // 6h later, still same UTC day.
        let sentence = PaceEngine.sentence(for: .pace(eta: eta), now: now)
        // Terse form (v0.5.2): "At this pace you'll reach budget around …"
        // clipped its tail in the fixed 18pt, 284pt-wide pace row.
        #expect(sentence.hasPrefix("Budget reached around "))
        #expect(sentence.hasSuffix("."))
        #expect(try sentence.contains(Regex(#"\b\d{1,2}:\d{2} [ap]m\b"#)))
    }

    @Test("every pace-row sentence fits the popover's single-line slot")
    func paceSentencesFitTheSlot() {
        // Regression (v0.5.2): the pace row is a fixed 18pt single-line slot
        // 284pt wide at 13pt (v0.4.3's equal-height guarantee forbids growing
        // it). ~46 chars ≈ 280pt at that size — anything longer clips.
        // Measured from the worst live report: "At this pace you'll reach
        // budget around 3:38 am." (47 chars) clipped; 44 fits with margin.
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let eta = now.addingTimeInterval(21600)
        let sentences = [
            PaceEngine.sentence(for: .idle, now: now),
            PaceEngine.sentence(for: .cruisingNoLimit, now: now),
            PaceEngine.sentence(for: .exhausted(reachedAt: now), now: now),
            PaceEngine.sentence(for: .pace(eta: eta), now: now),
            PaceEngine.sentence(for: .pace(eta: eta), now: now, typical: (median: 1234, spent: 5678)),
        ]
        for sentence in sentences {
            #expect(sentence.count <= 45, "'\(sentence)' is \(sentence.count) chars — over the ~45-char budget of the 284pt pace slot")
        }
    }

    @Test("pace sentence clamps to a generic message once the eta crosses midnight UTC")
    func paceSentenceClampsAfterMidnight() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let eta = ISODate.parse("2026-08-03T00:00:00Z")! // days past next midnight UTC.
        #expect(PaceEngine.sentence(for: .pace(eta: eta), now: now) == "On pace to stay under budget today.")
    }

    // MARK: - medianSpend (v0.2.0)

    /// Builds a DayRecord with a single hourly reading at the given hour.
    private func makeDay(hour: Int, value: Double) -> DayRecord {
        var hourly: [Double?] = Array(repeating: nil, count: 24)
        hourly[hour] = value
        return DayRecord(hourly: hourly, limit: 100, exhaustedAt: nil)
    }

    @Test("medianSpend returns nil below the 5-day gate")
    func medianSpendBelowGate() {
        let days: [String: DayRecord] = [
            "2026-08-01": makeDay(hour: 12, value: 10),
            "2026-08-02": makeDay(hour: 12, value: 20),
            "2026-08-03": makeDay(hour: 12, value: 30),
            "2026-08-04": makeDay(hour: 12, value: 40),
        ]
        #expect(PaceEngine.medianSpend(atHourUTC: 12, in: days, excluding: "2026-08-05") == nil)
    }

    @Test("medianSpend returns the median at exactly 5 days")
    func medianSpendAtGate() {
        let days: [String: DayRecord] = [
            "2026-08-01": makeDay(hour: 12, value: 50),
            "2026-08-02": makeDay(hour: 12, value: 20),
            "2026-08-03": makeDay(hour: 12, value: 10),
            "2026-08-04": makeDay(hour: 12, value: 40),
            "2026-08-05": makeDay(hour: 12, value: 30),
        ]
        #expect(PaceEngine.medianSpend(atHourUTC: 12, in: days, excluding: "2026-08-06") == 30)
    }

    @Test("medianSpend averages the two middle values for an even count")
    func medianSpendEvenCount() {
        let days: [String: DayRecord] = [
            "2026-08-01": makeDay(hour: 12, value: 10),
            "2026-08-02": makeDay(hour: 12, value: 20),
            "2026-08-03": makeDay(hour: 12, value: 30),
            "2026-08-04": makeDay(hour: 12, value: 40),
            "2026-08-05": makeDay(hour: 12, value: 50),
            "2026-08-06": makeDay(hour: 12, value: 60),
        ]
        #expect(PaceEngine.medianSpend(atHourUTC: 12, in: days, excluding: "2026-08-07") == 35)
    }

    @Test("medianSpend skips days with nil at the requested hour — they don't count toward the gate")
    func medianSpendSkipsNilHours() {
        var days: [String: DayRecord] = [
            "2026-08-01": makeDay(hour: 12, value: 10),
            "2026-08-02": makeDay(hour: 12, value: 20),
            "2026-08-03": makeDay(hour: 12, value: 30),
            "2026-08-04": makeDay(hour: 12, value: 40),
        ]
        // Two more days exist but have no reading at hour 12.
        days["2026-08-05"] = makeDay(hour: 9, value: 99)
        days["2026-08-06"] = makeDay(hour: 15, value: 99)
        // Only 4 eligible days → nil.
        #expect(PaceEngine.medianSpend(atHourUTC: 12, in: days, excluding: "2026-08-07") == nil)
    }

    @Test("medianSpend excludes today's gateway key — it never counts toward the gate or the median")
    func medianSpendExcludesToday() {
        var days: [String: DayRecord] = [
            "2026-08-01": makeDay(hour: 12, value: 10),
            "2026-08-02": makeDay(hour: 12, value: 20),
            "2026-08-03": makeDay(hour: 12, value: 30),
            "2026-08-04": makeDay(hour: 12, value: 40),
        ]
        // Today's in-progress day has a huge value — must be excluded.
        days["2026-08-05"] = makeDay(hour: 12, value: 999)
        // 4 past days → nil (today doesn't rescue the gate).
        #expect(PaceEngine.medianSpend(atHourUTC: 12, in: days, excluding: "2026-08-05") == nil)

        // With a 5th past day, the median comes from the past days only.
        days["2026-08-00"] = makeDay(hour: 12, value: 50)
        #expect(PaceEngine.medianSpend(atHourUTC: 12, in: days, excluding: "2026-08-05") == 30)
    }

    @Test("medianSpend with all-identical values returns that value")
    func medianSpendAllIdentical() {
        let days: [String: DayRecord] = [
            "2026-08-01": makeDay(hour: 12, value: 25),
            "2026-08-02": makeDay(hour: 12, value: 25),
            "2026-08-03": makeDay(hour: 12, value: 25),
            "2026-08-04": makeDay(hour: 12, value: 25),
            "2026-08-05": makeDay(hour: 12, value: 25),
        ]
        #expect(PaceEngine.medianSpend(atHourUTC: 12, in: days, excluding: "2026-08-06") == 25)
    }

    @Test("medianSpend with a custom minDays parameter")
    func medianSpendCustomMinDays() {
        let days: [String: DayRecord] = [
            "2026-08-01": makeDay(hour: 12, value: 10),
            "2026-08-02": makeDay(hour: 12, value: 20),
        ]
        #expect(PaceEngine.medianSpend(atHourUTC: 12, in: days, excluding: "2026-08-03", minDays: 2) == 15)
    }

    // MARK: - sentence with median benchmark (v0.2.0)

    @Test("pace past midnight with typical benchmark shows the comparison line")
    func paceSentenceWithTypical() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let eta = ISODate.parse("2026-08-03T00:00:00Z")! // past midnight
        let sentence = PaceEngine.sentence(for: .pace(eta: eta), now: now, typical: (median: 31.4, spent: 54.2))
        #expect(sentence == "Typical day: $31 — you're at $54.")
    }

    @Test("pace before midnight ignores the typical benchmark")
    func paceBeforeMidnightIgnoresTypical() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let eta = now.addingTimeInterval(21600) // 6h later, same UTC day
        let sentence = PaceEngine.sentence(for: .pace(eta: eta), now: now, typical: (median: 31.4, spent: 54.2))
        #expect(sentence.hasPrefix("Budget reached around "))
    }

    @Test("exhausted ignores the typical benchmark")
    func exhaustedIgnoresTypical() {
        let reachedAt = ISODate.parse("2026-08-01T18:40:00Z")!
        let sentence = PaceEngine.sentence(for: .exhausted(reachedAt: reachedAt), typical: (median: 31.4, spent: 54.2))
        #expect(sentence.hasPrefix("Reached at "))
    }

    @Test("idle ignores the typical benchmark")
    func idleIgnoresTypical() {
        #expect(PaceEngine.sentence(for: .idle, typical: (median: 31.4, spent: 54.2)) == "No spend yet today.")
    }

    @Test("cruisingNoLimit ignores the typical benchmark")
    func cruisingIgnoresTypical() {
        #expect(PaceEngine.sentence(for: .cruisingNoLimit, typical: (median: 31.4, spent: 54.2)) == "No daily limit on your account.")
    }

    @Test("pace with eta exactly at midnight takes the typical comparison branch (boundary condition)")
    func paceExactlyAtMidnightUsesTypical() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let midnight = ISODate.parse("2026-08-02T00:00:00Z")! // exactly the boundary
        let sentence = PaceEngine.sentence(for: .pace(eta: midnight), now: now, typical: (median: 31.4, spent: 54.2))
        #expect(sentence == "Typical day: $31 — you're at $54.")
    }

    @Test("medianSpend returns nil for an out-of-range hour instead of crashing")
    func medianSpendOutOfRangeHour() {
        let days: [String: DayRecord] = [
            "2026-08-01": makeDay(hour: 12, value: 10),
        ]
        #expect(PaceEngine.medianSpend(atHourUTC: -1, in: days, excluding: "x") == nil)
        #expect(PaceEngine.medianSpend(atHourUTC: 24, in: days, excluding: "x") == nil)
    }

    // MARK: - monthRunway (v0.2.1 — moved to PaceEngine for testability)

    @Test("monthRunway returns nil during the first 6 full days of the month")
    func monthRunwaySuppressedEarlyInMonth() {
        // 2026-08-03 12:00 UTC → ~2.5 days elapsed (< 6) → suppressed.
        let now = ISODate.parse("2026-08-03T12:00:00Z")!
        #expect(PaceEngine.monthRunway(monthSpent: 300, now: now) == nil)
    }

    @Test("monthRunway returns nil when there is no spend yet")
    func monthRunwayNilOnZeroSpend() {
        let now = ISODate.parse("2026-08-10T12:00:00Z")!
        #expect(PaceEngine.monthRunway(monthSpent: 0, now: now) == nil)
    }

    @Test("monthRunway uses fractional elapsed days — day 7 at 01:00 UTC divides by ~6.04, not 7")
    func monthRunwayUsesFractionalDays() {
        // 2026-08-07 01:00 UTC → 6 days + 1h = 6.0417 days elapsed. August
        // has 31 days. Integer-day math (÷7) gives 620 * 31/7 ≈ $2,746 —
        // a ~13% underestimate. Fractional math: 620 * 31/6.0417 ≈ $3,181.
        let now = ISODate.parse("2026-08-07T01:00:00Z")!
        #expect(PaceEngine.monthRunway(monthSpent: 620, now: now) == "On track for ~$3181 this month.")
    }

    @Test("monthRunway is correct for a 28-day February (non-leap year)")
    func monthRunwayFebruaryNonLeap() {
        // 2026-02-10 12:00 UTC → 9.5 days elapsed, 28 days in Feb 2026.
        // 95 * 28/9.5 = 280 exactly.
        let now = ISODate.parse("2026-02-10T12:00:00Z")!
        #expect(PaceEngine.monthRunway(monthSpent: 95, now: now) == "On track for ~$280 this month.")
    }

    @Test("monthRunway respects a custom minElapsedDays gate")
    func monthRunwayCustomGate() {
        // Same instant as the fractional-days test (6.04 days elapsed).
        let now = ISODate.parse("2026-08-07T01:00:00Z")!
        // Gate at 7 → 6.04 < 7 → suppressed.
        #expect(PaceEngine.monthRunway(monthSpent: 620, now: now, minElapsedDays: 7) == nil)
        // Gate at 5 → 6.04 ≥ 5 → shown.
        #expect(PaceEngine.monthRunway(monthSpent: 620, now: now, minElapsedDays: 5) != nil)
    }

    // MARK: - ghostCurve (v0.3.0)

    /// Builds a DayRecord with the same cumulative value at every hour
    /// 0...maxHour — a full observed day up to that hour.
    private func makeFullDay(valueAtHour: [Int: Double]) -> DayRecord {
        var hourly: [Double?] = Array(repeating: nil, count: 24)
        for (hour, value) in valueAtHour { hourly[hour] = value }
        return DayRecord(hourly: hourly, limit: 100, exhaustedAt: nil)
    }

    @Test("ghostCurve returns nil below the 5-day gate")
    func ghostCurveBelowGate() {
        var days: [String: DayRecord] = [:]
        for i in 1...4 {
            days["2026-08-0\(i)"] = makeFullDay(valueAtHour: [10: 100])
        }
        #expect(PaceEngine.ghostCurve(in: days, excluding: "2026-08-09") == nil)
    }

    @Test("ghostCurve is the per-hour-slot median across the most recent ≤14 days")
    func ghostCurveMedianPerSlot() {
        // 5 days, all with hour-10 values 10/20/30/40/50 → median 30.
        // Hour 11 values 100/200/300/400/500 → median 300.
        var days: [String: DayRecord] = [:]
        let values: [Double] = [10, 20, 30, 40, 50]
        for (i, v) in values.enumerated() {
            days["2026-08-0\(i + 1)"] = makeFullDay(valueAtHour: [10: v, 11: v * 10])
        }
        let ghost = PaceEngine.ghostCurve(in: days, excluding: "2026-08-09")
        #expect(ghost?[10] == 30)
        #expect(ghost?[11] == 300)
        // Hours with no readings stay nil (gaps stay gaps).
        #expect(ghost?[12] == nil)
    }

    @Test("ghostCurve ignores days older than the 14-day window")
    func ghostCurveRecencyWindow() {
        var days: [String: DayRecord] = [:]
        // 15 eligible days; the OLDEST has a wildly different value and
        // must be excluded by the recency window.
        for i in 1...15 {
            let key = String(format: "2026-08-%02d", i)
            days[key] = makeFullDay(valueAtHour: [10: i == 1 ? 9999 : 100])
        }
        let ghost = PaceEngine.ghostCurve(in: days, excluding: "2026-08-20")
        // Window keeps the 14 most recent (08-02 ... 08-15); all are 100.
        #expect(ghost?[10] == 100)
    }

    @Test("ghostCurve excludes today's key and skips slots with too few samples")
    func ghostCurveExcludesTodayAndSparseSlots() {
        var days: [String: DayRecord] = [:]
        for i in 1...5 {
            let key = String(format: "2026-08-0%d", i)
            // Hour 10 present in all 5 days; hour 11 present in only 4.
            var slots = [10: 100.0]
            if i < 5 { slots[11] = 200 }
            days[key] = makeFullDay(valueAtHour: slots)
        }
        // Today's key must never feed the ghost.
        days["2026-08-09"] = makeFullDay(valueAtHour: [10: 9999])
        let ghost = PaceEngine.ghostCurve(in: days, excluding: "2026-08-09")
        #expect(ghost?[10] == 100)
        // Hour 11 has only 4 samples < 5 → nil.
        #expect(ghost?[11] == nil)
    }
}
