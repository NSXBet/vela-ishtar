// Sources/VelaCore/PaceEngine.swift
// Turns today's cumulative spend + limit into a verdict about how the day
// is going, and a human sentence describing that verdict.
// Why: the popover leads with one line of copy; centralizing the pace
// math and its wording here keeps that logic testable and out of the UI.
// RELEVANT FILES: Tests/VelaCoreTests/PaceEngineTests.swift, Sources/VelaCore/Models.swift, Sources/VelaCore/BurnBuffer.swift

import Foundation

/// The state of today's spend relative to the daily limit.
public enum PaceVerdict: Equatable, Sendable {
    /// No spend recorded yet today (or too early in the day to project).
    case idle
    /// Spend has reached or exceeded the limit, at this moment.
    case exhausted(reachedAt: Date)
    /// Still under the limit; projected to reach it at `eta` if the current
    /// burn rate holds. `eta` may land past the next UTC midnight — the
    /// caller decides how to word that, PaceEngine still reports it.
    case pace(eta: Date)
    /// The account has no daily limit configured.
    case cruisingNoLimit
}

public enum PaceEngine {
    // A projection needs at least a minute of burn history since midnight
    // UTC to be worth trusting; below that, a single early API call could
    // imply an absurd extrapolated rate.
    private static let minElapsedSecondsForProjection: TimeInterval = 60

    /// A calendar pinned to UTC, used only for the midnight-UTC boundary
    /// math (never for display formatting, which stays in the local zone).
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The next UTC midnight strictly after `date`. Shared by verdict()'s
    /// early-day fallback and sentence()'s eta-clamp so both agree on where
    /// "today" ends.
    private static func nextMidnightUTC(after date: Date) -> Date {
        utcCalendar.date(byAdding: .day, value: 1, to: utcCalendar.startOfDay(for: date))!
    }

    /// Decides today's pace verdict. Rule order matters: a disabled limit
    /// always wins (there's nothing to be exhausted against or pace toward).
    ///
    /// `exhaustedAt` is the persisted instant spend first crossed the limit
    /// today (from HistoryStore.DayRecord.exhaustedAt). The App layer should
    /// always pass it once known; it defaults to nil so `.exhausted(reachedAt:
    /// now)` is only a fallback for the very first poll that crosses the
    /// limit, before anything has been persisted yet.
    ///
    /// `isFresh` says whether `spent` came from a poll that just succeeded.
    /// When it's false the spend figure is hours old, so the rate projection
    /// is replaced by the honest generic-pace fallback — extrapolating stale
    /// spend against NOW's clock fabricates an ETA. The FACTUAL branches
    /// (exhausted, idle, cruisingNoLimit) still report from stale data: a
    /// crossed limit is a fact that happened, not a projection.
    public static func verdict(spent: Double, limit: Double, limitEnabled: Bool, now: Date, exhaustedAt: Date? = nil, isFresh: Bool = true) -> PaceVerdict {
        guard limitEnabled else { return .cruisingNoLimit }
        guard spent < limit else { return .exhausted(reachedAt: exhaustedAt ?? now) }
        guard spent > 0 else { return .idle }

        guard isFresh else {
            // A stale response's spend figure is hours old; projecting it
            // against NOW's clock fabricates an ETA. Same honest fallback as
            // the early-day branch below: an eta at next midnight makes
            // sentence() render "On pace to stay under budget today.".
            return .pace(eta: nextMidnightUTC(after: now))
        }

        let midnightUTC = utcCalendar.startOfDay(for: now)
        let elapsedSeconds = now.timeIntervalSince(midnightUTC)
        guard elapsedSeconds >= minElapsedSecondsForProjection else {
            // Money has already been spent today (spent > 0, checked above),
            // so .idle would be a lie -- it reads as "no spend yet today."
            // There just isn't enough burn history yet to trust a rate
            // projection, so report the honest generic pace instead: an eta
            // past midnight makes sentence() render "On pace to stay under
            // budget today." rather than a fabricated early-day claim.
            return .pace(eta: nextMidnightUTC(after: now))
        }

        let rate = spent / elapsedSeconds
        let secondsToLimit = (limit - spent) / rate
        let eta = now.addingTimeInterval(secondsToLimit)
        return .pace(eta: eta)
    }

