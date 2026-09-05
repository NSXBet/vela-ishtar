// Sources/VelaCore/HistoryStore.swift
// Persists per-UTC-day hourly spend history to a JSON file on disk, keyed
// so the sparkline can show "today so far" and past days can be revisited.
// Why: the API only reports live totals, not history; without this the
// popover would lose all spend shape every time the app relaunches.
// RELEVANT FILES: Tests/VelaCoreTests/HistoryStoreTests.swift, BurnBuffer.swift, PaceEngine.swift

import Foundation
import OSLog

private let historyLog = Logger(subsystem: "com.nsxbet.velaishtar", category: "HistoryStore")

/// One UTC day's worth of spend. `hourly[h]` is the cumulative "spent
/// today" figure as of UTC hour `h`, or nil if that hour hasn't happened
/// (or wasn't observed) yet.
public struct DayRecord: Codable, Equatable, Sendable {
    /// A reading received after local midnight that still belongs to this
    /// GATEWAY day (B01). The hourly array is indexed by the local-UTC hour
    /// of receipt, so a 00:30 reading for yesterday's spend_date has no
    /// honest slot — writing it into hour 0 both destroys that slot and
    /// makes the receipt-order series non-monotonic, which load() then
    /// deletes as contaminated (the §12.1 data-loss sequence). Late readings
    /// keep their true receipt instant instead.
    public struct LateReading: Codable, Equatable, Sendable {
        public var at: Date
        public var amount: Double

        public init(at: Date, amount: Double) {
            self.at = at
            self.amount = amount
        }
    }

    public var hourly: [Double?]
    public var limit: Double
    public var exhaustedAt: Date?
    /// Receipt-ordered readings for this gateway day that arrived on a LATER
    /// local-UTC calendar day. Optional so legacy schema-1 files (which have
    /// no such key) still decode via synthesized Codable.
    public var lateReadings: [LateReading]?

    public init(hourly: [Double?], limit: Double, exhaustedAt: Date?, lateReadings: [LateReading]? = nil) {
        self.hourly = hourly
        self.limit = limit
        self.exhaustedAt = exhaustedAt
        self.lateReadings = lateReadings
    }

    /// The most recently observed cumulative amount for the day: the last
    /// late reading when present, else the highest hour slot with a value.
    public var lastObservedAmount: Double? {
        if let late = lateReadings?.last { return late.amount }
        return hourly.last { $0 != nil } ?? nil
    }
}

/// On-disk store of DayRecords, keyed by UTC calendar day ("yyyy-MM-dd").
public struct HistoryStore: Sendable {
    private let directory: URL
    private var days: [String: DayRecord] = [:]

    /// Read-only view of the loaded days (post-contamination-filter), keyed
    /// by gateway spend_date. Exposed for PaceEngine's median-day benchmark.
    public var allDays: [String: DayRecord] { days }

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

