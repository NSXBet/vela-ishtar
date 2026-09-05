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

// MARK: - Observation

/// One accepted reading of the cumulative spend, stored per scope and
/// gateway day.
///
/// §7.2: "Stable ID, scope, gateway day, receivedAt, cumulative amount,
/// enabled-limit/policy context, precision (`exactReceipt` or
/// `legacyHour`); receivedAt is observation time, not transaction time."
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

// MARK: - HistoryEnvelope

/// The versioned on-disk history container (schema 2).
///
/// §7.2: "Schema version 2, revision, scoped day records, bounded
/// observations, coverage metadata; version 1 backup retained during
/// migration." The 2 MiB active-size budget, per-day observation caps, and
/// the byte-preserving legacy backup are enforced by the history writer
/// (WP-02), described here as contract.
public struct HistoryEnvelope: Equatable, Sendable {
    /// On-disk schema version. 2 is the v2.0 envelope.
    public static let currentVersion = 2

    /// Schema version of this envelope (always 2 for fresh writes).
    public let version: Int
    /// Monotonic revision, bumped by every committed write; used by the
    /// serial writer to detect lost updates.
    public let revision: UInt64
    /// Day records keyed by scope opaque ID, then gateway day key.
    public let days: [String: [String: [Observation]]]
    /// Coverage metadata: which days have enough observations to support
    /// derived views, per scope.
    public struct Coverage: Equatable, Sendable {
        public let dayKey: String
        public let firstObservationAt: Date?
        public let lastObservationAt: Date?
        public let isComplete: Bool

        public init(dayKey: String, firstObservationAt: Date?, lastObservationAt: Date?, isComplete: Bool) {
            self.dayKey = dayKey
            self.firstObservationAt = firstObservationAt
            self.lastObservationAt = lastObservationAt
            self.isComplete = isComplete
        }
    }

    /// Coverage summaries for the days in this envelope.
    public let coverage: [String: [String: Coverage]]

    public init(
        version: Int = HistoryEnvelope.currentVersion,
        revision: UInt64,
        days: [String: [String: [Observation]]],
        coverage: [String: [String: Coverage]]
    ) {
        self.version = version
        self.revision = revision
        self.days = days
        self.coverage = coverage
    }
}

// MARK: - ConnectionState

/// The credential/connection lifecycle state.
///
/// §7.2: "`noCredential`, `keychainBlocked`, `connecting`, `live`,
/// `retrying`, `stale`, `authenticationRequired`, `invalidResponse`;
/// retains last good snapshot separately" — the last good snapshot lives
/// OUTSIDE this enum, alongside it, so a stale reading still renders.
public enum ConnectionState: Equatable, Sendable {
    /// No credential has been provided yet.
    case noCredential
    /// The Keychain blocked the read (locked, denied, or unavailable).
    case keychainBlocked
    /// A fetch is in flight; no result yet.
    case connecting
    /// The latest fetch succeeded; the attached snapshot is current.
    case live
    /// Retrying after a transient failure; backoff in progress.
    case retrying(attempt: Int)
    /// Trust expired (receipt age beyond the freshness window) without a
    /// hard error.
    case stale
    /// The gateway rejected the credential (401-class).
    case authenticationRequired
    /// A response arrived but could not be validated (decode/shape).
    case invalidResponse
}

// MARK: - Freshness

/// Derived trust in the currently displayed numbers.
///
/// §7.2: "Derive from receipt age, explicit invalidation, and request
/// result; fresh for at most 90s, then stale; authentication errors
/// immediately invalidate current trust." The 90-second window is the
/// contract maximum; the derivation itself is WP-04.
public enum Freshness: Equatable, Sendable {
    /// Within the freshness window of a validated receipt.
    case fresh(receivedAt: Date, maxAgeSeconds: Double)
    /// Beyond the window, or explicitly invalidated.
    case stale(lastReceivedAt: Date?)
    /// Trust was revoked before it could age out (auth failure, invalid
    /// response, credential change).
    case invalidated(reason: String)
}

// MARK: - BudgetOverview

