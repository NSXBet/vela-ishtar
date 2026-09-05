// Sources/VelaCore/UsageContracts.swift
// The frozen v2.0 coordination contracts (V2_IMPLEMENTATION_PLAN.md §7.2).
// Why: WP-00 writes these concrete declarations BEFORE dependent work
// packages start, so producers and consumers share one coordination
// boundary — consumers never rename these independently. These are type
// skeletons: later work packages (WP-01/02/03…) flesh out derived logic,
// but every stored property already has a real type and every enum its
// full case set, so downstream code compiles against them today.
// Semantics quoted in doc comments come verbatim from the plan's §7.2
// contract table.
// RELEVANT FILES: V2_IMPLEMENTATION_PLAN.md, Sources/VelaCore/Models.swift,
// docs/v2/API_CONTRACT.md, Tests/VelaAppTests/TestSupport.swift

import Foundation

// MARK: - UsageScope

/// Opaque non-secret local identifier for one credential's data.
///
/// §7.2: "Opaque non-secret local identifier, scope kind (`credential` or
/// verified `account`), gateway origin. Never persist the token as identity.
/// Without an account ID, isolate by returned token ID through an opaque
/// mapping." The raw token never appears here — only a locally derived
/// opaque identity (e.g. a UUID assigned when a token is first seen).
public struct UsageScope: Equatable, Sendable, Hashable {
    /// Scope kind: an unverified single token, or a verified whole account.
    public enum Kind: String, Equatable, Sendable, Codable {
        /// One token's view; isolation keyed by the token's opaque mapping.
        case credential
        /// A verified account identity (gateway account ID confirmed).
        case account
    }

    /// Whether this scope is a single token or a verified account.
    public let kind: Kind
    /// Opaque, non-secret local identifier. NOT the token, NOT the raw
    /// token_id from the wire — a locally generated mapping value.
    public let opaqueID: UUID
    /// The gateway origin this scope's data came from (scheme + host),
    /// so data from a different deployment never mixes in.
    public let gatewayOrigin: String

    public init(kind: Kind, opaqueID: UUID, gatewayOrigin: String) {
        self.kind = kind
        self.opaqueID = opaqueID
        self.gatewayOrigin = gatewayOrigin
    }
}

// MARK: - UsageSnapshot

/// A fully validated usage reading, the domain replacement for a raw
/// `UsageResponse`.
///
/// §7.2: "Validated response, scope, receivedAt, `GatewayDay`, model-data
/// availability, schema warnings. Raw DTO defaults cannot masquerade as
/// domain facts" — i.e. a missing `today`/`today_models` on the wire is
/// recorded as explicit availability, never silently decoded as zeroes.
public struct UsageSnapshot: Equatable, Sendable {
    /// Which parts of the gateway's model breakdown this response carried.
    public enum ModelDataAvailability: Equatable, Sendable {
        /// The response carried today-scoped model rows.
        case available
        /// The response carried the field but with no rows (empty array).
        case empty
        /// The field was absent (older gateway build) — monthly-only view.
        case unavailable
        /// Rows present but internally inconsistent with the day total.
        case inconsistent(reason: String)
    }

    /// Explicit schema-level warnings from tolerant decoding (e.g. "today
    /// absent, defaulted", "non-finite used_percent clamped"), so defaults
    /// from the DTO layer are visible facts, not silent fabrications.
    public struct SchemaWarning: Equatable, Sendable {
        public let field: String
        public let detail: String

        public init(field: String, detail: String) {
            self.field = field
            self.detail = detail
        }
    }

    /// The validated wire response. Validation lives upstream (WP-01);
    /// by the time a snapshot exists, the DTO is trusted.
    public let response: UsageResponse
    /// The credential scope this reading belongs to.
    public let scope: UsageScope
    /// When the response was received (observation time, not transaction time).
    public let receivedAt: Date
    /// The gateway billing day the response declares (from spend_date).
    public let gatewayDay: GatewayDay
    /// Whether today-scoped model data was really in the payload.
    public let modelData: ModelDataAvailability
    /// Non-fatal schema deviations observed while validating.
    public let schemaWarnings: [SchemaWarning]

