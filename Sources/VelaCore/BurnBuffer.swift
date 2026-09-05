// Sources/VelaCore/BurnBuffer.swift
// Time-correct rolling pulse of recent burn (WP-04, 04.2; finding B09),
// derived from the gateway's cumulative "spent today" by differencing
// consecutive OBSERVATIONS in receipt order.
// Why: the old buffer ignored the observation dates entirely — a $10 delta
// over one minute and over eight hours produced equal slots, and every
// popover open (which polls) compressed the supposed hour. The buffer now
// stores timestamped intervals and keeps only those intersecting the last
// hour of real wall-clock time: irregular opens never rescale the axis and
// a sleep gap is a gap, not a one-minute spike.
// RELEVANT FILES: Sources/VelaCore/ObservationCoverage.swift,
// Sources/VelaCore/Observation.swift, PaceEngine.swift, Models.swift

import Foundation

public struct BurnBuffer: Equatable, Sendable {
    /// The analysis window the pulse covers (§7.3 recent window).
    public static let window: TimeInterval = 3600

    /// One pulse sample: the real wall-clock sub-interval it covers and
    /// the burn apportioned to it. Consecutive samples share endpoints,
    /// so a sparkline drawn from them is honest about time.
    public struct Slot: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let burn: Double

        public init(start: Date, end: Date, burn: Double) {
            self.start = start
            self.end = end
            self.burn = burn
        }

        /// Real wall-clock seconds this sample covers.
        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Observed sub-intervals inside the last hour, oldest first.
    public private(set) var slots: [Slot] = []

    /// The cumulative reading each slot's END was computed from — the
    /// baseline for the next record(). Kept as the newest observation.
    private var latest: Observation?

    public init() {}

    /// Records a new observation and re-derives the pulse from ALL
    /// retained observations, keeping only the parts inside the last
    /// `window` seconds. B09 fixed: `date` (via Observation.receivedAt)
    /// actually drives the math — same delta over 1 minute vs 8 hours
    /// now yields different coverage.
    ///
    /// A downward correction (spend restated below the running peak)
    /// establishes a NEW baseline: the correction interval itself
    /// contributes zero burn, and earlier slots remain (real observed
    /// spend) but the caller re-baselines comparisons across it —
    /// never a negative burn (§7.3).
    public mutating func record(_ observation: Observation) {
        // Same-instant duplicate receipt: the later cumulative wins and
        // no interval is emitted.
        if let current = latest, observation.receivedAt <= current.receivedAt {
            latest = observation
            rederive()
            return
        }
        if let current = latest {
            let raw = observation.cumulativeAmount - current.cumulativeAmount
            // Append the interval this poll actually covers. The delta is
            // clamped at 0: a restatement down is a baseline change, not
            // negative burn.
            slots.append(Slot(
                start: current.receivedAt,
                end: observation.receivedAt,
                burn: max(0, raw)
            ))
        }
        latest = observation
        rederive()
    }

    /// Legacy-shape record for call sites still thinking in (cumulative,
    /// date) pairs; wraps Observation construction.
    public mutating func record(
        spentToday: Double,
        at date: Date,
        scope: UsageScope,
        gatewayDay: GatewayDay,
        limitEnabled: Bool = true,
        limitUSD: Double = 0
    ) {
        record(Observation(
            id: UUID(),
            scope: scope,
            gatewayDay: gatewayDay,
            receivedAt: date,
            cumulativeAmount: spentToday,
            limitEnabled: limitEnabled,
            limitUSD: limitUSD,
            precision: .exactReceipt
        ))
    }

    /// Drops sub-intervals that no longer intersect the last-hour window.
    /// An interval PARTIALLY outside contributes only its inside part —
    /// that is the time-correct pulse: the axis is wall-clock, not a
    /// sample count.
    private mutating func rederive() {
        guard let latest else { slots = []; return }
        let windowStart = latest.receivedAt.addingTimeInterval(-Self.window)
        slots = slots.compactMap { slot in
            let s = max(slot.start, windowStart)
            let e = min(slot.end, latest.receivedAt)
            guard e > s else { return nil }
            let full = slot.end.timeIntervalSince(slot.start)
            guard full > 0 else { return nil }
            let fraction = e.timeIntervalSince(s) / full
            return Slot(start: s, end: e, burn: slot.burn * fraction)
        }
    }

    /// Total observed burn in the pulse window.
    public var totalBurn: Double {
        slots.reduce(0) { $0 + $1.burn }
    }

    /// Observed rate (dollars/second) across the pulse, over the ACTUAL
    /// elapsed time from the first slot's start to the last slot's end.
    /// nil when no time is covered or nothing burned.
    public var ratePerSecond: Double? {
        guard let first = slots.first, let last = slots.last else { return nil }
        let elapsed = last.end.timeIntervalSince(first.start)
        guard elapsed > 0 else { return nil }
        let burn = totalBurn
        guard burn > 0 else { return nil }
        return burn / elapsed
    }

    /// Every slot burn divided by the largest slot burn, for drawing a
    /// 0...1 sparkline. Nil when every slot is zero (nothing burned).
    public func normalized() -> [Double]? {
        guard let maxBurn = slots.map(\.burn).max(), maxBurn > 0 else { return nil }
        return slots.map { $0.burn / maxBurn }
    }
}
