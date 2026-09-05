// Sources/VelaCore/HistoryRepository.swift
// The schema-2 history container (HistoryEnvelope) plus the serial actor
// (HistoryRepository) that owns all load/encode/save for it.
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
/// names, cases, and semantics are unchanged. Codable was added for
/// persistence.
public struct HistoryEnvelope: Equatable, Sendable, Codable {
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
    /// observations first; first/last and policy boundaries are preserved
    /// even when the day stays over cap (§7.3: reduced chart resolution is
    /// reported via coverage, boundaries are never silently dropped).
    static func capped(_ day: [Observation]) -> [Observation] {
        var result = day
        while result.count > HistoryRetention.maxObservationsPerDay {
            guard let victim = oldestOrdinaryIndex(in: result) else { break }
            result.remove(at: victim)
        }
        return result
    }

    /// Index of the oldest droppable observation: not the first, not the
    /// last, not either side of a policy-change boundary.
    private static func oldestOrdinaryIndex(in day: [Observation]) -> Int? {
        guard day.count > 2 else { return nil }
        for i in 1..<(day.count - 1) {
            if isPolicyBoundary(day[i - 1], day[i]) { continue }
            if isPolicyBoundary(day[i], day[i + 1]) { continue }
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
        updated = HistoryRetentionEngine.capped(updated)
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
            if !filesystem.exists(at: backupURL) {
                do {
                    try filesystem.createDirectory(at: directory)
                    try filesystem.copyItem(at: fileURL, to: backupURL)
                } catch {
                    repositoryLog.error("legacy backup failed: \(error.localizedDescription, privacy: .public)")
                }
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
            data = try encoder.encode(envelope)
        } catch {
            lastError = "encode failed: \(error.localizedDescription)"
            throw SaveError.encodeFailed
        }

        // §7.3 size budget: coarsen oldest ordinary observations, then drop
        // oldest complete day records, before committing an oversized file.
        if data.count > HistoryRetention.maxEnvelopeBytes {
            shrinkToFitBudget(encoder: encoder)
            data = (try? encoder.encode(envelope)) ?? data
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
            ((try? encoder.encode(envelope))?.count) ?? Int.max
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
        for entry in entries where entry.hasPrefix(Self.tempFilePrefix) {
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
        struct Entry: Codable {
            var reason: String
            var originalKey: String
            var payload: String
        }
        var entries: [Entry] = []
        if filesystem.exists(at: quarantineFile), let existing = try? filesystem.read(quarantineFile),
           let decoded = try? JSONDecoder().decode([Entry].self, from: existing) {
            entries = decoded
        }
        entries.append(contentsOf: records.map { Entry(reason: $0.reason.rawValue, originalKey: $0.originalKey, payload: $0.payload) })
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
