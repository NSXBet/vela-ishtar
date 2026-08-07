// Sources/VelaCore/DayStrip.swift
// Extracts the last 7 gateway days (ending at today) with each day's total,
// for the popover's hairline strip under the curve.
// Why: the strip is a comparison surface, so its window math (calendar, not
// string) and total rule (final observed slot, not the max) live here where
// they're unit-testable — the App layer just draws bars.
// RELEVANT FILES: Tests/VelaCoreTests/DayStripTests.swift, Sources/VelaCore/HistoryStore.swift, Sources/App/PopoverView.swift

import Foundation

public enum DayStrip {
    /// One day in the strip. `total` is nil when the day has no observed
    /// readings at all (a gap — the App layer draws an empty slot, not a
    /// zero bar).
    public struct Day: Equatable, Sendable {
        public let key: String          // gateway spend_date, "yyyy-MM-dd"
        public let total: Double?
        public let isToday: Bool
        public let exhausted: Bool      // hit budget that day → scar tick

        public init(key: String, total: Double?, isToday: Bool, exhausted: Bool) {
            self.key = key
            self.total = total
            self.isToday = isToday
            self.exhausted = exhausted
        }
    }

    /// The 7-day window ending at `today` (the gateway's current spend_date),
    /// oldest first. Always 7 entries — days with no record appear with a
    /// nil total so the strip's x-positions stay stable day to day.
    ///
    /// The window is calendar math on parsed dates, NOT key-string
    /// arithmetic: subtracting 6 from "2026-08-01" is not a valid key, but
    /// "2026-07-26" is the right day. Keys are regenerated through the same
    /// UTC formatter HistoryStore writes with, so lookups always match.
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

        return (0..<7).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: todayDate)!
            let key = formatter.string(from: date)
            let record = days[key]
            return Day(
                key: key,
                total: record.flatMap(dayTotal),
                isToday: offset == 0,
                exhausted: record?.exhaustedAt != nil
            )
        }
    }

    /// A day's total is its FINAL observed hourly reading, not the max: the
    /// last slot is the closest thing to "how much did that day cost" the
    /// history holds. (record()'s monotonic guard keeps the series clean, so
    /// final == max on healthy days anyway; on a weird day we trust the last
    /// observation the gateway gave us.)
    private static func dayTotal(_ day: DayRecord) -> Double? {
        day.hourly.last(where: { $0 != nil }) ?? nil
    }
}