    /// Records a new cumulative "spent today" reading, keyed by the
    /// GATEWAY's day (`spendDate`, the `daily_budget.spend_date` field),
    /// not the local clock's UTC date. Why: the gateway buckets spend by
    /// its own day boundary, which lags the local clock — a poll at
    /// 00:30 UTC can still carry yesterday's spend_date. Keying by the
    /// local date filed yesterday's total under today, and the cumulative
    /// curve visibly DECREASED within a day (real history.json showed
    /// hour 0–2 holding the previous day's total). The hour slot stays
    /// local-UTC so the curve's x-axis remains "hours of my day."
    ///
    /// Also persists the FIRST instant spend reaches or exceeds the limit
    /// that day (`exhaustedAt`), so PaceEngine can report a true, stable
    /// exhaustion time instead of re-stamping "now" on every poll after the
    /// budget is already blown.
    public mutating func record(spentToday: Double, limit: Double, limitEnabled: Bool = true, at date: Date, spendDate: String) {
        let hour = Self.utcCalendar.component(.hour, from: date)
        // Normalize the gateway's spend_date to the canonical bare day key —
        // the API has emitted both "2026-08-06" and "2026-08-07T00:00:00Z"
        // for the same logical day, and keying by the raw string would split
        // one day across two records.
        let key = ISODate.dayKey(spendDate)

        var day = days[key] ?? DayRecord(hourly: Array(repeating: nil, count: 24), limit: limit, exhaustedAt: nil)
        day.limit = limit
        // B01: a reading received on a LATER local-UTC calendar day than the
        // gateway's spend_date continues that gateway day — the gateway's day
        // boundary lags the local clock. It must NEVER go into hour 0: the
        // hourly slot index is the local hour of receipt, and hour 0 of the
        // labeled day is 24h EARLIER in receipt order. Keep it as a
        // late reading with its true receipt instant; the running-max guard
        // still rejects downward seam resets (audit #4).
        if Self.dayKeyFormatter.string(from: date) != key {
            let runningMax = max(day.hourly.compactMap { $0 }.max() ?? 0, day.lateReadings?.map(\.amount).max() ?? 0)
            if runningMax > 0, spentToday < runningMax - max(runningMax * 0.01, 0.50) {
                historyLog.notice("ignored downward seam restatement for \(key, privacy: .public): peak \(runningMax, privacy: .public) -> \(spentToday, privacy: .public)")
            } else {
                day.lateReadings = (day.lateReadings ?? []) + [DayRecord.LateReading(at: date, amount: spentToday)]
                if day.exhaustedAt == nil, limitEnabled, spentToday >= limit {
                    day.exhaustedAt = date
                }
            }
            days[key] = day
            pruneToRetentionWindow()
            return
        }
        // Monotonic guard: a cumulative "spent today" reading never goes
        // DOWN within a gateway day, so never accept a value that drops
        // below the day's running max by more than the restatement
        // tolerance. Comparing against the running max (not just this slot's
        // previous value) closes the cross-hour case: a decrease into an
        // EMPTY later slot — hour 14 → 15, or hour 23 → 0 across the gateway
        // seam — would otherwise write through unguarded and leave a visible
        // right-to-left zigzag in the day's curve (and, via allDays, poison
        // the median until the next launch's contamination filter).
        //
        // Two ways a downward reading can legitimately appear: (1) the
        // gateway restates an hour downward by a few cents on the next poll,
        // and (2) the gateway's day boundary LEADS the local clock, so a
        // 00:30 poll writes a small value into hour 0 of a day that already
        // holds a large hour-23 reading. Tolerance mirrors isContaminated's
        // (max 1% of the running max, or $0.50) so an honest tiny
        // restatement doesn't wedge the slot at a stale high. Late readings
        // count toward the peak so a post-midnight continuation is the real
        // running max, not the last slotted hour.
        let hourlyMax = day.hourly.compactMap { $0 }.max() ?? 0
        let lateMax = day.lateReadings?.map(\.amount).max() ?? 0
        let runningMax = max(hourlyMax, lateMax)
        if runningMax > 0 {
            let peak = runningMax
            let tolerance = max(peak * 0.01, 0.50)
            if spentToday < peak - tolerance {
                historyLog.notice("ignored downward restatement for \(key, privacy: .public) hour \(hour, privacy: .public): peak \(peak, privacy: .public) -> \(spentToday, privacy: .public)")
            } else {
                day.hourly[hour] = spentToday
            }
        } else {
            day.hourly[hour] = spentToday
        }
        // Only stamp exhaustion when a daily limit is actually in force.
        // `limitEnabled` is the gateway's own "limit on/off" flag — gating on
        // it (not on `limit > 0`) covers both no-limit shapes: a disabled
        // limit whose configured value is still nonzero, and a zero limit.
        // Without the guard, `spentToday >= limit` (0 >= 0) stamped exhaustion
        // on the very first poll for a no-limit account.
        if day.exhaustedAt == nil, limitEnabled, spentToday >= limit {
            day.exhaustedAt = date
        }
        days[key] = day
        pruneToRetentionWindow()
    }

    /// The number of gateway days kept on disk. Set well above the 14-day
    /// read window PaceEngine uses, so the file stays bounded without ever
    /// dropping data a future longer-window feature (30-day strip,
    /// month-over-month) would want. ~90 days is a few tens of KB of JSON.
    private static let retentionDays = 90

    /// Drops all but the newest `retentionDays` gateway days. Day keys are
    /// canonical "yyyy-MM-dd", so lexicographic order IS chronological order
    /// and "newest" is a plain string sort. Called on every record() so each
    /// save stays bounded.
    private mutating func pruneToRetentionWindow() {
        guard days.count > Self.retentionDays else { return }
        let keep = Set(days.keys.sorted().suffix(Self.retentionDays))
        let dropped = days.keys.filter { !keep.contains($0) }
        days = days.filter { keep.contains($0.key) }
        if !dropped.isEmpty {
            historyLog.notice("pruned \(dropped.count, privacy: .public) day(s) beyond the \(Self.retentionDays, privacy: .public)-day retention window")
        }
    }

