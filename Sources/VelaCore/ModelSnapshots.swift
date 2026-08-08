// Sources/VelaCore/ModelSnapshots.swift
// Persists per-gateway-day snapshots of the month-cumulative top_models
// payload, so TodayModelSplitEngine can difference yesterday's snapshot
// against the current response and derive TODAY's per-model spend.
// Why: the API only reports month-cumulative per-model figures. Without a
// stored baseline from one gateway-day ago, "today by model" is not
// derivable at all — this store is the memory that makes the split possible.
// RELEVANT FILES: Tests/VelaCoreTests/ModelSnapshotsTests.swift, Sources/VelaCore/TodayModelSplit.swift, Sources/VelaCore/HistoryStore.swift

import Foundation
import OSLog

private let snapshotsLog = Logger(subsystem: "com.nsxbet.velaishtar", category: "ModelSnapshots")

/// One model's month-cumulative position at snapshot time.
public struct ModelPoint: Codable, Equatable, Sendable {
    public let costUSD: Double
    public let tokens: Int

    public init(costUSD: Double, tokens: Int) {
        self.costUSD = costUSD
        self.tokens = tokens
    }
}

/// The month-cumulative top_models payload captured on one gateway day.
/// `monthKey` ("yyyy-MM") is derived from spend_date so the split engine can
/// reject a cross-month pair without re-parsing dates.
public struct ModelSnapshot: Codable, Equatable, Sendable {
    public let monthKey: String
    public let monthTotalUSD: Double
    public let models: [String: ModelPoint]
    public let capturedAt: Date

    public init(monthKey: String, monthTotalUSD: Double, models: [String: ModelPoint], capturedAt: Date) {
        self.monthKey = monthKey
        self.monthTotalUSD = monthTotalUSD
        self.models = models
        self.capturedAt = capturedAt
    }
}

/// On-disk store of ModelSnapshots, keyed by gateway spend_date. Mirrors
/// HistoryStore's idioms: injectable directory, tmp+rename atomic save, and
/// a pruned key set so the file never grows unboundedly.
public struct ModelSnapshots: Sendable {
    /// Only the most recent few days matter for a "yesterday's baseline"
    /// lookup; older snapshots are dead weight, so the store self-prunes.
    /// Because the split is computed BEFORE `record` overwrites today's key,
    /// yesterday's snapshot is present at lookup time even at a small cap.
    /// The true minimum is 2 (probe-verified): a REPEAT poll on day D
    /// recomputes the split, and at cap 1 day D's own first record has
    /// already evicted D−1, so the repeat would read no baseline. Cap 2 keeps
    /// {D−1, D}, so repeated same-day polls keep splitting. Seven is not a
    /// defect fix (#15); it's cheap defense-in-depth — a one-week bounded
    /// history for diagnostics and forward-compatibility, at negligible file
    /// size.
    static let maxKeys = 7

    private let directory: URL
    private let retentionLimit: Int
    private var snapshots: [String: ModelSnapshot] = [:]

    private var fileURL: URL {
        directory.appendingPathComponent("snapshots.json")
    }

    /// `directory` is injectable so app and tests can control persistence.
    public init(directory: URL) {
        self.init(directory: directory, maxKeys: Self.maxKeys)
    }

    /// Test-only retention override. Production uses the public initializer,
    /// which always preserves the shipped seven-key default.
    init(directory: URL, maxKeys: Int) {
        self.directory = directory
        self.retentionLimit = maxKeys
    }

    /// The snapshot recorded under a given gateway spend_date. The query
    /// key is normalized first, so a lookup with "2026-08-10" and one with
    /// "2026-08-10T00:00:00Z" hit the same record.
    public func snapshot(for spendDate: String) -> ModelSnapshot? {
        snapshots[ISODate.dayKey(spendDate)]
    }

    /// Captures a response's month-cumulative top_models under the GATEWAY's
    /// day key (the canonical bare form of spend_date — never the local
    /// clock's date). The month key is derived via TodayModelSplitEngine.monthKey
    /// so a bare "2026-08-10" and a full-ISO "2026-08-10T00:00:00Z" land
    /// identically — and the day key normalizes through ISODate.dayKey so one
    /// logical day is never split across two records.
    public mutating func record(_ usage: UsageResponse, at date: Date) {
        guard let monthKey = TodayModelSplitEngine.monthKey(of: usage.dailyBudget.spendDate) else {
            snapshotsLog.notice("skipped snapshot: unparseable spend_date \(usage.dailyBudget.spendDate, privacy: .public)")
            return
        }
        var models: [String: ModelPoint] = [:]
        for model in usage.topModels {
            models[model.model] = ModelPoint(costUSD: model.totalCostUSD, tokens: model.totalTokens)
        }
        snapshots[ISODate.dayKey(usage.dailyBudget.spendDate)] = ModelSnapshot(
            monthKey: monthKey,
            monthTotalUSD: usage.currentMonth.totalCostUSD,
            models: models,
            capturedAt: date
        )
        prune()
    }

