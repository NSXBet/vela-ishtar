// Sources/VelaCore/HistoryStore.swift
// Persists per-UTC-day hourly spend history to a JSON file on disk, keyed
// so the sparkline can show "today so far" and past days can be revisited.
// Why: the API only reports live totals, not history; without this the
// popover would lose all spend shape every time the app relaunches.
// RELEVANT FILES: Tests/VelaCoreTests/HistoryStoreTests.swift, BurnBuffer.swift, PaceEngine.swift

import Foundation

/// One UTC day's worth of spend. `hourly[h]` is the cumulative "spent
/// today" figure as of UTC hour `h`, or nil if that hour hasn't happened
/// (or wasn't observed) yet.
public struct DayRecord: Codable, Equatable, Sendable {
    public var hourly: [Double?]
    public var limit: Double
    public var exhaustedAt: Date?

    public init(hourly: [Double?], limit: Double, exhaustedAt: Date?) {
        self.hourly = hourly
        self.limit = limit
        self.exhaustedAt = exhaustedAt
    }
}

/// On-disk store of DayRecords, keyed by UTC calendar day ("yyyy-MM-dd").
public struct HistoryStore: Sendable {
    private let directory: URL
    private var days: [String: DayRecord] = [:]

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static var dayKeyFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private var fileURL: URL {
        directory.appendingPathComponent("history.json")
    }

    /// `directory` is injectable so tests can point this at a throwaway
    /// temp subdirectory instead of the app's real support directory.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Records a new cumulative "spent today" reading into the UTC hour
    /// slot for `date`, creating that day's record if it doesn't exist yet.
    public mutating func record(spentToday: Double, limit: Double, at date: Date) {
        let key = Self.dayKeyFormatter.string(from: date)
        let hour = Self.utcCalendar.component(.hour, from: date)

        var day = days[key] ?? DayRecord(hourly: Array(repeating: nil, count: 24), limit: limit, exhaustedAt: nil)
        day.limit = limit
        day.hourly[hour] = spentToday
        days[key] = day
    }

    /// Looks up the record for the UTC day containing `utcDate`.
    public func day(utcDate: Date) -> DayRecord? {
        let key = Self.dayKeyFormatter.string(from: utcDate)
        return days[key]
    }

    /// Loads history.json from `directory`. A missing file simply means
    /// no history has been saved yet -- that's the normal first-run state,
    /// not an error, so `days` is left empty rather than throwing.
    public mutating func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            days = [:]
            return
        }
        let data = try Data(contentsOf: fileURL)
        days = try JSONDecoder().decode([String: DayRecord].self, from: data)
    }

    /// Saves the current history to history.json, creating `directory` if
    /// needed. Writes to a temp file first and renames it into place so a
    /// crash or power loss mid-write can never leave a half-written file.
    public func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(days)

        let tempURL = directory.appendingPathComponent("history.json.tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    }
}
