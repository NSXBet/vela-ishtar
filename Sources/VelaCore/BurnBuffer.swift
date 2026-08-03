// Sources/VelaCore/BurnBuffer.swift
// Rolling buffer of per-poll-minute dollars burned, derived from the API's
// cumulative "spent today" figure by differencing consecutive reads.
// Why: the API only reports a running total, not a rate; this buffer turns
// that into a sparkline-ready series and survives the UTC-midnight reset.
// RELEVANT FILES: Tests/VelaCoreTests/BurnBufferTests.swift, PaceEngine.swift, Models.swift

import Foundation

public struct BurnBuffer: Equatable, Sendable {
    /// Number of poll-minute slots retained. Older slots are evicted first.
    public static let capacity = 60

    /// Dollars burned per poll, oldest first.
    public private(set) var slots: [Double] = []

    // Cumulative "spent today" from the previous call to record(), used to
    // compute this poll's delta. Nil until the first record() call.
    private var previousSpentToday: Double?

    public init() {}

    /// Records a new cumulative "spent today" reading and appends the delta
    /// (this poll's burn) to the buffer.
    ///
    /// The first call after init (or after a reset) has no prior baseline,
    /// so it stores a delta of 0 rather than guessing — there's no way to
    /// know how much was spent before this app started watching.
    ///
    /// A negative delta means today's cumulative spend went DOWN, which only
    /// happens when the API's spend counter reset at UTC midnight between
    /// polls. In that case the whole buffer is cleared (the old deltas
    /// belonged to a different day) and a single 0 is stored for this poll.
    public mutating func record(spentToday: Double, at date: Date) {
        guard let previous = previousSpentToday else {
            previousSpentToday = spentToday
            slots.append(0)
            return
        }

        let delta = spentToday - previous
        previousSpentToday = spentToday

        if delta < 0 {
            slots = [0]
            return
        }

        slots.append(delta)
        if slots.count > Self.capacity {
            slots.removeFirst(slots.count - Self.capacity)
        }
    }

    /// Every slot divided by the largest slot, for drawing a 0...1 sparkline.
    /// Returns nil when every slot is zero (nothing burned yet to normalize).
    public func normalized() -> [Double]? {
        guard let maxSlot = slots.max(), maxSlot > 0 else { return nil }
        return slots.map { $0 / maxSlot }
    }
}