    /// The snapshot exactly one gateway-day before `spendDate`, or nil.
    /// Why strict adjacency: the split differences baseline against current
    /// and calls the result "today". A baseline from two days ago would fold
    /// yesterday's spend into "today" — a confident lie — so a gap in
    /// recording (app off over the seam) must surface as "no baseline", not
    /// as a silently wrong split. Adjacency is CALENDAR-day math on the LABEL
    /// (via GatewayDay), so a non-UTC-midnight spend_date ("2026-08-10T00:00:
    /// 00+03:00") compares as its labelled day — never the UTC instant's day —
    /// and "2026-07-31" is adjacent to "2026-08-01" (the split engine's own
    /// monthChanged guard rejects that pair downstream).
    public func baseline(before spendDate: String) -> ModelSnapshot? {
        guard let today = GatewayDay(spendDate: spendDate),
              let yesterday = today.previous() else { return nil }
        return snapshots[yesterday.key]
    }

    /// Keeps only the most recent `retentionLimit` day keys. Keys are canonical
    /// "yyyy-MM-dd" (record normalizes, load migrates), so a lexicographic
    /// descending sort IS chronological order — prefix keeps the newest.
    private mutating func prune() {
        let keys = snapshots.keys.sorted(by: >)
        guard keys.count > retentionLimit else { return }
        for key in keys.dropFirst(retentionLimit) {
            snapshots.removeValue(forKey: key)
        }
    }

    /// Loads snapshots.json. A missing file is the normal first-run state,
    /// not an error — the store stays empty rather than throwing.
    public mutating func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            snapshots = [:]
            return
        }
        let data = try Data(contentsOf: fileURL)
        var decoded = try JSONDecoder().decode([String: ModelSnapshot].self, from: data)

        // Migrate pre-normalization keys: a full-ISO day key
        // ("2026-08-07T00:00:00Z") is re-keyed to its bare day form. On a
        // collision (both shapes recorded for one logical day) keep the
        // snapshot with the later capturedAt — it reflects the later poll.
        var migrated = false
        for key in decoded.keys {
            let bare = ISODate.dayKey(key)
            guard bare != key, let isoSnapshot = decoded[key] else { continue }
            decoded.removeValue(forKey: key)
            if let existing = decoded[bare], existing.capturedAt >= isoSnapshot.capturedAt {
                // Existing bare-keyed snapshot is newer — drop the ISO one.
            } else {
                decoded[bare] = isoSnapshot
            }
            migrated = true
            snapshotsLog.notice("migrated snapshot key \(key, privacy: .public) -> \(bare, privacy: .public)")
        }

        // Recompute each persisted monthKey from its (now normalized) day
        // label. Pre-GatewayDay, monthKey was derived by parsing spend_date as
        // an INSTANT, so a non-UTC-midnight label was stored with the wrong
        // month ("2026-08-01T00:00:00+03:00" → "2026-07"). Left stale, the
        // split bails monthChanged against a valid baseline the day after a
        // month seam. Re-deriving from the label keeps the persisted file
        // honest; the snapshot is immutable, so rebuild the value.
        for (key, snapshot) in decoded {
            guard let correct = GatewayDay(spendDate: key)?.monthKey(),
                  correct != snapshot.monthKey else { continue }
            decoded[key] = ModelSnapshot(
                monthKey: correct,
                monthTotalUSD: snapshot.monthTotalUSD,
                models: snapshot.models,
                capturedAt: snapshot.capturedAt
            )
            migrated = true
            snapshotsLog.notice("recomputed snapshot monthKey \(snapshot.monthKey, privacy: .public) -> \(correct, privacy: .public) for \(key, privacy: .public)")
        }

        snapshots = decoded
        prune()
        // Persist the re-keyed store so the migration doesn't re-run (and
        // re-log) on every launch. Best-effort.
        if migrated { try? save() }
    }

    /// Saves to snapshots.json, creating `directory` if needed. Temp-file +
    /// rename so a crash mid-write never leaves a half-written file.
    public func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshots)

        let tempURL = directory.appendingPathComponent("snapshots.json.tmp-\(UUID().uuidString)")
        try data.write(to: tempURL)
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
