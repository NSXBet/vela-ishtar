// Sources/VelaCore/SpendMarker.swift
// WP-09 09.1: the marker engine — start/finish from accepted observations,
// bounded optional names, comparable cumulative deltas with EXPLICIT
// unavailable boundaries, plus the bounded markers.json persistence DTO.
// Why: F02 lets the user bracket a spend interval ("what has this run cost
// so far?"). A marker's delta is only measured when the two endpoint
// observations are genuinely comparable — same scope, same gateway day, no
// downward correction anywhere in the interval. Anything else is an
// explicit unavailable reason, never a guessed cross-boundary delta. This
// is observed spend in scope during the interval, nothing more: no project
// attribution is recorded or implied anywhere.
//
// Persistence decision (documented for review): receipts and pending
// markers live in a SEPARATE markers.json file next to history.json, not
// as a HistoryEnvelope extension. The envelope is the schema-2 history
// contract with its own revision/retention/size machinery; markers are a
// small bounded user record (max 100 receipts) with an independent
// lifetime — keeping them out of the envelope leaves the migration path
// untouched and keeps marker writes from bumping history revisions.
// RELEVANT FILES: Sources/VelaCore/UsageContracts.swift (MarkerReceipt),
// Sources/VelaCore/HistoryRepository.swift, Sources/VelaCore/Observation.swift,
// Tests/VelaCoreTests/SpendMarkerTests.swift

import Foundation

// MARK: - PendingMarker

/// A marker that has been started but not yet finished. Embedded start
/// observation is the measured baseline; it survives observation pruning
/// because the receipt/pending record carries its own copy.
public struct PendingMarker: Equatable, Sendable {
    /// Stable from start through finish — the finished receipt reuses it.
    public let id: UUID
    /// Optional user-chosen name, normalized to ≤80 characters.
    public let name: String?
    public let scope: UsageScope
    /// The accepted observation the marker measures from.
    public let startObservation: Observation
    /// When the user placed the marker (may be later than the start
    /// observation's receipt).
    public let startedAt: Date

    public init(id: UUID, name: String?, scope: UsageScope, startObservation: Observation, startedAt: Date) {
        self.id = id
        self.name = name
        self.scope = scope
        self.startObservation = startObservation
        self.startedAt = startedAt
    }
}

// MARK: - Marker engine

/// Pure marker rules. No I/O, no clocks — the repository supplies accepted
/// observations and `now`; this type decides what is comparable.
public enum SpendMarker {
    /// The largest name a marker accepts (§7.2: "optional ≤80-character
    /// name"). Longer input is truncated, never rejected silently.
    public static let maxNameLength = 80

    /// Normalizes a user-supplied marker name: trims whitespace, drops the
    /// empty result, truncates at 80 characters.
    public static func normalizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Creates a pending marker from an ACCEPTED observation. Nil when the
    /// observation cannot anchor a measurement (non-finite amount).
    public static func makePending(observation: Observation, name: String?, startedAt: Date) -> PendingMarker? {
        guard observation.cumulativeAmount.isFinite else { return nil }
        return PendingMarker(
            id: UUID(),
            name: normalizedName(name),
            scope: observation.scope,
            startObservation: observation,
            startedAt: startedAt
        )
    }

    /// Finishes a pending marker with an end observation. Returns nil for
    /// INVALID ends — the marker stays pending rather than producing a
    /// garbage receipt: an end observation at or before the start
    /// (stale/misordered), or a non-finite amount.
    ///
    /// `intermediates` are the accepted observations strictly between the
    /// endpoints (the repository supplies the start day's list). A downward
    /// correction anywhere in the interval makes the cumulative series
    /// incomparable — explicit `.discontinuity`, never a negative delta.
    public static func finishReceipt(
        pending: PendingMarker,
        end: Observation,
        intermediates: [Observation]
    ) -> MarkerReceipt? {
        guard end.receivedAt > pending.startObservation.receivedAt else { return nil }
        guard end.cumulativeAmount.isFinite else { return nil }
        let delta = measurableDelta(from: pending.startObservation, to: end, intermediates: intermediates)
        return MarkerReceipt(
            id: pending.id,
            name: pending.name,
            scope: pending.scope,
            startDay: pending.startObservation.gatewayDay,
            endDay: end.gatewayDay,
            startObservation: pending.startObservation,
            endObservation: end,
            delta: delta
        )
    }

