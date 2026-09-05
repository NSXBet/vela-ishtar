// Sources/VelaCore/ObservationCoverage.swift
// Coverage analysis over Observation series (WP-04, 04.2 + §7.4 gates).
// Why: B09 — BurnBuffer's `date` argument was unused, so a $10 delta over
// one minute and over eight hours produced equal buffers, and frequent
// popover opens compressed the "hour" axis to however often the user
// happened to look. Coverage recomputes burn over ACTUAL elapsed time:
// only intervals that really intersect the last hour count, irregular
// opens never rescale the axis, and long unobserved stretches are gaps —
// never one-minute spikes or bridged curves. All math is pure over
// receipt-ordered Observations (as HistoryRepository stores them).
// RELEVANT FILES: Sources/VelaCore/Observation.swift,
// Sources/VelaCore/HistoryRepository.swift, Sources/VelaCore/BurnBuffer.swift,
// Tests/VelaCoreTests/BurnBufferTests.swift

import Foundation

// MARK: - ObservationCoverage

/// Pure coverage/rate math over an observation series. No clock reads,
/// no I/O — every function takes its `now`.
public enum ObservationCoverage {

    /// §7.4 forecast-eligibility gates for the recent-pace sentence.
    /// Contract constants, not tunables.
    public enum ForecastGate {
        /// Width of the recent-pulse analysis window (the "last hour").
        public static let analysisWindow: TimeInterval = 3600
        /// Minimum continuous coverage inside the analysis window.
        public static let minContinuousCoverage: TimeInterval = 600 // 10 min
        /// Minimum distinct readings in the window.
        public static let minReadings = 6
        /// Largest inter-reading gap tolerated inside the window.
        public static let maxGap: TimeInterval = 150
        /// Width of the correction-free window required for a forecast.
        public static let correctionFreeWindow: TimeInterval = 1800 // 30 min
    }

    /// One observed spend interval: from one reading to the next, with the
    /// cumulative delta actually burned across that real elapsed time.
    public struct Interval: Equatable, Sendable {
        public let start: Date
        public let end: Date
        /// Cumulative spend delta from `start` to `end`. Never negative:
        /// a downward correction produces a zero-delta interval here and
        /// the caller re-baselines (§7.3 — no invented negative burn).
        public let delta: Double
        /// True when the readings on either side changed the limit policy
        /// (enabled/disabled or limit value) — the interval is real but
        /// its rate is not comparable across the boundary.
        public let crossesPolicyBoundary: Bool

        public var duration: TimeInterval { end.timeIntervalSince(start) }
        /// Dollars per second over the actual elapsed interval. Zero-length
        /// intervals (duplicate receipts) report nil, not infinity.
        public var ratePerSecond: Double? {
            let d = duration
            guard d > 0 else { return nil }
            return delta / d
        }

        public init(start: Date, end: Date, delta: Double, crossesPolicyBoundary: Bool = false) {
            self.start = start
            self.end = end
            self.delta = delta
            self.crossesPolicyBoundary = crossesPolicyBoundary
        }
    }

    /// How a recent window supports a forecast.
    public enum Verdict: Equatable, Sendable {
        /// The window qualifies for a recent-pace calculation.
        case qualified
        /// One named reason the window does not qualify. Always explicit —
        /// §7.4 requires an `insufficientEvidence` result, never a fake.
        case insufficientEvidence(reason: Reason)
    }

    /// Named, factual reasons evidence is insufficient.
    public enum Reason: Equatable, Sendable {
        /// Fewer readings than the gate requires (or none at all).
        case tooFewReadings
        /// Total continuous coverage under the gate.
        case coverageTooShort
        /// An unobserved stretch longer than the gate — a gap, not a rate.
        case gapTooLong(gapSeconds: TimeInterval)
        /// A downward correction landed inside the required window.
        case corrected
        /// Readings span more than one gateway day.
        case dayMismatch
        /// Readings belong to a different scope than the displayed one.
        case scopeMismatch
        /// The newest reading is beyond the freshness window.
        case stale
        /// No burn observed in the recent window (idle).
        case idle
        /// A cumulative reset (new billing day) sits inside the window.
        case dayReset
        /// Readings lack exact receipt precision — only hour-precision
        /// legacy values, whose true inter-reading times are unknown.
        case impreciseTiming
        /// The projected exhaustion falls past the next billing reset —
        /// show factual remaining room instead (§7.4).
        case projectionPastReset
        /// The projected exhaustion precedes the analysis instant itself
        /// (burst spend) — a projection anchored before "now" is nonsense.
        case projectionBeforeNow
    }

