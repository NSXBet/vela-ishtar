// Sources/VelaCore/DayStrip.swift
// Extracts the current Monday–Sunday calendar week with each day's total, for
// the popover's cell strip above the footer.
// Why: the strip is a comparison surface, so its window math (a true calendar
// week, not a rolling 7 days), total rule (final observed slot, not the max),
// cell-intensity bucketing, and hover readout live here where they're
// unit-testable — the App layer just draws cells and shows the card.
// RELEVANT FILES: Tests/VelaCoreTests/DayStripTests.swift, Sources/VelaCore/HistoryStore.swift, Sources/App/DayStripView.swift

import Foundation

public enum DayStrip {
    /// One day in the strip. `total` is nil when the day has no observed
    /// readings at all (a gap — the App layer draws an empty slot, not a
    /// zero bar).
    public struct Day: Equatable, Sendable {
        public let key: String          // gateway spend_date, "yyyy-MM-dd"
        public let total: Double?
        public let isToday: Bool
        public let exhausted: Bool      // hit budget that day

        public init(key: String, total: Double?, isToday: Bool, exhausted: Bool) {
            self.key = key
            self.total = total
            self.isToday = isToday
            self.exhausted = exhausted
        }
    }

    /// The CURRENT Monday–Sunday calendar week containing `today` (the
    /// gateway's current spend_date), Monday first. Always 7 entries, so the
    /// strip's x-positions are the days of the week themselves — index 0 is
    /// always Monday, index 6 always Sunday, and today lands wherever in the
    /// row it actually falls (the GitHub grammar). Days with no record appear
    /// with a nil total.
    ///
    /// v1.0.0 replaced the rolling 7-day window (which ended at today and so
    /// re-labelled every column each morning) with this fixed week. The row is
    /// now a stable frame the eye can learn: the same seven slots all week,
    /// with the "now" edge advancing through them.
    ///
    /// Days AFTER today in this week are the future. Their total is forced nil
    /// — a gap, identical to a no-data day — even if history somehow holds a
    /// record for them (clock skew, or a spend_date running ahead of the local
    /// clock). A day that hasn't happened must never contribute to the week's
    /// max, or every cell would be bucketed against a phantom.
    ///
    /// The window is calendar math on parsed dates, NOT key-string arithmetic:
    /// subtracting 6 from "2026-08-01" is not a valid key, but "2026-07-27" is
    /// the right Monday. Keys are regenerated through the same UTC formatter
    /// HistoryStore writes with, so lookups always match.
    public static func week(in days: [String: DayRecord], today: String) -> [Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"

        // Parse `today` tolerantly: the gateway's spend_date arrives as a
        // bare date ("2026-08-10") on some days and a full timestamp
        // ("2026-08-10T00:00:00Z") on others. The window keys below are
        // always regenerated bare via `formatter`, so once history keys are
        // normalized (HistoryStore), the lookups match.
        guard let todayDate = ISODate.parse(today) else { return [] }

        // Today's offset from this week's Monday. Explicit arithmetic on the
        // Gregorian weekday (1 = Sunday … 7 = Saturday) rather than
        // firstWeekday/dateInterval: Monday-first is a fixed design decision
        // here, not a locale preference, so it must not depend on how the
        // calendar happens to be configured.
        let weekday = calendar.component(.weekday, from: todayDate)
        let offsetFromMonday = (weekday + 5) % 7   // Mon → 0, Sun → 6

        return (0..<7).map { index in
            let date = calendar.date(byAdding: .day, value: index - offsetFromMonday, to: todayDate)!
            let key = formatter.string(from: date)
            let isToday = index == offsetFromMonday
            let isFuture = index > offsetFromMonday
            let record = isFuture ? nil : days[key]
            return Day(
                key: key,
                total: record.flatMap(dayTotal),
                isToday: isToday,
                exhausted: record?.exhaustedAt != nil
            )
        }
    }

    /// The hover readout for one strip cell: that day's cost, and nothing else
    /// ("$42.18"). nil for a day with no data — a gap and a future day both
    /// answer with silence rather than a "$0.00" that would read as "you spent
    /// nothing," which is a different claim from "we have no reading."
    public static func hoverText(total: Double?) -> String? {
        guard let total else { return nil }
        return String(format: "$%.2f", total)
    }

    /// A day's total is its FINAL observed hourly reading, not the max: the
    /// last slot is the closest thing to "how much did that day cost" the
    /// history holds. (record()'s monotonic guard keeps the series clean, so
    /// final == max on healthy days anyway; on a weird day we trust the last
    /// observation the gateway gave us.)
    private static func dayTotal(_ day: DayRecord) -> Double? {
        day.hourly.last(where: { $0 != nil }) ?? nil
    }

    /// Maps a day's total onto the 0...4 cell-intensity scale the GitHub-style
    /// strip renders (v0.5.2). Nil (a gap) is always 0 — the flat empty cell.
    /// Any OBSERVED day floors at 1, so a real but tiny day ($13 next to
    /// $160) still reads as "something happened," never as an empty slot —
    /// the same anti-lie rule the bar floor carried. The week's biggest day
    /// is always 4; everyone else is ceil-bucketed between. Degenerate
    /// maxTotal (≤ 0, impossible on a healthy render but cheap to guard)
    /// collapses every observed day to the floor instead of dividing by zero.
    public static func intensity(total: Double?, maxTotal: Double) -> Int {
        guard let total else { return 0 }
        guard maxTotal > 0, total > 0 else { return 1 }
        return min(4, max(1, Int((total / maxTotal * 4).rounded(.up))))
    }
}