/// The complete, presentation-ready budget picture.
///
/// §7.2: "Global policy, deterministically sorted model signals,
/// per-model budget headroom, reset description, freshness; no unsupported
/// availability promise" — anything not known is stated as unavailable,
/// never defaulted.
public struct BudgetOverview: Equatable, Sendable {
    /// One model's cap position at the overview's instant.
    public struct ModelSignal: Equatable, Sendable {
        public let model: String
        public let spentUSD: Double
        public let limitUSD: Double?
        /// Spend headroom under the model's own cap, nil when uncapped.
        public let headroomUSD: Double?
        /// Active cooldown bypass of the MODEL cap only, if any.
        public let relaxedUntil: Date?

        public init(model: String, spentUSD: Double, limitUSD: Double?, headroomUSD: Double?, relaxedUntil: Date?) {
            self.model = model
            self.spentUSD = spentUSD
            self.limitUSD = limitUSD
            self.headroomUSD = headroomUSD
            self.relaxedUntil = relaxedUntil
        }
    }

    /// Global daily budget: enabled state and value. A disabled global
    /// limit is UNLIMITED; a model cap of zero is BLOCKED — these are
    /// different semantics and both survive here untouched.
    public let globalLimitEnabled: Bool
    public let globalLimitUSD: Double
    public let globalSpentUSD: Double
    /// Model signals, deterministically sorted (spend descending, then
    /// model name ascending) so equal inputs always render identically.
    public let modelSignals: [ModelSignal]
    /// Human-readable description of when the current window resets
    /// ("resets at UTC midnight" / "no daily limit"), never an invented date.
    public let resetDescription: String
    /// Freshness of the numbers this overview was derived from.
    public let freshness: Freshness

    public init(
        globalLimitEnabled: Bool,
        globalLimitUSD: Double,
        globalSpentUSD: Double,
        modelSignals: [ModelSignal],
        resetDescription: String,
        freshness: Freshness
    ) {
        self.globalLimitEnabled = globalLimitEnabled
        self.globalLimitUSD = globalLimitUSD
        self.globalSpentUSD = globalSpentUSD
        self.modelSignals = modelSignals
        self.resetDescription = resetDescription
        self.freshness = freshness
    }
}

// MARK: - SummaryDisplayState

/// The immutable display state the popover renders from.
///
/// §7.2: "Equatable section states, stable row IDs, selected model period
/// and its scoped total, freshness/accessibility text; no Keychain/network
/// reads while constructing/applying." Pure value: building or applying
/// this state performs no I/O.
public struct SummaryDisplayState: Equatable, Sendable {
    /// One display row: stable ID across refreshes so AppKit diffing
    /// (and VoiceOver) track the same logical row.
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let detail: String
        public let fraction: Double?

        public init(id: String, title: String, detail: String, fraction: Double?) {
            self.id = id
            self.title = title
            self.detail = detail
            self.fraction = fraction
        }
    }

    /// The hero section: headline amount + narrative line.
    public let hero: Row
    /// Model rows (max four named + pinned "Other" at the UI layer; the
    /// cap is presentation policy, not stored here).
    public let rows: [Row]
    /// The selected model period and its scoped total ("today" vs "month").
    public let selectedPeriod: String
    public let selectedPeriodTotalUSD: Double
    /// Freshness line for display and accessibility.
    public let freshnessText: String
    /// Full accessibility summary of the summary section.
    public let accessibilitySummary: String

    public init(
        hero: Row,
        rows: [Row],
        selectedPeriod: String,
        selectedPeriodTotalUSD: Double,
        freshnessText: String,
        accessibilitySummary: String
    ) {
        self.hero = hero
        self.rows = rows
        self.selectedPeriod = selectedPeriod
        self.selectedPeriodTotalUSD = selectedPeriodTotalUSD
        self.freshnessText = freshnessText
        self.accessibilitySummary = accessibilitySummary
    }
}

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

// MARK: - UsageTransport

/// The async transport seam every usage fetch goes through.
///
/// §7.2 suggested shape. The live client (WP-03) implements this over
/// URLSession; tests inject a fake. Token parameters remain in memory
/// only — no conforming type may log, persist, or embed the token.
public protocol UsageTransport: Sendable {
    func fetchUsage(token: String) async throws -> UsageResponse
}

// MARK: - RefreshReason

/// Why a refresh was requested; drives backoff and scheduling policy.
///
/// §7.2 suggested shape.
public enum RefreshReason: Sendable, Equatable {
    case launch
    case scheduled
    case opened
    case manual
    case wake
    case credentialChanged
}
