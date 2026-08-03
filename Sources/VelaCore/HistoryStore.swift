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

    // Computed, not `static let`: Calendar and DateFormatter are not
    // thread-safe to share, so building a fresh instance per call is the
    // safe choice here rather than caching one behind a lock.
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // Same reasoning as `utcCalendar` above: DateFormatter is not
    // thread-safe, so this stays a computed var, not a cached singleton.
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
    ///
    /// Also persists the FIRST instant spend reaches or exceeds the limit
    /// that day (`exhaustedAt`), so PaceEngine can report a true, stable
    /// exhaustion time instead of re-stamping "now" on every poll after the
    /// budget is already blown.
    public mutating func record(spentToday: Double, limit: Double, at date: Date) {
        let key = Self.dayKeyFormatter.string(from: date)
        let hour = Self.utcCalendar.component(.hour, from: date)

        var day = days[key] ?? DayRecord(hourly: Array(repeating: nil, count: 24), limit: limit, exhaustedAt: nil)
        day.limit = limit
        day.hourly[hour] = spentToday
        if day.exhaustedAt == nil, spentToday >= limit {
            day.exhaustedAt = date
        }
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
        var decoded = try JSONDecoder().decode([String: DayRecord].self, from: data)

        // Defend against a hand-edited or corrupted history.json where a
        // day's hourly array isn't exactly 24 slots -- record() indexes it
        // by UTC hour (0...23) and would crash on an out-of-bounds write.
        // Reset any offending day back to a fresh 24-nil array rather than
        // failing the whole load.
        for key in decoded.keys where decoded[key]!.hourly.count != 24 {
            decoded[key]!.hourly = Array(repeating: nil, count: 24)
        }
        days = decoded
    }

    /// Saves the current history to history.json, creating `directory` if
    /// needed. Writes to a temp file first and renames it into place so a
    /// crash or power loss mid-write can never leave a half-written file.
    public func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(days)

        let tempURL = directory.appendingPathComponent("history.json.tmp-\(UUID().uuidString)")
        try data.write(to: tempURL)
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            // Don't leave the orphaned temp file behind if the swap failed.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
