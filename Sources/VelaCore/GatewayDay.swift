// Sources/VelaCore/GatewayDay.swift
// The canonical interpretation of the gateway's spend_date as a CALENDAR-DAY
// LABEL ("yyyy-MM-dd"), with the calendar math every derived view needs.
// Why: spend_date is the gateway's billing-day label, NOT an instant. Several
// sites used to ISODate.parse it and read UTC components, which shifts a
// non-UTC-midnight label onto the wrong day ("2026-08-07T00:00:00+03:00" is
// the gateway's Aug 7, not UTC's Aug 6) — mis-anchoring the week strip, the
// per-model baseline lookup, and the month key. GatewayDay is the single
// place that rule lives: normalize the label once, then do pure calendar math
// on it. It WRAPS ISODate.dayKey (the one source of truth for "label, not
// instant") rather than re-implementing that normalization.
// RELEVANT FILES: Sources/VelaCore/Models.swift, Sources/VelaCore/DayStrip.swift, Sources/VelaCore/ModelSnapshots.swift

import Foundation

/// A gateway calendar day. Value type, Sendable. NOT Codable against
/// spend_date strings — persist the `key: String`, never the type.
public struct GatewayDay: Equatable, Sendable {
    /// The canonical bare label, "yyyy-MM-dd".
    public let key: String

    /// Normalize any spend_date shape (bare date, Z-timestamp, or numeric
    /// offset) through ISODate.dayKey — the label survives, the instant does
    /// not. Returns nil only when the label is unusable even after the
    /// tolerant dayKey fallback (i.e. the string isn't a date at all).
    public init?(spendDate: String) {
        let key = ISODate.dayKey(spendDate)
        guard Self.isWellFormed(key) else { return nil }
        self.key = key
    }

    /// The day after `n` days subtracted, as a new GatewayDay.
    public func minusDays(_ n: Int) -> GatewayDay? {
        shift(by: -n)
    }

    /// The previous calendar day.
    public func previous() -> GatewayDay? {
        minusDays(1)
    }

    /// The Gregorian weekday in UTC, 1 = Sunday … 7 = Saturday (Foundation's
    /// convention). Callers doing Monday-first math convert with (x + 5) % 7.
    public func weekdayInUTC() -> Int? {
        guard let date = Self.midnightUTC(for: key) else { return nil }
        return Self.utcCalendar.component(.weekday, from: date)
    }

    /// The month label, "yyyy-MM" — the first 7 chars of the key. Reading the
    /// label, never re-parsing an instant, is what keeps a "+03:00" month-seam
    /// spend_date in its real month.
    public func monthKey() -> String {
        String(key.prefix(7))
    }

    // MARK: - internals

    /// Pure calendar math on the label: parse the key as a UTC midnight,
    /// shift whole days, re-emit the bare key. All through the same UTC
    /// formatter HistoryStore writes with, so keys always match.
    private func shift(by days: Int) -> GatewayDay? {
        guard let date = Self.midnightUTC(for: key),
              let shifted = Self.utcCalendar.date(byAdding: .day, value: days, to: date) else {
            return nil
        }
        let shiftedKey = Self.dayFormatter.string(from: shifted)
        return GatewayDay(uncheckedKey: shiftedKey)
    }

    /// Internal initializer that trusts an already-normalized key (used by
    /// shift, which produces a well-formed key by construction).
    private init(uncheckedKey: String) {
        self.key = uncheckedKey
    }

    private static func isWellFormed(_ key: String) -> Bool {
        midnightUTC(for: key) != nil
    }

    /// The UTC midnight Date for a bare "yyyy-MM-dd" key, or nil if the key
    /// isn't a real calendar day.
    private static func midnightUTC(for key: String) -> Date? {
        dayFormatter.date(from: key)
    }

    // Computed, not `static let`: DateFormatter/Calendar are not Sendable to
    // share across threads.
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
