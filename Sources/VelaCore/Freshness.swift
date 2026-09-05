// Sources/VelaCore/Freshness.swift
// Derived trust in the currently displayed numbers (WP-04, 04.1).
// Why: B05 — freshness used to depend on failure counts instead of elapsed
// age, so a sleeping/hung request could keep a hours-old reading "fresh",
// and errors before the first success left `.neverFetched` rendering as
// Connecting forever. Freshness is derived here from three honest inputs —
// receipt age, explicit invalidation, and the request result — with the
// §7.2 contract that a reading is fresh for at most 90 seconds and an
// authentication failure revokes trust immediately.
// RELEVANT FILES: Sources/VelaCore/UsageContracts.swift,
// Sources/VelaCore/Observation.swift, Tests/VelaCoreTests/FreshnessTests.swift

import Foundation

// MARK: - Freshness

/// Derived trust in the currently displayed numbers.
///
/// §7.2: "Derive from receipt age, explicit invalidation, and request
/// result; fresh for at most 90s, then stale; authentication errors
/// immediately invalidate current trust."
///
/// Moved here verbatim from UsageContracts.swift (WP-04 owns the
/// derivation); names, cases, and semantics are identical to the frozen
/// declaration. UsageContracts.swift no longer carries a copy.
public enum Freshness: Equatable, Sendable {
    /// Within the freshness window of a validated receipt.
    case fresh(receivedAt: Date, maxAgeSeconds: Double)
    /// Beyond the window, or explicitly invalidated.
    case stale(lastReceivedAt: Date?)
    /// Trust was revoked before it could age out (auth failure, invalid
    /// response, credential change).
    case invalidated(reason: String)

    /// The contract maximum a reading may stay fresh. §7.2: "fresh for at
    /// most 90s, then stale". A namespace constant, not a tunable.
    public static let maxAgeSeconds: Double = 90

    /// Small clock-skew allowance: a receipt stamped a few seconds ahead of
    /// the local clock is normal NTP jitter, not a rollback.
    private static let clockSkewTolerance: TimeInterval = 5

    // MARK: derivation (04.1)

    /// Derives freshness from the newest accepted reading.
    ///
    /// - `receivedAt`: when the displayed numbers were received, or nil
    ///   when nothing has ever been received (`.stale(lastReceivedAt: nil)`).
    /// - `precision`: an `.exactReceipt` reading ages from its actual
    ///   receipt time; a `.legacyHour` reading only knows its HOUR, so the
    ///   age is measured conservatively from the START of its hour slot
    ///   (B15: cached age must not pretend slot-start precision is exact —
    ///   the honest reading is "at least this old", so we use the oldest
    ///   bound).
    /// - `invalidatedBy`: a non-nil reason revokes trust immediately,
    ///   regardless of age — authentication failures, invalid responses,
    ///   and credential changes never age out gracefully.
    /// - `now`: the evaluation instant (tests pin it; production passes
    ///   the current time).
    ///
    /// Clock rollback is handled conservatively: a receipt up to 5s in the
    /// future is tolerated jitter (age clamps to 0); anything further ahead
    /// means the local clock cannot be trusted to measure this receipt's
    /// age, so the reading is stale rather than infinitely fresh.
    public static func derive(
        receivedAt: Date?,
        precision: Observation.Precision = .exactReceipt,
        now: Date,
        invalidatedBy: String? = nil
    ) -> Freshness {
        if let invalidatedBy {
            return .invalidated(reason: invalidatedBy)
        }
        guard let receivedAt else {
            return .stale(lastReceivedAt: nil)
        }

        let rawAge = now.timeIntervalSince(receivedAt)
        guard rawAge >= -clockSkewTolerance else {
            // Receipt stamped far ahead of the (rolled-back) clock: its age
            // is unmeasurable, so trust is revoked, not presumed fresh.
            return .stale(lastReceivedAt: receivedAt)
        }

        // Conservative age: exactly when the reading was received for
        // exact receipts; the start of its hour slot for legacy reads.
        let age: TimeInterval
        switch precision {
        case .exactReceipt:
            age = max(0, rawAge)
        case .legacyHour:
            let slotStart = receivedAt.timeIntervalSince1970
                .truncatingRemainder(dividingBy: 3600)
            let slotStartInstant = receivedAt.addingTimeInterval(-slotStart)
            age = max(0, now.timeIntervalSince(slotStartInstant))
        }

        guard age <= maxAgeSeconds else {
            return .stale(lastReceivedAt: receivedAt)
        }
        return .fresh(receivedAt: receivedAt, maxAgeSeconds: maxAgeSeconds)
    }

    /// Explicit invalidation: trust is revoked NOW (auth failure, invalid
    /// response, credential change). The age of the previous receipt is
    /// irrelevant — §7.2: "authentication errors immediately invalidate
    /// current trust".
    public static func invalidated(_ reason: String) -> Freshness {
        .invalidated(reason: reason)
    }

    /// Whether the displayed numbers may back a live projection. Freshness
    /// and confidence are independent (§7.4): `true` here does NOT mean the
    /// data is sufficient for a forecast — only that it isn't known-stale.
    public var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}