    /// The comparable-delta rule (§7.2: "delta or explicit unavailable
    /// reason"). Same cumulative series semantics as the repository's
    /// downward-correction tolerance: max(1% of the earlier peak, $0.50).
    static func measurableDelta(
        from start: Observation,
        to end: Observation,
        intermediates: [Observation]
    ) -> MarkerReceipt.Delta {
        // Token replacement mid-marker: the two readings describe different
        // scopes — amounts are not comparable.
        if end.scope != start.scope { return .unavailable(.scopeChanged) }
        // Midnight boundary: the gateway's cumulative amount resets per
        // billing day, so a cross-day delta would be a guess. Same
        // discontinuity reason covers corrections and day resets: both are
        // breaks in the cumulative series.
        if end.gatewayDay.key != start.gatewayDay.key { return .unavailable(.discontinuity) }

        let series = [start] + intermediates + [end]
        for i in 1..<series.count {
            let earlier = series[i - 1].cumulativeAmount
            let later = series[i].cumulativeAmount
            guard later.isFinite, earlier.isFinite else { return .unavailable(.discontinuity) }
            if later < earlier - max(earlier * 0.01, 0.50) {
                return .unavailable(.discontinuity)
            }
        }
        return .measured(amountUSD: end.cumulativeAmount - start.cumulativeAmount)
    }
}

// MARK: - markers.json persistence DTO

/// The on-disk shape of the marker store. Deliberately hand-rolled (not
/// synthesized Codable on the domain types): `Observation` is intentionally
/// not Codable (§7.3 normalized storage), and an explicit DTO keeps the
/// marker file decodable even if the domain grows non-persisted fields.
struct MarkerStoreDTO: Codable, Equatable {
    static let currentVersion = 1

    struct ObservationDTO: Codable, Equatable {
        var kind: UsageScope.Kind
        var opaqueID: UUID
        var origin: String
        var dayKey: String
        var receivedAt: Date
        var cumulativeAmount: Double
        var limitEnabled: Bool
        var limitUSD: Double
        var precision: Observation.Precision

        init(_ observation: Observation) {
            kind = observation.scope.kind
            opaqueID = observation.scope.opaqueID
            origin = observation.scope.gatewayOrigin
            dayKey = observation.gatewayDay.key
            receivedAt = observation.receivedAt
            cumulativeAmount = observation.cumulativeAmount
            limitEnabled = observation.limitEnabled
            limitUSD = observation.limitUSD
            precision = observation.precision
        }

        /// Nil when the day key is not a real calendar day (corrupt file).
        var observation: Observation? {
            guard let day = GatewayDay(spendDate: dayKey) else { return nil }
            return Observation(
                id: UUID(), // DTO does not carry observation IDs; see note below
                scope: UsageScope(kind: kind, opaqueID: opaqueID, gatewayOrigin: origin),
                gatewayDay: day,
                receivedAt: receivedAt,
                cumulativeAmount: cumulativeAmount,
                limitEnabled: limitEnabled,
                limitUSD: limitUSD,
                precision: precision
            )
        }
    }

    struct DeltaDTO: Codable, Equatable {
        var measured: Double?
        /// One of "noBaseline", "scopeChanged", "discontinuity".
        var reason: String?
    }

    struct ReceiptDTO: Codable, Equatable {
        var id: UUID
        var name: String?
        var startObs: ObservationDTO
        var endObs: ObservationDTO?
        var delta: DeltaDTO
    }

    struct PendingDTO: Codable, Equatable {
        var id: UUID
        var name: String?
        var startedAt: Date
        var startObs: ObservationDTO
    }

    var version: Int
    var pending: [PendingDTO]
    var receipts: [ReceiptDTO]

