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
public struct Observation: Equatable, Sendable, Identifiable, Codable {
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

// MARK: - Persistence

private enum ObservationCodingKeys: String, CodingKey {
    case id
    case scopeID
    case scopeKind
    case gatewayOrigin
    case gatewayDay
    case receivedAt
    case cumulativeAmount
    case limitEnabled
    case limitUSD
    case precision
}

extension Observation {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: ObservationCodingKeys.self)
        guard let idString = try container.decodeIfPresent(String.self, forKey: .id),
              let id = UUID(uuidString: idString) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Observation id must be a UUID string")
        }
        guard let scopeIDString = try container.decodeIfPresent(String.self, forKey: .scopeID),
              let scopeID = UUID(uuidString: scopeIDString) else {
            throw DecodingError.dataCorruptedError(forKey: .scopeID, in: container, debugDescription: "Observation scopeID must be a UUID string")
        }
        let scopeKind = try container.decode(UsageScope.Kind.self, forKey: .scopeKind)
        let gatewayOrigin = try container.decode(String.self, forKey: .gatewayOrigin)
        let dayKey = try container.decode(String.self, forKey: .gatewayDay)
        guard let gatewayDay = GatewayDay(spendDate: dayKey) else {
            throw DecodingError.dataCorruptedError(forKey: .gatewayDay, in: container, debugDescription: "Observation gatewayDay is not a well-formed day label: \(dayKey)")
        }
        self.init(
            id: id,
            scope: UsageScope(kind: scopeKind, opaqueID: scopeID, gatewayOrigin: gatewayOrigin),
            gatewayDay: gatewayDay,
            receivedAt: try container.decode(Date.self, forKey: .receivedAt),
            cumulativeAmount: try container.decode(Double.self, forKey: .cumulativeAmount),
            limitEnabled: try container.decode(Bool.self, forKey: .limitEnabled),
            limitUSD: try container.decode(Double.self, forKey: .limitUSD),
            precision: try container.decode(Precision.self, forKey: .precision)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: ObservationCodingKeys.self)
        try container.encode(id.uuidString, forKey: .id)
        try container.encode(scope.opaqueID.uuidString, forKey: .scopeID)
        try container.encode(scope.kind, forKey: .scopeKind)
        try container.encode(scope.gatewayOrigin, forKey: .gatewayOrigin)
        // Persist the day LABEL, never a re-derived instant — this is what
        // keeps a non-UTC-midnight spend_date on its real calendar day.
        try container.encode(gatewayDay.key, forKey: .gatewayDay)
        try container.encode(receivedAt, forKey: .receivedAt)
        try container.encode(cumulativeAmount, forKey: .cumulativeAmount)
        try container.encode(limitEnabled, forKey: .limitEnabled)
        try container.encode(limitUSD, forKey: .limitUSD)
        try container.encode(precision, forKey: .precision)
    }
}
