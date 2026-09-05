// Sources/VelaCore/HistoryRepository.swift
// The schema-2 history container (HistoryEnvelope) plus the serial actor
// (HistoryRepository) that owns all load/encode/save for it — including
// the WP-09 marker store (receipts + pending markers) and the day/scope
// listing the history explorer navigates.
// Why: B13 — legacy load/save errors were discarded and file work ran on
// the main actor; B01/§7.3 — history needs receipt-time ordering, retention
// bounds, and a revisioned writer so two rapid saves can never regress the
// file. The actor serializes every mutation and write, so revision ordering
// is structural, not lock-based. File access goes through an injected
// `HistoryFilesystem` seam so failure modes (read-only, full disk, missing
// directory) are deterministic in tests.
// RELEVANT FILES: Sources/VelaCore/Observation.swift,
// Sources/VelaCore/HistoryMigration.swift, Sources/VelaCore/HistoryStore.swift,
// Tests/VelaCoreTests/HistoryRepositoryTests.swift

import Foundation
import OSLog

private let repositoryLog = Logger(subsystem: "com.nsxbet.velaishtar", category: "HistoryRepository")

// MARK: - HistoryEnvelope

/// The versioned on-disk history container (schema 2).
///
/// §7.2: "Schema version 2, revision, scoped day records, bounded
/// observations, coverage metadata; version 1 backup retained during
/// migration." The 2 MiB active-size budget, per-day observation caps, and
/// the byte-preserving legacy backup are enforced by the history writer
/// (WP-02), described here as contract.
///
/// Moved here verbatim from UsageContracts.swift (WP-02 is the producer);
/// names, cases, and semantics are unchanged. Persistence is NOT synthesized
/// Codable on this struct: §7.3 requires scope/day/policy metadata to be
/// stored ONCE and referenced by samples, so encoding/decoding goes through
/// the normalized `NormalizedEnvelopeDTO` below and rehydrates Observations
/// from the shared metadata tables.
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
    public struct Coverage: Equatable, Sendable, Codable {
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

// MARK: - Normalized schema-2 persistence DTO (§7.3 storage shape)

/// The on-disk shape for schema 2. §7.3: "Store shared scope/day metadata
/// once, and policy context by reference within a day, rather than
/// duplicating a large object per sample." Scopes live in one table, each
/// day gets one policy record, and samples reference them by index/key —
/// a 320-observation day stores its scope triple and (limitEnabled, limit)
/// pair once, not 320 times.
private struct NormalizedEnvelopeDTO: Codable, Equatable {
    /// Shared scope table: stable scopeID → (kind, gatewayOrigin).
    struct ScopeRecord: Codable, Equatable {
        var kind: UsageScope.Kind
        var gatewayOrigin: String
    }

    /// Per-day policy context, written once and referenced by samples.
    struct PolicyRecord: Codable, Equatable, Hashable {
        var limitEnabled: Bool
        var limitUSD: Double
    }

    /// One stored sample: everything unique to the reading, references for
    /// everything shared.
    struct SampleDTO: Codable, Equatable {
        var id: UUID
        /// Index into the day's policy records (policy context by reference).
        var policy: Int
        var receivedAt: Date
        var cumulativeAmount: Double
        var precision: Observation.Precision
    }

    struct DayDTO: Codable, Equatable {
        var policy: [PolicyRecord]
        var samples: [SampleDTO]
    }

    var version: Int
    var revision: UInt64
    var scopes: [String: ScopeRecord]
    /// scopeID → dayKey → day record (policy table + reference samples).
    var days: [String: [String: DayDTO]]
    var coverage: [String: [String: HistoryEnvelope.Coverage]]
}

extension HistoryEnvelope {
    /// Encodes through the normalized DTO. Throws if any observation's day
    /// key disagrees with its storage day (a corrupted in-memory map), so a
    /// bad write can never silently persist.
    func encodedForPersistence(using encoder: JSONEncoder) throws -> Data {
        var dto = NormalizedEnvelopeDTO(
            version: version, revision: revision,
            scopes: [:], days: [:], coverage: coverage
        )
        for (scopeID, scopeDays) in days {
            guard let scopeRecord = scopeRecord(forScopeID: scopeID, in: scopeDays) else {
                throw HistoryRepository.SaveError.encodeFailed
            }
            dto.scopes[scopeID] = scopeRecord
            var encodedDays: [String: NormalizedEnvelopeDTO.DayDTO] = [:]
            for (dayKey, observations) in scopeDays {
                var policies: [NormalizedEnvelopeDTO.PolicyRecord] = []
                var policyIndex: [NormalizedEnvelopeDTO.PolicyRecord: Int] = [:]
                var samples: [NormalizedEnvelopeDTO.SampleDTO] = []
                for observation in observations {
                    // A sample must agree with the day it is stored under.
                    guard observation.gatewayDay.key == dayKey,
                          observation.scope.opaqueID.uuidString == scopeID else {
                        throw HistoryRepository.SaveError.encodeFailed
                    }
                    let policy = NormalizedEnvelopeDTO.PolicyRecord(
                        limitEnabled: observation.limitEnabled,
                        limitUSD: observation.limitUSD
                    )
                    let index = policyIndex[policy] ?? {
                        policies.append(policy)
                        policyIndex[policy] = policies.count - 1
                        return policies.count - 1
                    }()
                    samples.append(.init(
                        id: observation.id,
                        policy: index,
                        receivedAt: observation.receivedAt,
                        cumulativeAmount: observation.cumulativeAmount,
                        precision: observation.precision
                    ))
                }
                encodedDays[dayKey] = .init(policy: policies, samples: samples)
            }
            dto.days[scopeID] = encodedDays
        }
        return try encoder.encode(dto)
    }

    /// Every observation in a scope's days must share one UsageScope; take
    /// it from the first sample and verify no sample disagrees.
    private func scopeRecord(forScopeID scopeID: String, in scopeDays: [String: [Observation]]) -> NormalizedEnvelopeDTO.ScopeRecord? {
        var kind: UsageScope.Kind?
        var origin: String?
        for observations in scopeDays.values {
            for observation in observations {
                guard observation.scope.opaqueID.uuidString == scopeID else { return nil }
                if let knownKind = kind {
                    guard observation.scope.kind == knownKind, observation.scope.gatewayOrigin == origin else { return nil }
                } else {
                    kind = observation.scope.kind
                    origin = observation.scope.gatewayOrigin
                }
            }
        }
        guard let kind, let origin else { return nil }
        return .init(kind: kind, gatewayOrigin: origin)
    }

    /// Decodes the normalized DTO back into the in-memory envelope,
    /// rehydrating each Observation from the shared tables. Throws on any
    /// dangling reference (bad policy index, unknown scope) — the caller
    /// treats that as a corrupt file, not a partial load.
    static func decodedFromPersistence(_ data: Data, using decoder: JSONDecoder) throws -> HistoryEnvelope {
        let dto = try decoder.decode(NormalizedEnvelopeDTO.self, from: data)
        var days: [String: [String: [Observation]]] = [:]
        for (scopeID, scopeDays) in dto.days {
            guard let scopeRecord = dto.scopes[scopeID],
                  let opaqueID = UUID(uuidString: scopeID) else {
                throw HistoryRepository.SaveError.encodeFailed
            }
            let scope = UsageScope(kind: scopeRecord.kind, opaqueID: opaqueID, gatewayOrigin: scopeRecord.gatewayOrigin)
            var decodedDays: [String: [Observation]] = [:]
            for (dayKey, day) in scopeDays {
                guard let gatewayDay = GatewayDay(spendDate: dayKey) else {
                    throw HistoryRepository.SaveError.encodeFailed
                }
                let observations = try day.samples.map { sample -> Observation in
                    guard day.policy.indices.contains(sample.policy) else {
                        throw HistoryRepository.SaveError.encodeFailed
                    }
                    let policy = day.policy[sample.policy]
                    return Observation(
                        id: sample.id,
                        scope: scope,
                        gatewayDay: gatewayDay,
                        receivedAt: sample.receivedAt,
                        cumulativeAmount: sample.cumulativeAmount,
                        limitEnabled: policy.limitEnabled,
                        limitUSD: policy.limitUSD,
                        precision: sample.precision
                    )
                }
                decodedDays[dayKey] = observations
            }
            days[scopeID] = decodedDays
        }
        return HistoryEnvelope(
            version: dto.version,
            revision: dto.revision,
            days: days,
            coverage: dto.coverage
        )
    }
}

// MARK: - Filesystem seam

/// The file operations the repository needs, isolated so tests can inject
/// deterministic failures (read-only destination, full disk, missing
/// directory). The default implementation is a thin FileManager wrapper.
public protocol HistoryFilesystem: Sendable {
    func exists(at url: URL) -> Bool
    func read(_ url: URL) throws -> Data
    func createDirectory(at url: URL) throws
    func write(_ data: Data, to url: URL) throws
    func replaceItem(at destination: URL, with source: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [String]
}

/// Default seam: straight FileManager calls.
public struct FileManagerHistoryFilesystem: HistoryFilesystem {
    public init() {}
    public func exists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func write(_ data: Data, to url: URL) throws { try data.write(to: url) }
    public func replaceItem(at destination: URL, with source: URL) throws {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    }
    public func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
    public func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    public func contentsOfDirectory(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }
}

// MARK: - Retention policy

/// §7.3 storage bounds. A namespace enum, not configuration: these are
/// contract constants, not tunables.
public enum HistoryRetention {
    /// At most one ordinary observation per five-minute bucket; first/last
    /// and policy-change boundaries are always retained.
    public static let coalesceBucket: TimeInterval = 300
    /// Per-day observation cap.
    public static let maxObservationsPerDay = 320
    /// Active history window in gateway days.
    public static let retentionDays = 90
    /// Serialized active-envelope size budget.
    public static let maxEnvelopeBytes = 2 * 1024 * 1024
    /// In-memory recent-reading buffer: the last 60 minutes of accepted
    /// readings, capped at 800 (§7.3, recent-rate support).
    public static let recentWindow: TimeInterval = 3600
    public static let recentBufferCap = 800
}

/// Internal (package-visible for tests) pure retention/coalescing logic.
enum HistoryRetentionEngine {
    /// Whether two observations carry different limit-policy context —
    /// a boundary the coalescer must never collapse away.
    static func isPolicyBoundary(_ a: Observation, _ b: Observation) -> Bool {
        a.limitEnabled != b.limitEnabled || a.limitUSD != b.limitUSD
    }

    /// Applies five-minute coalescing when appending `new` to an existing
    /// receipt-ordered day. Returns the retained list. Rules (§7.3):
    /// keep the day's first observation, keep the latest observation, keep
    /// both sides of a policy-change boundary; otherwise only the latest
    /// ordinary observation per five-minute bucket survives.
    static func appending(_ new: Observation, to day: [Observation]) -> [Observation] {
        guard let last = day.last else { return [new] }
        guard let first = day.first else { return [new] }
        if isPolicyBoundary(last, new) { return day + [new] }
        let bucket = Int(new.receivedAt.timeIntervalSince1970) / Int(HistoryRetention.coalesceBucket)
        let lastBucket = Int(last.receivedAt.timeIntervalSince1970) / Int(HistoryRetention.coalesceBucket)
        guard bucket == lastBucket, day.count > 1, last.id != first.id else {
            return day + [new]
        }
        // The previous latest is an ordinary observation in the same bucket
        // — unless it itself sits on a policy boundary with its predecessor.
        let previous = day[day.count - 2]
        if isPolicyBoundary(previous, last) { return day + [new] }
        var result = day
        result[result.count - 1] = new
        return result
    }

    /// Enforces the per-day cap by dropping the oldest ORDINARY
    /// observations first; first/last, policy boundaries, and MARKER
    /// boundaries are preserved even when the day stays over cap (§7.3:
    /// reduced chart resolution is reported via coverage, boundaries are
    /// never silently dropped).
    static func capped(_ day: [Observation], markerIDs: Set<UUID>) -> [Observation] {
        var result = day
        while result.count > HistoryRetention.maxObservationsPerDay {
            guard let victim = oldestOrdinaryIndex(in: result, markerIDs: markerIDs) else { break }
            result.remove(at: victim)
        }
        return result
    }

    /// Back-compat overload (no marker context).
    static func capped(_ day: [Observation]) -> [Observation] {
        capped(day, markerIDs: [])
    }

    /// Index of the oldest droppable observation: not the first, not the
    /// last, not either side of a policy-change or marker boundary.
    private static func oldestOrdinaryIndex(in day: [Observation], markerIDs: Set<UUID>) -> Int? {
        guard day.count > 2 else { return nil }
        for i in 1..<(day.count - 1) {
            if isPolicyBoundary(day[i - 1], day[i]) { continue }
            if isPolicyBoundary(day[i], day[i + 1]) { continue }
            if markerIDs.contains(day[i].id) { continue }
            return i
        }
        return nil
    }

    /// Coverage for one day, honestly reflecting gaps: a legacy-hour day is
    /// "complete" only when all 24 hour slots were observed; an exact day is
    /// complete when receipt coverage spans the whole billing day.
    static func coverage(dayKey: String, observations: [Observation]) -> HistoryEnvelope.Coverage {
        guard !observations.isEmpty else {
            return HistoryEnvelope.Coverage(dayKey: dayKey, firstObservationAt: nil, lastObservationAt: nil, isComplete: false)
        }
        let first = observations.first!.receivedAt
        let last = observations.last!.receivedAt
        let isComplete: Bool
        if observations.allSatisfy({ $0.precision == .legacyHour }) {
            let hours = Set(observations.map {
                Int(($0.receivedAt.timeIntervalSince1970 / 3600).rounded(.down))
            })
            isComplete = hours.count >= 24
        } else if let midnight = GatewayDay(spendDate: dayKey)?.startOfDayUTC {
            isComplete = first <= midnight + 300 && last >= midnight + 86_400 - 300
        } else {
            isComplete = false
        }
        return HistoryEnvelope.Coverage(dayKey: dayKey, firstObservationAt: first, lastObservationAt: last, isComplete: isComplete)
    }
}

// MARK: - HistoryRepository

/// Serial owner of the on-disk history. All mutations and writes happen
/// inside the actor, so revision ordering is guaranteed by construction and
/// no file I/O ever runs on the main actor.
public actor HistoryRepository {
    /// What a load attempt found on disk. Recoverable states surface here
    /// instead of being swallowed (B13): the caller can render a storage
    /// status rather than mistaking corruption for "no history".
    public enum LoadStatus: Equatable, Sendable {
        /// No history file exists yet — the normal first-run state.
        case empty
        /// A schema-2 envelope loaded as-is.
        case loaded
        /// A legacy schema-1 file was migrated; the byte-preserving backup
        /// of the original bytes lives at the given path.
        case migratedFromLegacy(backupFileName: String)
        /// The file was corrupt; the original bytes are retained and a copy
        /// was quarantined. The repository starts from an empty envelope.
        case corruptRetained(quarantineFileName: String?)
        /// The file could not be read at all; original file untouched.
        case unreadable(reason: String)
    }

    /// The result of appending one observation.
    public struct AppendOutcome: Equatable, Sendable {
        /// True when the reading corrected the day's cumulative amount
        /// downward beyond restatement tolerance. The correction IS stored
        /// (honest data), but consumers must treat it as a discontinuity and
        /// reset comparable burn/marker baselines — never derive a negative
        /// burn from the pair. The value itself is the mark; no fabricated
        /// flag is persisted.
        public let isDownwardCorrection: Bool
    }

    public enum SaveError: Error, Equatable, Sendable {
        case encodeFailed
        case writeFailed(String)
    }

    public static let activeFileName = "history.json"
    public static let legacyBackupFileName = "history-legacy-backup.json"
    public static let quarantineDirectoryName = "history-quarantine"
    private static let tempFilePrefix = "history.json.tmp-"

    /// The directory history.json lives in (exposed for callers/tests that
    /// need to inspect the file the actor manages).
    public let directory: URL
    private let filesystem: any HistoryFilesystem

    private var days: [String: [String: [Observation]]] = [:]
    private var revision: UInt64 = 0
    private var lastWrittenRevision: UInt64 = 0
    private(set) var dirty = false
    private var recent: [Observation] = []
    // WP-09 marker store: pending markers and bounded receipts, persisted
    // to a separate markers.json (see SpendMarker.swift for the decision).
    // Serial-actor ownership gives the same revision safety as history.
    private var pendingMarkers: [PendingMarker] = []
    private var markerReceipts: [MarkerReceipt] = []
    private var markerFileDirty = false
    /// The last surfaced error, so callers can render a storage status
    /// instead of the error vanishing into a `try?` (B13).
    public private(set) var lastError: String?

    public init(directory: URL, filesystem: any HistoryFilesystem = FileManagerHistoryFilesystem()) {
        self.directory = directory
        self.filesystem = filesystem
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.activeFileName) }
    private var backupURL: URL { directory.appendingPathComponent(Self.legacyBackupFileName) }

    /// The current in-memory envelope view.
    public var envelope: HistoryEnvelope {
        HistoryEnvelope(revision: revision, days: days, coverage: coverageMap())
    }

    /// Bounded in-memory buffer of accepted readings from the last 60
    /// minutes (§7.3). In-memory only; after relaunch projections stay
    /// unavailable until restored + new samples meet coverage gates.
    public var recentReadings: [Observation] { recent }

    /// Appends one observation. Receipt order is preserved within the
    /// declared billing day (an after-midnight reading for the previous
    /// gateway day is appended to THAT day, never moved to the clock day
    /// and never written into the day's earliest slot — B01).
    @discardableResult
    public func append(_ observation: Observation) -> AppendOutcome {
        let scopeID = observation.scope.opaqueID.uuidString
        let dayKey = observation.gatewayDay.key
        var scopeDays = days[scopeID] ?? [:]
        let existing = scopeDays[dayKey] ?? []

        // Downward-correction detection mirrors the legacy running-max
        // tolerance: cumulative spend never decreases within a gateway day
        // beyond max(1% of the day's peak, $0.50). After a real correction
        // the peak stays authoritative, so readings below it keep flagging
        // until spend recovers past it — derived views must reset their
        // comparable baselines for the whole post-correction span. The
        // correction IS STORED, marked in the outcome — the day is not
        // erased and no negative burn is invented.
        let peak = existing.map(\.cumulativeAmount).max()
        var isCorrection = false
        if let peak, observation.cumulativeAmount < peak - max(peak * 0.01, 0.50) {
            isCorrection = true
            repositoryLog.notice("downward correction for \(scopeID, privacy: .public)/\(dayKey, privacy: .public): peak \(peak, privacy: .public) -> \(observation.cumulativeAmount, privacy: .public)")
        }

        var updated = HistoryRetentionEngine.appending(observation, to: existing)
        updated = HistoryRetentionEngine.capped(updated, markerIDs: markerBoundaryIDs)
        scopeDays[dayKey] = updated
        days[scopeID] = scopeDays
        pruneScopesToRetentionWindow()

        recent.append(observation)
        let cutoff = observation.receivedAt.addingTimeInterval(-HistoryRetention.recentWindow)
        recent = recent.filter { $0.receivedAt >= cutoff }
        if recent.count > HistoryRetention.recentBufferCap {
            recent.removeFirst(recent.count - HistoryRetention.recentBufferCap)
        }

        revision &+= 1
        dirty = true
        return AppendOutcome(isDownwardCorrection: isCorrection)
    }

    /// Reads observations for one scope/day in receipt order.
    public func observations(scope: UsageScope, day: GatewayDay) -> [Observation] {
        days[scope.opaqueID.uuidString]?[day.key] ?? []
    }

    /// Loads history.json, migrating a legacy schema-1 file when found.
    /// Never throws: every failure mode is a `LoadStatus`, the original
    /// file is always retained, and a failed load leaves an empty in-memory
    /// envelope rather than half-applied state.
    @discardableResult
    public func load() -> LoadStatus {
        lastError = nil
        days = [:]
        recent = []
        revision = 0
        lastWrittenRevision = 0
        dirty = false
        // Markers load with the history: a relaunch without loadMarkers()
        // would forget pending markers/receipts even though they persisted.
        loadMarkers()

        cleanupOrphanedTempFiles()

        guard filesystem.exists(at: fileURL) else { return .empty }

        let raw: Data
        do {
            raw = try filesystem.read(fileURL)
        } catch {
            lastError = "read failed: \(error.localizedDescription)"
            return .unreadable(reason: error.localizedDescription)
        }

        switch HistoryMigration.plan(raw) {
        case .alreadyCurrent(let envelope):
            days = envelope.days
            revision = envelope.revision
            lastWrittenRevision = envelope.revision
            return .loaded

        case .migrateLegacy(let envelope, let quarantined):
            // Byte-preserving backup BEFORE writing schema 2 (§7.3). At most
            // one backup: an existing backup is never overwritten, so a
            // re-run after interruption cannot churn it.
            var backupFailed: String?
            if !filesystem.exists(at: backupURL) {
                do {
                    try filesystem.createDirectory(at: directory)
                    try filesystem.copyItem(at: fileURL, to: backupURL)
                } catch {
                    // §7.3/02.3: the byte-preserving backup is a hard
                    // precondition for migration. Without it, saving schema 2
                    // would replace the sole legacy file — refuse to
                    // migrate and leave everything exactly as it was.
                    backupFailed = "legacy backup failed: \(error.localizedDescription)"
                    repositoryLog.error("\(backupFailed ?? "backup failed", privacy: .public)")
                }
            }
            if let backupFailed {
                lastError = backupFailed
                // Nothing written, nothing quarantined: the legacy file is
                // the only good copy and stays untouched. In-memory state
                // stays empty; the next launch retries the same migration.
                return .unreadable(reason: backupFailed)
            }
            persistQuarantine(quarantined)
            days = envelope.days
            revision = envelope.revision
            dirty = true
            do {
                try save()
            } catch {
                // Migration write failed: the legacy file is untouched
                // (atomic temp+swap), the backup/quarantine survive, and the
                // next launch re-derives the same plan. In-memory data stays.
                lastError = "migration save failed: \(error.localizedDescription)"
            }
            return .migratedFromLegacy(backupFileName: Self.legacyBackupFileName)

        case .corrupt(let reason):
            // Retain the original file; quarantine a byte copy for forensic
            // recovery; start empty. The next successful save replaces the
            // corrupt file atomically.
            let quarantineName = persistCorruptCopy(raw: raw, reason: reason)
            lastError = "corrupt history: \(reason)"
            return .corruptRetained(quarantineFileName: quarantineName)
        }
    }

    /// Writes the current envelope atomically (temp file + swap). Revision
    /// ordering: a save that carries no new revision is a no-op, so two
    /// rapid saves can never regress disk state to an older envelope.
    /// Writes are synchronous inside the actor — strictly serialized.
    public func save() throws {
        guard dirty, revision > lastWrittenRevision else { return }
        do {
            try filesystem.createDirectory(at: directory)
        } catch {
            lastError = "create directory failed: \(error.localizedDescription)"
            throw SaveError.writeFailed(error.localizedDescription)
        }

        var encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data: Data
        do {
            data = try envelope.encodedForPersistence(using: encoder)
        } catch {
            lastError = "encode failed: \(error.localizedDescription)"
            throw SaveError.encodeFailed
        }

        // §7.3 size budget: coarsen oldest ordinary observations, then drop
        // oldest complete day records, before committing an oversized file.
        if data.count > HistoryRetention.maxEnvelopeBytes {
            shrinkToFitBudget(encoder: encoder)
            data = (try? envelope.encodedForPersistence(using: encoder)) ?? data
        }

        let tempURL = directory.appendingPathComponent("\(Self.tempFilePrefix)\(UUID().uuidString)")
        do {
            try filesystem.write(data, to: tempURL)
            try filesystem.replaceItem(at: fileURL, with: tempURL)
        } catch {
            // Never leave an orphaned temp file behind on a failed swap.
            try? filesystem.removeItem(at: tempURL)
            lastError = "write failed: \(error.localizedDescription)"
            throw SaveError.writeFailed(error.localizedDescription)
        }
        lastWrittenRevision = revision
        dirty = false
        lastError = nil
        // Marker store piggybacks on every history flush (WP-09): one
        // persist point, marker file stays fresh without touching app
        // call sites. Independent dirty flag keeps it a cheap no-op
        // when no marker changed.
        try? saveMarkers()
    }

    // MARK: - Marker store (WP-09)

    public static let markerFileName = "markers.json"
    private static let markerTempPrefix = "markers.json.tmp-"
    /// §6.1 local-data contract: at most 100 marker receipts.
    public static let maxMarkerReceipts = 100

    private var markerFileURL: URL {
        directory.appendingPathComponent(Self.markerFileName)
    }

    public var pendingMarkersList: [PendingMarker] { pendingMarkers }
    public var markerReceiptsList: [MarkerReceipt] { markerReceipts }
    /// Marker boundary observations pinned against coalescing/pruning.
    public var markerBoundaryIDs: Set<UUID> {
        var ids = Set<UUID>()
        for pending in pendingMarkers { ids.insert(pending.startObservation.id) }
        for receipt in markerReceipts {
            ids.insert(receipt.startObservation.id)
            if let end = receipt.endObservation { ids.insert(end.id) }
        }
        return ids
    }

    /// Records a marker start. The marker's start observation is pinned
    /// against per-day cap/coalescing so the baseline can never silently
    /// disappear from the day's retained list (WP-02's coalescing note).
    public func startMarker(_ marker: PendingMarker) {
        guard !pendingMarkers.contains(where: { $0.id == marker.id }) else { return }
        // One pending marker at a time per scope: a new start replaces the
        // previous unfinished one (the receipt list keeps its history).
        pendingMarkers.removeAll { $0.scope == marker.scope }
        pendingMarkers.append(marker)
        markerFileDirty = true
    }

    /// Finishes a pending marker with an ACCEPTED end observation. The
    /// engine decides comparability; an invalid end leaves the marker
    /// pending and returns nil (the caller surfaces why via the engine's
    /// rules — same scope/day required for a measured delta).
    @discardableResult
    public func finishMarker(id: UUID, end: Observation) -> MarkerReceipt? {
        guard let index = pendingMarkers.firstIndex(where: { $0.id == id }) else { return nil }
        let pending = pendingMarkers[index]
        // Intermediates: accepted observations strictly between the start
        // and the end within the start day — the correction scan series.
        let dayObservations = observations(
            scope: pending.scope, day: pending.startObservation.gatewayDay)
        let intermediates = dayObservations.filter {
            $0.receivedAt > pending.startObservation.receivedAt && $0.receivedAt < end.receivedAt
        }
        guard let receipt = SpendMarker.finishReceipt(
            pending: pending, end: end, intermediates: intermediates) else { return nil }

        pendingMarkers.remove(at: index)
        markerReceipts.append(receipt)
        if markerReceipts.count > Self.maxMarkerReceipts {
            markerReceipts.removeFirst(markerReceipts.count - Self.maxMarkerReceipts)
        }
        markerFileDirty = true
        return receipt
    }

    /// Cancels a pending marker without a receipt.
    public func cancelMarker(id: UUID) {
        guard let index = pendingMarkers.firstIndex(where: { $0.id == id }) else { return }
        pendingMarkers.remove(at: index)
        markerFileDirty = true
    }

    /// Loads markers.json. Never throws; a structurally unusable file is
    /// retained in place (renamed .unusable) and the store starts empty —
    /// the same forensic policy the corrupt-history path follows.
    public func loadMarkers() {
        pendingMarkers = []
        markerReceipts = []
        markerFileDirty = false
        guard filesystem.exists(at: markerFileURL) else { return }
        guard let raw = try? filesystem.read(markerFileURL) else { return }
        guard let decoded = MarkerStoreDTO.decode(raw) else {
            let unusable = directory.appendingPathComponent(Self.markerFileName + ".unusable")
            if !filesystem.exists(at: unusable) {
                try? filesystem.copyItem(at: markerFileURL, to: unusable)
            }
            repositoryLog.error("unusable markers.json retained as .unusable")
            return
        }
        pendingMarkers = decoded.pending
        markerReceipts = decoded.receipts
    }

    /// Writes markers.json atomically when dirty. Independent of history
    /// saves — a marker commit must not force a history revision bump.
    public func saveMarkers() throws {
        guard markerFileDirty else { return }
        do {
            try filesystem.createDirectory(at: directory)
        } catch {
            lastError = "create directory failed: \(error.localizedDescription)"
            throw SaveError.writeFailed(error.localizedDescription)
        }
        let data: Data
        do {
            data = try MarkerStoreDTO.encode(pending: pendingMarkers, receipts: markerReceipts)
        } catch {
            lastError = "marker encode failed: \(error.localizedDescription)"
            throw SaveError.encodeFailed
        }
        let tempURL = directory.appendingPathComponent("\(Self.markerTempPrefix)\(UUID().uuidString)")
        do {
            try filesystem.write(data, to: tempURL)
            try filesystem.replaceItem(at: markerFileURL, with: tempURL)
        } catch {
            try? filesystem.removeItem(at: tempURL)
            lastError = "marker write failed: \(error.localizedDescription)"
            throw SaveError.writeFailed(error.localizedDescription)
        }
        markerFileDirty = false
        lastError = nil
    }

    // MARK: - Explorer listing (WP-09)

    /// All (scopeID, dayKey) pairs currently retained, for the explorer's
    /// navigation list. Sorted: scope ID, then canonical day key.
    public struct DayListing: Equatable, Sendable {
        public let scope: UsageScope
        public let day: GatewayDay
        public let observationCount: Int
        public let coverage: HistoryEnvelope.Coverage
    }

    public func dayListings() -> [DayListing] {
        var result: [DayListing] = []
        for scopeID in days.keys.sorted() {
            guard let scopeDays = days[scopeID],
                  let firstObservation = scopeDays.values.flatMap({ $0 }).first else { continue }
            let scope = firstObservation.scope
            for dayKey in scopeDays.keys.sorted() {
                guard let day = GatewayDay(spendDate: dayKey),
                      let dayObservations = scopeDays[dayKey] else { continue }
                result.append(DayListing(
                    scope: scope,
                    day: day,
                    observationCount: dayObservations.count,
                    coverage: scopeDays[dayKey].map {
                        HistoryRetentionEngine.coverage(dayKey: dayKey, observations: $0)
                    } ?? HistoryEnvelope.Coverage(
                        dayKey: dayKey, firstObservationAt: nil, lastObservationAt: nil, isComplete: false)
                ))
            }
        }
        return result
    }

    /// The most recent observation per scope (the "latest" the explorer
    /// opens on). Nil for unknown scopes.
    public func latestObservation(scope: UsageScope) -> Observation? {
        let scopeDays = days[scope.opaqueID.uuidString] ?? [:]
        guard let newestDay = scopeDays.keys.sorted().last,
              let list = scopeDays[newestDay] else { return nil }
        return list.last
    }

    /// The latest observation of ONE selected day for a scope (the marker
    /// start baseline must anchor the day the user is looking at, not the
    /// scope's newest day). Nil for unknown scope/day.
    public func latestObservation(scope: UsageScope, day: GatewayDay) -> Observation? {
        days[scope.opaqueID.uuidString]?[day.key]?.last
    }

    /// Deletes ALL history data for one scope (data control, 09.3). The
    /// caller owns the explicit confirmation UI; the actor owns the state.
    public func clearHistory(scope: UsageScope) {
        days.removeValue(forKey: scope.opaqueID.uuidString)
        pendingMarkers.removeAll { $0.scope == scope }
        markerReceipts.removeAll { $0.scope == scope }
        revision &+= 1
        dirty = true
        markerFileDirty = true
    }

    // MARK: - internals

    private func coverageMap() -> [String: [String: HistoryEnvelope.Coverage]] {
        days.mapValues { scopeDays in
            Dictionary(uniqueKeysWithValues: scopeDays.map { dayKey, observations in
                (dayKey, HistoryRetentionEngine.coverage(dayKey: dayKey, observations: observations))
            })
        }
    }

    /// Deterministic day pruning: day keys are canonical "yyyy-MM-dd" labels,
    /// so lexicographic order IS chronological order. Oldest days drop first.
    private func pruneScopesToRetentionWindow() {
        for scopeID in days.keys {
            let scopeDays = days[scopeID] ?? [:]
            guard scopeDays.count > HistoryRetention.retentionDays else { continue }
            let keep = Set(scopeDays.keys.sorted().suffix(HistoryRetention.retentionDays))
            days[scopeID] = scopeDays.filter { keep.contains($0.key) }
        }
    }

    /// Shrinks the in-memory envelope until it encodes under the 2 MiB
    /// budget: coarsen oldest ordinary observations across the oldest days
    /// first, then drop the oldest complete day records (§7.3). Never
    /// touches the current gateway day.
    private func shrinkToFitBudget(encoder: JSONEncoder) {
        func encodedSize() -> Int {
            ((try? envelope.encodedForPersistence(using: encoder))?.count) ?? Int.max
        }
        // Pass 1: halve the density of the oldest days (drop every second
        // ordinary observation) until under budget.
        while encodedSize() > HistoryRetention.maxEnvelopeBytes {
            var changed = false
            for scopeID in days.keys.sorted() {
                for dayKey in (days[scopeID] ?? [:]).keys.sorted() {
                    guard var list = days[scopeID]?[dayKey], list.count > 8 else { continue }
                    var compacted: [Observation] = []
                    for (i, observation) in list.enumerated() {
                        let isBoundary = i == 0 || i == list.count - 1
                            || HistoryRetentionEngine.isPolicyBoundary(list[max(0, i - 1)], observation)
                            || (i + 1 < list.count && HistoryRetentionEngine.isPolicyBoundary(observation, list[i + 1]))
                        if isBoundary || i % 2 == 0 { compacted.append(observation) }
                    }
                    if compacted.count < list.count {
                        days[scopeID]?[dayKey] = compacted
                        changed = true
                    }
                    if encodedSize() <= HistoryRetention.maxEnvelopeBytes { return }
                }
            }
            guard changed else { break }
        }
        // Pass 2: drop the oldest complete day records outright.
        while encodedSize() > HistoryRetention.maxEnvelopeBytes {
            var oldest: (scope: String, day: String)?
            for scopeID in days.keys {
                if let day = (days[scopeID] ?? [:]).keys.sorted().first {
                    if oldest == nil || day < oldest!.day { oldest = (scopeID, day) }
                }
            }
            guard let target = oldest else { break }
            days[target.scope]?.removeValue(forKey: target.day)
            if days[target.scope]?.isEmpty == true { days.removeValue(forKey: target.scope) }
        }
    }

    /// A crash mid-write leaves `history.json.tmp-*` behind; drop any on
    /// load so orphans never accumulate.
    private func cleanupOrphanedTempFiles() {
        guard filesystem.exists(at: directory),
              let entries = try? filesystem.contentsOfDirectory(at: directory) else { return }
        for entry in entries where entry.hasPrefix(Self.tempFilePrefix) || entry.hasPrefix(Self.markerTempPrefix) {
            try? filesystem.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// Persists per-record quarantine entries as one JSON array file inside
    /// history-quarantine/. Appends across migrations so nothing uncertain
    /// is ever irreversibly deleted (§7.3).
    private func persistQuarantine(_ records: [HistoryMigration.QuarantinedRecord]) {
        guard !records.isEmpty else { return }
        let quarantineDir = directory.appendingPathComponent(Self.quarantineDirectoryName)
        let quarantineFile = quarantineDir.appendingPathComponent("records.json")
        struct Entry: Codable, Hashable {
            var reason: String
            var originalKey: String
            var payload: String
        }
        var entries: [Entry] = []
        if filesystem.exists(at: quarantineFile), let existing = try? filesystem.read(quarantineFile),
           let decoded = try? JSONDecoder().decode([Entry].self, from: existing) {
            entries = decoded
        }
        let new = records.map { Entry(reason: $0.reason.rawValue, originalKey: $0.originalKey, payload: $0.payload) }
        // Idempotence: a retry after a failed schema-2 write re-runs the
        // same migration and re-offers the same quarantined records.
        // Deduplicate by (reason, originalKey, payload) identity, keeping
        // the FIRST occurrence and sorting deterministically, so the file
        // holds each distinct record exactly once regardless of retries.
        var seen = Set<Entry>()
        entries.append(contentsOf: new)
        entries = entries.filter { seen.insert($0).inserted }
            .sorted { ($0.reason, $0.originalKey, $0.payload) < ($1.reason, $1.originalKey, $1.payload) }
        do {
            try filesystem.createDirectory(at: quarantineDir)
            let data = try JSONEncoder().encode(entries)
            try filesystem.write(data, to: quarantineFile)
        } catch {
            repositoryLog.error("quarantine persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies the raw corrupt bytes into history-quarantine/ (the original
    /// file itself is retained in place).
    private func persistCorruptCopy(raw: Data, reason: String) -> String? {
        let quarantineDir = directory.appendingPathComponent(Self.quarantineDirectoryName)
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "corrupt-\(stamp).json"
        do {
            try filesystem.createDirectory(at: quarantineDir)
            try filesystem.write(raw, to: quarantineDir.appendingPathComponent(name))
            return "\(Self.quarantineDirectoryName)/\(name)"
        } catch {
            repositoryLog.error("corrupt-copy quarantine failed: \(error.localizedDescription, privacy: .public); reason was \(reason, privacy: .public)")
            return nil
        }
    }
}