    /// Whole minutes since the last successful poll, floored at 0 so clock
    /// skew (a `lastSuccessAt` stamped ahead of `now`) can never render a
    /// negative age like "Data is -3 min old". Sub-minute remainders
    /// truncate toward zero.
    public static func ageMinutes(now: Date, lastSuccessAt: Date) -> Int {
        max(0, Int(now.timeIntervalSince(lastSuccessAt) / 60))
    }

    /// The sentence shown under the verdict. `now` defaults to the real
    /// clock — in the running app sentence() is called right after
    /// verdict() with the same instant, so this stays accurate in
    /// production while letting tests pin a deterministic `now`.
    ///
    /// `typical` is an optional median-day benchmark (from `medianSpend`).
    /// When non-nil AND the verdict is the inert pace-past-midnight branch,
    /// the generic line is replaced by a comparison against the user's own
    /// history. Every other branch ignores `typical` — those lines already
    /// say something concrete.
    public static func sentence(for verdict: PaceVerdict, now: Date = Date(), typical: (median: Double, spent: Double)? = nil) -> String {
        switch verdict {
        case .idle:
            return "No spend yet today."
        case .cruisingNoLimit:
            return "No daily limit on your account."
        case .exhausted(let reachedAt):
            // "· resets at midnight" — every char is budget in the 284pt
            // pace slot; the UTC qualifier lives in the What's New note.
            return "Reached at \(localTime(reachedAt)) · resets at midnight"
        case .pace(let eta):
            // Shared with verdict()'s early-day fallback so both agree on
            // where "today" ends -- otherwise the two computations could
            // silently drift apart.
            let midnightBoundary = Self.nextMidnightUTC(after: now)
            if eta < midnightBoundary {
                // Short on purpose: the pace row is a fixed single-line 18pt
                // slot (v0.4.3's equal-height guarantee), and "At this pace
                // you'll reach budget around 3:38 am." clipped its tail in a
                // 284pt field. The terse form fits at every sane width.
                return "Budget reached around \(localTime(eta))."
            } else if let typical {
                // Median-day comparison (v0.2.0): replaces the inert
                // "On pace to stay under budget today." with a benchmark
                // from the user's own history. Whole-dollar formatting
                // matches the hero suffix style. "Typical day:" (not "…by
                // now:") — the longer form measures 291pt at 13pt and clips
                // the 284pt pace slot; every char is budget here.
                return String(format: "Typical day: $%.0f — you're at $%.0f.", typical.median, typical.spent)
            } else {
                return "On pace to stay under budget today."
            }
        }
    }

    /// Median cumulative spend at UTC hour `hour` across eligible past days.
    /// Returns nil when fewer than `minDays` eligible days have a reading at
    /// that hour — the caller must then fall back to the generic line.
    ///
    /// A day is eligible iff (1) it's present in the post-load `days` dict
    /// (contaminated days were already dropped by load()), (2) its key is
    /// NOT today's gateway spend_date (the in-progress day's mid-hour
    /// reading would bias the median), and (3) `hourly[hour] != nil`.
    ///
    /// `hour` outside 0..<24 returns nil rather than crashing on an
    /// out-of-range index — this is a public function and callers compute
    /// the hour from a live clock.
    ///
    /// Caveat: record() overwrites an occupied hour slot, so a past day's
    /// hourly[H] is the LAST reading observed within that hour (≈ end-of-hour
    /// cumulative), while today's spend is mid-hour. This slightly flatters
    /// the user early in each hour — a bounded, one-sided bias of at most
    /// one hour of burn. Not worth interpolating past days to mid-hour.
    public static func medianSpend(
        atHourUTC hour: Int,
        in days: [String: DayRecord],
        excluding todayKey: String,
        minDays: Int = 5,
        maxDays: Int = 14
    ) -> Double? {
        guard (0..<24).contains(hour) else { return nil }
        // Normalize the exclusion key: callers pass the gateway's raw
        // spend_date, which arrives in two shapes for the same logical day —
        // history keys are canonical, so a raw full-ISO key would fail to
        // exclude today and pollute the median with today's own reading.
        let excludeKey = ISODate.dayKey(todayKey)
        // The same ≤14-day recency window ghostCurve uses, so the sentence
        // and the ghost can never disagree about what "a typical day" is:
        // both track how the user spends NOW, not months-old behavior.
        let samples = days
            .filter { $0.key != excludeKey }
            .sorted { $0.key > $1.key }
            .prefix(maxDays)
            .compactMap { $0.value.hourly[hour] }
            .sorted()
        guard samples.count >= minDays else { return nil }
        return median(of: samples)
    }