    static func encode(pending: [PendingMarker], receipts: [MarkerReceipt]) throws -> Data {
        let dto = MarkerStoreDTO(
            version: currentVersion,
            pending: pending.map { p in
                PendingDTO(id: p.id, name: p.name, startedAt: p.startedAt, startObs: ObservationDTO(p.startObservation))
            },
            receipts: receipts.map { r in
                ReceiptDTO(
                    id: r.id,
                    name: r.name,
                    startObs: ObservationDTO(r.startObservation),
                    endObs: r.endObservation.map(ObservationDTO.init),
                    delta: {
                        switch r.delta {
                        case .measured(let amount): return DeltaDTO(measured: amount, reason: nil)
                        case .unavailable(let reason):
                            let label: String
                            switch reason {
                            case .noBaseline: label = "noBaseline"
                            case .scopeChanged: label = "scopeChanged"
                            case .discontinuity: label = "discontinuity"
                            }
                            return DeltaDTO(measured: nil, reason: label)
                        }
                    }()
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(dto)
    }

    /// Returns nil when the file is structurally unusable (wrong version,
    /// malformed records) — the caller keeps the original bytes and starts
    /// empty rather than silently overwriting data it could not read.
    static func decode(_ data: Data) -> (pending: [PendingMarker], receipts: [MarkerReceipt])? {
        guard let dto = try? JSONDecoder().decode(MarkerStoreDTO.self, from: data),
              dto.version == currentVersion else { return nil }

        func markerScope(_ o: ObservationDTO) -> UsageScope {
            UsageScope(kind: o.kind, opaqueID: o.opaqueID, gatewayOrigin: o.origin)
        }
        // Rebuild observations with DETERMINISTIC IDs: the DTO intentionally
        // omits per-observation UUIDs (marker receipts embed their own
        // copies; stable identity is the receipt's id). A fresh UUID per
        // load is harmless for equality of PENDING/receipt content below,
        // but Equatable on Observation includes id — so receipts decode with
        // stable derived IDs via FNV-1a over the DTO fields instead of
        // random UUIDs, keeping restart round-trips exactly equal.
        func stableObservation(_ o: ObservationDTO) -> Observation? {
            guard let day = GatewayDay(spendDate: o.dayKey) else { return nil }
            let identity = "\(o.opaqueID.uuidString)|\(o.dayKey)|\(o.receivedAt.timeIntervalSince1970)|\(o.cumulativeAmount)"
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in identity.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            return Observation(
                id: UUID(uuid: (
                    UInt8(truncatingIfNeeded: hash >> 56), UInt8(truncatingIfNeeded: hash >> 48),
                    UInt8(truncatingIfNeeded: hash >> 40), UInt8(truncatingIfNeeded: hash >> 32),
                    UInt8(truncatingIfNeeded: hash >> 24), UInt8(truncatingIfNeeded: hash >> 16),
                    UInt8(truncatingIfNeeded: hash >> 8), UInt8(truncatingIfNeeded: hash),
                    0x56, 0x45, 0x4C, 0x41, 0x4D, 0x41, 0x52, 0x4B // "VELAMARK" marker namespace tail
                )),
                scope: markerScope(o),
                gatewayDay: day,
                receivedAt: o.receivedAt,
                cumulativeAmount: o.cumulativeAmount,
                limitEnabled: o.limitEnabled,
                limitUSD: o.limitUSD,
                precision: o.precision
            )
        }

        func delta(from dto: DeltaDTO) -> MarkerReceipt.Delta? {
            if let measured = dto.measured { return .measured(amountUSD: measured) }
            switch dto.reason {
            case "noBaseline": return .unavailable(.noBaseline)
            case "scopeChanged": return .unavailable(.scopeChanged)
            case "discontinuity": return .unavailable(.discontinuity)
            default: return nil
            }
        }

        var pending: [PendingMarker] = []
        for p in dto.pending {
            guard let start = stableObservation(p.startObs) else { continue }
            pending.append(PendingMarker(
                id: p.id, name: p.name, scope: start.scope,
                startObservation: start, startedAt: p.startedAt
            ))
        }

        var receipts: [MarkerReceipt] = []
        for r in dto.receipts {
            guard let start = stableObservation(r.startObs),
                  let deltaValue = delta(from: r.delta) else { continue }
            let end = r.endObs.flatMap(stableObservation)
            receipts.append(MarkerReceipt(
                id: r.id, name: r.name, scope: start.scope,
                startDay: start.gatewayDay,
                endDay: end?.gatewayDay ?? start.gatewayDay,
                startObservation: start, endObservation: end, delta: deltaValue
            ))
        }
        return (pending, receipts)
    }
}