    /// Splits a receipt-ordered observation series into consecutive
    /// intervals. Same-instant duplicate receipts collapse (the later
    /// cumulative value wins). A downward correction yields delta 0 for
    /// that step and keeps the pair visible, so callers can re-baseline;
    /// no negative burn is ever produced.
    public static func intervals(from observations: [Observation]) -> [Interval] {
        guard observations.count >= 2 else { return [] }
        var left = observations[0]
        var result: [Interval] = []
        for index in 1..<observations.count {
            let right = observations[index]
            if right.receivedAt == left.receivedAt {
                // Same-instant duplicate: the later cumulative value wins;
                // it becomes the new left edge with no interval emitted.
                left = right
                continue
            }
            result.append(Interval(
                start: left.receivedAt,
                end: right.receivedAt,
                delta: max(0, right.cumulativeAmount - left.cumulativeAmount),
                crossesPolicyBoundary:
                    left.limitEnabled != right.limitEnabled ||
                    left.limitUSD != right.limitUSD
            ))
            left = right
        }
        return result
    }

    /// The part of `interval` inside `[windowStart, now]`. B09: poll time
    /// is REAL wall-clock time, so an interval opened at 11:05 and closed
    /// at 11:55 contributes its 50 minutes even if the popover only opened
    /// at 11:59 — irregular opens never rescale the axis. The delta is
    /// apportioned linearly across the intersection.
    public static func intersecting(_ interval: Interval, since windowStart: Date, until now: Date) -> Interval? {
        let s = max(interval.start, windowStart)
        let e = min(interval.end, now)
        guard e > s, interval.duration > 0 else { return nil }
        let fraction = e.timeIntervalSince(s) / interval.duration
        return Interval(
            start: s,
            end: e,
            delta: interval.delta * fraction,
            crossesPolicyBoundary: interval.crossesPolicyBoundary
        )
    }

    /// Whether any downward correction (a cumulative reading lower than
    /// its predecessor beyond the repository's restatement tolerance)
    /// lands inside `[cutoff, now]`.
    public static func hasCorrection(in observations: [Observation], since cutoff: Date) -> Bool {
        for i in 1..<observations.count
        where observations[i].receivedAt >= cutoff {
            // Mirror HistoryRepository's tolerance: a drop larger than
            // max(1% of the peak, $0.50) is a real correction; tiny dips
            // within tolerance are rounding, not restatements.
            let peak = observations[0...i].map(\.cumulativeAmount).max() ?? 0
            let tolerance = max(peak * 0.01, 0.50)
            if observations[i].cumulativeAmount < peak - tolerance {
                return true
            }
        }
        return false
    }

    /// The §7.4 eligibility verdict for a recent-pace forecast over
    /// `recent` (receipt-ordered, oldest first) as of `now`, expected to
    /// all belong to `scope` and `day`.
    ///
    /// Gates, in check order: scope/day identity; freshness of the newest
    /// reading; reading count; exact receipt precision; no cumulative
    /// reset; enough clipped continuous coverage; no gap over the gate; no
    /// downward correction inside the correction-free window; and actual
    /// burn in the window (idle is truthful but has no pace). Any failure
    /// is a named `insufficientEvidence`, never a fabricated ETA.
    public static func paceVerdict(
        recent: [Observation],
        scope: UsageScope,
        day: GatewayDay,
        now: Date
    ) -> Verdict {
        guard let newest = recent.last else {
            return .insufficientEvidence(reason: .tooFewReadings)
        }
        guard newest.scope == scope else {
            return .insufficientEvidence(reason: .scopeMismatch)
        }
        guard newest.gatewayDay == day else {
            return .insufficientEvidence(reason: .dayMismatch)
        }
        guard Freshness.derive(receivedAt: newest.receivedAt, now: now).isFresh else {
            return .insufficientEvidence(reason: .stale)
        }
        guard recent.count >= ForecastGate.minReadings else {
            return .insufficientEvidence(reason: .tooFewReadings)
        }
        guard recent.allSatisfy({ $0.precision == .exactReceipt }) else {
            return .insufficientEvidence(reason: .impreciseTiming)
        }

        // A billing-day reset (cumulative restarted at a lower value)
        // re-baselines the whole window: the readings straddle two days
        // of spending and no single rate describes both.
        for i in 1..<recent.count
        where recent[i].cumulativeAmount < recent[i - 1].cumulativeAmount {
            return .insufficientEvidence(reason: .dayReset)
        }

        let steps = intervals(from: recent)

        // Coverage: only intervals genuinely inside the analysis window
        // count, clipped to it — the window is wall-clock, not a sample
        // count.
        let windowStart = now.addingTimeInterval(-ForecastGate.analysisWindow)
        let clipped = steps.compactMap { intersecting($0, since: windowStart, until: now) }
        let coverage = clipped.reduce(0.0) { $0 + $1.duration }
        guard coverage >= ForecastGate.minContinuousCoverage else {
            return .insufficientEvidence(reason: .coverageTooShort)
        }

        // Gaps: any inter-reading stretch longer than the gate is time the
        // gateway was unobserved — evidence of absence, not a rate to
        // bridge (§7.4: no invented within-gap rate).
        for step in steps where step.duration > ForecastGate.maxGap {
            return .insufficientEvidence(reason: .gapTooLong(gapSeconds: step.duration))
        }

        // Downward correction inside the correction-free window: the day's
        // numbers were restated, so the recent rate does not describe the
        // current world.
        let correctionCutoff = now.addingTimeInterval(-ForecastGate.correctionFreeWindow)
        if hasCorrection(in: recent, since: correctionCutoff) {
            return .insufficientEvidence(reason: .corrected)
        }

        // Idle: nothing burned in the window — truthful, but no pace.
        let burned = clipped.reduce(0.0) { $0 + $1.delta }
        guard burned > 0 else {
            return .insufficientEvidence(reason: .idle)
        }

        return .qualified
    }