    /// The ghost curve for v0.3.0: the per-hour-slot median across the
    /// `maxDays` most recent eligible past days, as a 24-slot array parallel
    /// to `DayRecord.hourly`. Returns nil when NO hour has enough samples
    /// (the caller then draws no ghost). Slots with fewer than `minDays`
    /// samples stay nil — gaps stay gaps, the ghost simply doesn't draw
    /// there.
    ///
    /// Eligibility mirrors `medianSpend` (post-load days only, today's key
    /// excluded). The recency window keeps the ghost tracking how the user
    /// spends NOW, not how they spent months ago — gateway spend_date keys
    /// sort lexicographically, so "most recent" is a plain string sort.
    public static func ghostCurve(
        in days: [String: DayRecord],
        excluding todayKey: String,
        minDays: Int = 5,
        maxDays: Int = 14
    ) -> [Double?]? {
        let excludeKey = ISODate.dayKey(todayKey)
        let eligible = days
            .filter { $0.key != excludeKey }
            .sorted { $0.key > $1.key }   // most recent first
            .prefix(maxDays)
            .map(\.value)
        guard !eligible.isEmpty else { return nil }

        var ghost: [Double?] = Array(repeating: nil, count: 24)
        var anySlot = false
        for hour in 0..<24 {
            let samples = eligible.compactMap { $0.hourly[hour] }.sorted()
            if samples.count >= minDays {
                ghost[hour] = median(of: samples)
                anySlot = true
            }
        }
        return anySlot ? ghost : nil
    }

    /// Median of an already-sorted, non-empty array. Even counts average the
    /// two middle values. Single shared implementation so medianSpend and
    /// ghostCurve can never drift apart.
    private static func median(of sorted: [Double]) -> Double {
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        } else {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
    }

    /// Linear month extrapolation: "On track for ~$X this month."
    /// Suppressed during the first `minElapsedDays` (default 6) full days of
    /// the month — projecting from 2 days of data produces a confidently
    /// wrong number, which is worse than no number. Also suppressed when
    /// there's no spend yet ($0.00). Returns nil when the line should not
    /// appear.
    ///
    /// Uses fractional elapsed days (not integer dayOfMonth) so the divisor
    /// accounts for today being only partially elapsed — dividing by the
    /// integer day on day 7 at 01:00 UTC would underestimate by ~13%.
    ///
    /// Lives in VelaCore (not the view layer) so the calendar math is
    /// unit-testable; the month boundary is UTC to match the gateway's
    /// billing day keying elsewhere.
    public static func monthRunway(monthSpent: Double, now: Date, minElapsedDays: Double = 6) -> String? {
        guard monthSpent > 0 else { return nil }
        let startOfMonth = utcCalendar.date(from: utcCalendar.dateComponents([.year, .month], from: now))!
        let elapsedDays = now.timeIntervalSince(startOfMonth) / 86400
        guard elapsedDays >= minElapsedDays else { return nil }
        let daysInMonth = utcCalendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let projected = monthSpent / elapsedDays * Double(daysInMonth)
        return String(format: "On track for ~$%.0f this month.", projected)
    }

    /// Formats a date as local time, e.g. "9:40 pm" — no leading zero on
    /// the hour, lowercase am/pm, locale pinned so this never drifts with
    /// the user's system locale settings.
    private static func localTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date).lowercased()
    }
}
