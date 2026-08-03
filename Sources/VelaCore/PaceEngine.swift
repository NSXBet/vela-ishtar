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
    public static func verdict(spent: Double, limit: Double, limitEnabled: Bool, now: Date, exhaustedAt: Date? = nil) -> PaceVerdict {
        guard limitEnabled else { return .cruisingNoLimit }
        guard spent < limit else { return .exhausted(reachedAt: exhaustedAt ?? now) }
        guard spent > 0 else { return .idle }

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

    /// The sentence shown under the verdict. `now` defaults to the real
    /// clock — in the running app sentence() is called right after
    /// verdict() with the same instant, so this stays accurate in
    /// production while letting tests pin a deterministic `now`.
    public static func sentence(for verdict: PaceVerdict, now: Date = Date()) -> String {
        switch verdict {
        case .idle:
            return "No spend yet today."
        case .cruisingNoLimit:
            return "No daily limit on your account."
        case .exhausted(let reachedAt):
            return "Budget reached at \(localTime(reachedAt)). Resets at midnight UTC."
        case .pace(let eta):
            // Shared with verdict()'s early-day fallback so both agree on
            // where "today" ends -- otherwise the two computations could
            // silently drift apart.
            let midnightBoundary = Self.nextMidnightUTC(after: now)
            if eta < midnightBoundary {
                return "At this pace you'll reach budget around \(localTime(eta))."
            } else {
                return "On pace to stay under budget today."
            }
        }
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