    /// The observed burn rate over the qualified window: total delta over
    /// the total covered time from the first reading to `now`. Only call
    /// after `.qualified` — the caller chooses what to do with an
    /// unqualified window and the verdict already says why it's unusable.
    public static func observedRate(
        recent: [Observation],
        now: Date
    ) -> Double? {
        guard let first = recent.first, let last = recent.last else { return nil }
        let elapsed = last.receivedAt.timeIntervalSince(first.receivedAt)
        guard elapsed > 0 else { return nil }
        let delta = last.cumulativeAmount - first.cumulativeAmount
        guard delta > 0 else { return nil }
        return delta / elapsed
    }

    /// Median per-hour cumulative at `hourUTC` across the previous 14
    /// CALENDAR days of observations (§7.4 medians policy). Eligible
    /// samples:
    /// - same scope only (never another credential's data),
    /// - strictly PAST gateway days relative to `today` — never today,
    ///   never future, never the unassigned-legacy archive scope,
    /// - hour-anchored at the legacy-safe UTC slot start (an
    ///   `.exactReceipt` reading at 12:37 counts at hour 12's anchor, the
    ///   same convention HistoryStore used, so past and present are
    ///   comparable),
    /// - complete-coverage days only when `requireComplete` is set.
    ///
    /// Returns nil below `minDays` eligible days — the caller falls back,
    /// never fabricating a benchmark from insufficient history. An
    /// incomplete history must not imply a complete month.
    public static func medianSpend(
        atHourUTC hour: Int,
        observationsByDay: [String: [Observation]],
        scope: UsageScope,
        todayKey: String,
        now: Date,
        minDays: Int = 5,
        windowDays: Int = 14
    ) -> Double? {
        guard (0..<24).contains(hour) else { return nil }

        // Calendar cutoff: strictly the previous `windowDays` calendar
        // days before today's key (§7.4: "previous 14 CALENDAR days").
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "yyyy-MM-dd"
        guard let today = formatter.date(from: todayKey) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let cutoffDay = calendar.date(byAdding: .day, value: -windowDays, to: today),
              let cutoffKey = Optional(formatter.string(from: cutoffDay)) else { return nil }

        let scopeID = scope.opaqueID.uuidString
        var samples: [Double] = []
        for (dayKey, observations) in observationsByDay.sorted(by: { $0.key > $1.key }) {
            // Most recent first; stop once outside the calendar window.
            if dayKey <= cutoffKey { break }
            if dayKey >= todayKey { continue } // today and future never contribute
            guard !observations.isEmpty else { continue }
            // Same scope only; the unassigned-legacy archive scope never
            // contributes to a personal median.
            guard observations.allSatisfy({ $0.scope.opaqueID.uuidString == scopeID }) else { continue }
            guard let slot = GatewayDay(spendDate: dayKey)?.startOfDayUTC?.addingTimeInterval(Double(hour) * 3600) else { continue }
            // The last reading whose effective instant falls inside the
            // slot: hour-anchored, never interpolated. Legacy-hour
            // readings participate at their SLOT START (their only honest
            // instant, B15); exact receipts at their real time.
            let slotEnd = slot.addingTimeInterval(3600)
            let candidates = observations.compactMap { o -> (Date, Double)? in
                let t = o.precision == .legacyHour ? slot : o.receivedAt
                guard t >= slot, t < slotEnd else { return nil }
                return (t, o.cumulativeAmount)
            }
            guard let reading = candidates.max(by: { $0.0 < $1.0 }) else { continue }
            samples.append(reading.1)
        }
        guard samples.count >= minDays else { return nil }
        samples.sort()
        let mid = samples.count / 2
        if samples.count % 2 == 1 { return samples[mid] }
        return (samples[mid - 1] + samples[mid]) / 2
    }
}