    public init(
        response: UsageResponse,
        scope: UsageScope,
        receivedAt: Date,
        gatewayDay: GatewayDay,
        modelData: ModelDataAvailability,
        schemaWarnings: [SchemaWarning] = []
    ) {
        self.response = response
        self.scope = scope
        self.receivedAt = receivedAt
        self.gatewayDay = gatewayDay
        self.modelData = modelData
        self.schemaWarnings = schemaWarnings
    }
}

// MARK: - ModelBreakdownState

/// The presentation-safe state of a day's per-model breakdown.
///
/// §7.2: "`available(rows, total, scope)`, `empty`, `unavailable(reason)`,
/// `inconsistent(reason)`; raw field absence survives decoding" — a payload
/// without `today_models` must reach the UI as `.unavailable`, not as a
/// fabricated empty list.
public enum ModelBreakdownState: Equatable, Sendable {
    /// Named rows plus the day total they were computed against, within
    /// one scope. Rows are ordered by spend, descending.
    case available(rows: [ModelUsage], total: Double, scope: UsageScope)
    /// The gateway says there is no model spend for the day.
    case empty
    /// The data was absent (e.g. older gateway without `today_models`).
    case unavailable(reason: String)
    /// Rows contradict the day total (e.g. named sum exceeds the total).
    case inconsistent(reason: String)
}

// MARK: - Observation / HistoryEnvelope

// `Observation` and `HistoryEnvelope` moved to their producer files in
// WP-02: Sources/VelaCore/Observation.swift and
// Sources/VelaCore/HistoryRepository.swift. WP-03 owns ConnectionState
// (Sources/VelaCore/PollStateMachine.swift), UsageTransport, and
// RefreshReason (Sources/VelaCore/AIHubClientProtocol.swift). Names, cases,
// and semantics are identical to the frozen §7.2 declarations; only
// ownership moved. This file keeps the remaining coordination contracts;
// the moved types are intentionally NOT duplicated here.

// MARK: - Freshness

// Freshness moved to its producer file in WP-04:
// Sources/VelaCore/Freshness.swift. Names, cases, and semantics are
// identical to the frozen §7.2 declaration; WP-04 added the derivation
// (receipt age, explicit invalidation, request result). This file keeps
// the remaining coordination contracts; the moved type is intentionally
// NOT duplicated here.

// MARK: - BudgetOverview

// BudgetOverview moved to its producer file in WP-08:
// Sources/VelaCore/BudgetOverview.swift. Names, fields, and semantics are
// identical to the frozen §7.2 declaration; WP-08 added the derived policy
// state and the derive(from:freshness:now:calendar:) entry point. This file
// keeps the remaining coordination contracts; the moved type is
// intentionally NOT duplicated here.

// MARK: - MarkerReceipt

/// A user-placed spend marker with its measured delta.
///
/// §7.2: "ID, optional ≤80-character name, scope, start/end day and
/// observation, delta or explicit unavailable reason, precision/coverage."
public struct MarkerReceipt: Equatable, Sendable {
    /// Why a marker's delta could not be measured.
    public enum DeltaUnavailable: Equatable, Sendable {
        /// No accepted observation exists at or before the marker start.
        case noBaseline
        /// The scope changed between start and end; amounts not comparable.
        case scopeChanged
        /// A downward correction invalidated the interval.
        case discontinuity
    }

    /// The delta value.
    public enum Delta: Equatable, Sendable {
        case measured(amountUSD: Double)
        case unavailable(DeltaUnavailable)
    }

    public let id: UUID
    /// Optional user-chosen name, at most 80 characters.
    public let name: String?
    /// The scope the marker was placed in.
    public let scope: UsageScope
    /// Gateway day of the marker's start observation.
    public let startDay: GatewayDay
    /// Gateway day of the marker's end observation (may differ after
    /// midnight).
    public let endDay: GatewayDay
    /// The start observation itself.
    public let startObservation: Observation
    /// The end observation itself.
    public let endObservation: Observation?
    /// Measured delta or an explicit unavailability reason.
    public let delta: Delta

    public init(
        id: UUID,
        name: String?,
        scope: UsageScope,
        startDay: GatewayDay,
        endDay: GatewayDay,
        startObservation: Observation,
        endObservation: Observation?,
        delta: Delta
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.startDay = startDay
        self.endDay = endDay
        self.startObservation = startObservation
        self.endObservation = endObservation
        self.delta = delta
    }
}
