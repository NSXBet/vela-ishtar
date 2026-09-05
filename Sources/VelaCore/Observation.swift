// Sources/VelaCore/Observation.swift
// The timestamp-aware history sample (WP-02): one accepted reading of the
// gateway's cumulative daily spend, stored per scope and gateway day.
// Why: the legacy hourly-slot HistoryStore cannot represent an after-midnight
// reading for the previous gateway day (§12.1 ascending-seam loss, finding
// B01) and cannot say how old a reading actually is (B15). Observation keeps
// gateway day and ACTUAL receipt time independently, so chart order follows
// receipt order inside the declared billing day and nothing is ever written
// into the wrong hour.
// RELEVANT FILES: Sources/VelaCore/HistoryRepository.swift,
// Sources/VelaCore/HistoryStore.swift, Sources/VelaCore/UsageContracts.swift,
// Tests/VelaCoreTests/HistoryRepositoryTests.swift

import Foundation

// MARK: - Observation

/// One accepted reading of the cumulative spend, stored per scope and
/// gateway day.
///
/// §7.2: "Stable ID, scope, gateway day, receivedAt, cumulative amount,
/// enabled-limit/policy context, precision (`exactReceipt` or
/// `legacyHour`); receivedAt is observation time, not transaction time."
///
/// Moved here verbatim from UsageContracts.swift (WP-02 is the producer);
/// names, cases, and semantics are unchanged. Codable was added so the
/// schema-2 `HistoryEnvelope` can persist observations; scope and gateway
/// day encode by their stable labels (`opaqueID`, `key`), never as raw
/// spend_date instants.
/// Serialization is NOT on this struct: §7.3 requires scope/day metadata to
/// be stored ONCE per day, not duplicated per sample. HistoryRepository's
/// normalized schema-2 DTO owns encoding/decoding and rehydrates
/// Observations from the shared metadata tables.
public struct Observation: Equatable, Sendable, Identifiable {
    /// How precisely the reading's time is known.
    public enum Precision: String, Equatable, Sendable, Codable {
        /// The reading's receipt time is known exactly (v2 schema).
        case exactReceipt
        /// The reading is a legacy hourly value; only hour precision is honest.
        case legacyHour
    }

    /// Stable identifier, stable across save/load and revisions.
    public let id: UUID
    /// The scope whose credential produced this reading.
    public let scope: UsageScope
    /// The gateway billing day the reading was labeled with.
    public let gatewayDay: GatewayDay
    /// When the observation was received — NOT when the spend happened.
    public let receivedAt: Date
    /// Cumulative amount the gateway reported for the declared day.
    public let cumulativeAmount: Double
    /// Whether the global limit was enabled at observation time, plus its
    /// value — the policy context the observation was made under.
    public let limitEnabled: Bool
    public let limitUSD: Double
    /// Time precision of this observation.
    public let precision: Precision

    public init(
        id: UUID,
        scope: UsageScope,
        gatewayDay: GatewayDay,
        receivedAt: Date,
        cumulativeAmount: Double,
        limitEnabled: Bool,
        limitUSD: Double,
        precision: Precision
    ) {
        self.id = id
        self.scope = scope
        self.gatewayDay = gatewayDay
        self.receivedAt = receivedAt
        self.cumulativeAmount = cumulativeAmount
        self.limitEnabled = limitEnabled
        self.limitUSD = limitUSD
        self.precision = precision
    }
}