    /// Looks up the record for the UTC day containing `utcDate`.
    public func day(utcDate: Date) -> DayRecord? {
        let key = Self.dayKeyFormatter.string(from: utcDate)
        return days[key]
    }

    /// Looks up the record by the GATEWAY's day key (`spend_date`
    /// verbatim). The write path keys by this, so reads that need the
    /// authoritative "today" (exhaustion state, the popover's curve) use
    /// this lookup — the local UTC date and the gateway's day disagree
    /// around the midnight-UTC seam.
    public func day(spendDate: String) -> DayRecord? {
        days[ISODate.dayKey(spendDate)]
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

        // Migrate pre-normalization keys: any full-ISO day key
        // ("2026-08-07T00:00:00Z") is re-keyed to its bare day form, merging
        // into an existing bare-keyed record for the same logical day. Merge
        // takes the max per hour slot (cumulative spend is non-decreasing
        // within a day, so the max is the truthful reading) and the earliest
        // non-nil exhaustedAt.
        var migrated = false
        for key in decoded.keys {
            let bare = ISODate.dayKey(key)
            guard bare != key, let isoRecord = decoded[key] else { continue }
            decoded.removeValue(forKey: key)
            if var existing = decoded[bare] {
                for hour in 0..<min(existing.hourly.count, isoRecord.hourly.count) {
                    switch (existing.hourly[hour], isoRecord.hourly[hour]) {
                    case let (a?, b?): existing.hourly[hour] = max(a, b)
                    case (nil, let b?): existing.hourly[hour] = b
                    default: break  // keep existing (a?, nil) or (nil, nil)
                    }
                }
                existing.limit = max(existing.limit, isoRecord.limit)
                if existing.exhaustedAt == nil { existing.exhaustedAt = isoRecord.exhaustedAt }
                if let isoLate = isoRecord.lateReadings {
                    // Merge late readings by receipt time, deduping exact
                    // (instant, amount) pairs.
                    var merged = existing.lateReadings ?? []
                    for reading in isoLate where !merged.contains(reading) {
                        merged.append(reading)
                    }
                    existing.lateReadings = merged.sorted { $0.at < $1.at }
                }
                decoded[bare] = existing
            } else {
                decoded[bare] = isoRecord
            }
            migrated = true
            historyLog.notice("migrated history day key \(key, privacy: .public) -> \(bare, privacy: .public)")
        }

        // Defend against a hand-edited or corrupted history.json where a
        // day's hourly array isn't exactly 24 slots -- record() indexes it
        // by UTC hour (0...23) and would crash on an out-of-bounds write.
        // Reset any offending day back to a fresh 24-nil array rather than
        // failing the whole load.
        for key in decoded.keys where decoded[key]!.hourly.count != 24 {
            decoded[key]!.hourly = Array(repeating: nil, count: 24)
        }

        // Drop days written by the pre-0.1.2 local-clock day-keying bug:
        // their early UTC hours hold the PREVIOUS day's total, so spend
        // appears to decrease mid-day. A cumulative-within-a-gateway-day
        // series is non-decreasing by construction, so a drop larger than
        // the restatement tolerance marks the day as contaminated. Those
        // days are wrong data, not missing data -- keeping them would
        // poison every day-over-day comparison (median line, ghost curve).
        let contaminated = decoded.keys.filter { Self.isContaminated(decoded[$0]!) }
        for key in contaminated {
            decoded.removeValue(forKey: key)
            historyLog.notice("dropped contaminated day \(key, privacy: .public) (spend decreases within the gateway day)")
        }

        days = decoded

        // Persist the cleaned/migrated history so the dropped days and the
        // re-keyed ISO days are gone for good — otherwise every launch
        // re-reads the same file, re-drops/re-migrates, and re-fires the log
        // lines above. Best-effort: a failed save just means we redo it next
        // launch.
        if !contaminated.isEmpty || migrated {
            try? save()
        }
    }

    /// True when a day's observed hourly readings decrease by more than the
    /// gateway-restatement tolerance. Tolerance is the larger of 1% of the
    /// day's peak or $0.50, so honest small restatements (the gateway
    /// recomputing a reading downward by a few cents) don't drop a good day.
    static func isContaminated(_ day: DayRecord) -> Bool {
        let observed = day.hourly.compactMap { $0 }
        guard observed.count > 1 else { return false }
        let peak = observed.max() ?? 0
        let tolerance = max(peak * 0.01, 0.50)
        var previous = -Double.infinity
        for value in observed {
            if value < previous - tolerance { return true }
            previous = max(previous, value)
        }
        return false
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
