// Tests/VelaCoreTests/ModelSnapshotsTests.swift
// Verifies ModelSnapshots: the per-gateway-day persistence of month-cumulative
// top_models snapshots, and the adjacency-checked baseline lookup the split
// engine depends on.
// Why: the Today-models split is only as trustworthy as its baseline. A
// baseline that isn't exactly one gateway-day behind "today" silently
// produces a wrong split, so the adjacency rule and the round-trip fidelity
// are pinned here against a throwaway directory.
// RELEVANT FILES: Sources/VelaCore/ModelSnapshots.swift, Sources/VelaCore/TodayModelSplit.swift, Tests/VelaCoreTests/TodayModelSplitTests.swift

import Testing
import Foundation
@testable import VelaCore

struct ModelSnapshotsTests {
    // MARK: - Fixtures

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-snapshots-\(UUID().uuidString)")
        return url
    }

    private func usage(spendDate: String, monthTotal: Double, models: [(String, Double, Int)]) -> UsageResponse {
        UsageResponse(
            tokenId: "t",
            dailyBudget: DailyBudget(limitUSD: 400, spentUSD: 10, remainingUSD: 390, usedPercent: 2.5, limitEnabled: true, spendDate: spendDate),
            currentMonth: MonthStats(totalCostUSD: monthTotal, totalTokens: 1, requests: 1),
            topModels: models.map { ModelUsage(model: $0.0, totalCostUSD: $0.1, totalTokens: $0.2, requests: 1) }
        )
    }

    // MARK: - Recording and round-trip

    @Test("record stores the snapshot under the gateway spend_date key, not the local date")
    func recordKeysBySpendDate() {
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-10", monthTotal: 130, models: [("a", 70, 100)]), at: Date())
        #expect(store.snapshot(for: "2026-08-10") != nil)
        #expect(store.snapshot(for: "2026-08-11") == nil)
    }

    @Test("the stored snapshot captures the month key, month total, and per-model points")
    func recordCapturesMonthKeyTotalAndModels() {
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-10T00:00:00Z", monthTotal: 130, models: [("a", 70, 2_000_000)]), at: Date())
        let snap = store.snapshot(for: "2026-08-10T00:00:00Z")
        #expect(snap?.monthKey == "2026-08")
        #expect(snap?.monthTotalUSD == 130)
        #expect(snap?.models["a"]?.costUSD == 70)
        #expect(snap?.models["a"]?.tokens == 2_000_000)
    }

    @Test("save then load round-trips every snapshot intact")
    func saveLoadRoundTrips() throws {
        let directory = makeDirectory()
        var store = ModelSnapshots(directory: directory)
        store.record(usage(spendDate: "2026-08-09", monthTotal: 100, models: [("a", 40, 1000)]), at: Date())
        store.record(usage(spendDate: "2026-08-10", monthTotal: 130, models: [("a", 70, 2000), ("b", 5, 50)]), at: Date())
        try store.save()

        var reloaded = ModelSnapshots(directory: directory)
        try reloaded.load()
        #expect(reloaded.snapshot(for: "2026-08-09")?.monthTotalUSD == 100)
        #expect(reloaded.snapshot(for: "2026-08-10")?.models["b"]?.costUSD == 5)
    }

    @Test("load on a missing file leaves the store empty — normal first-run state")
    func loadMissingFileIsEmpty() throws {
        var store = ModelSnapshots(directory: makeDirectory())
        try store.load()
        #expect(store.snapshot(for: "2026-08-10") == nil)
    }

    @Test("save creates the directory if it doesn't exist")
    func saveCreatesDirectory() throws {
        let directory = makeDirectory().appendingPathComponent("nested")
        var store = ModelSnapshots(directory: directory)
        store.record(usage(spendDate: "2026-08-10", monthTotal: 130, models: [("a", 70, 100)]), at: Date())
        try store.save()
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshots.json").path))
    }

    // MARK: - Baseline adjacency

    @Test("baseline returns the snapshot exactly one gateway-day before today")
    func baselineFindsYesterdaysSnapshot() {
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-09", monthTotal: 100, models: [("a", 40, 100)]), at: Date())
        let baseline = store.baseline(before: "2026-08-10")
        #expect(baseline?.monthTotalUSD == 100)
    }

    @Test("a baseline two or more days behind is rejected as not adjacent (app was off over the seam)")
    func baselineRejectsAGap() {
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-08", monthTotal: 90, models: [("a", 30, 100)]), at: Date())
        #expect(store.baseline(before: "2026-08-10") == nil)
    }

    @Test("adjacency holds across a month boundary (Jul 31 → Aug 01)")
    func baselineCrossesMonthBoundary() {
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-07-31", monthTotal: 500, models: [("a", 40, 100)]), at: Date())
        // Adjacent by date even though monthKey differs — the split engine's
        // own monthChanged guard is what rejects this pair, not the lookup.
        #expect(store.baseline(before: "2026-08-01") != nil)
    }

    @Test("adjacency parses a full-ISO spend_date identically to a bare date")
    func baselineParsesFullISOSpendDate() {
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-09", monthTotal: 100, models: [("a", 40, 100)]), at: Date())
        #expect(store.baseline(before: "2026-08-10T00:00:00Z") != nil)
    }

    @Test("adjacency holds across a non-UTC-midnight label — the split finds its baseline all day")
    func baselineFindsBaselineAcrossOffsetLabel() {
        // Yesterday stored under its bare key; today arrives as the gateway's
        // "+03:00" label for Aug 10. Parsed as an INSTANT, today is Aug 9
        // 21:00 UTC, so the baseline lookup would compare Aug 9 against Aug 9
        // and find nothing (or a two-day-old snapshot) — the split stays
        // "noBaseline" all day. On the LABEL, Aug 10 is exactly one day after
        // Aug 9, so the baseline is found.
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-09", monthTotal: 100, models: [("a", 40, 100)]), at: Date())
        #expect(store.baseline(before: "2026-08-10T00:00:00+03:00")?.monthTotalUSD == 100)
    }

    @Test("no snapshot at all yields a nil baseline")
    func baselineNilWhenStoreEmpty() {
        let store = ModelSnapshots(directory: makeDirectory())
        #expect(store.baseline(before: "2026-08-10") == nil)
    }

    // MARK: - Pruning

    @Test("record prunes to the 7 most recent day keys")
    func recordPrunesToSevenMostRecent() {
        // The retention window is 7 (headroom, not a fix — see #15 and the
        // comment on maxKeys), so a full calendar week of keys always
        // survives and day 8 is the first eviction.
        var store = ModelSnapshots(directory: makeDirectory())
        for day in 5...13 {
            let key = String(format: "2026-08-%02d", day)
            store.record(usage(spendDate: key, monthTotal: Double(day * 10), models: [("a", 1, 1)]), at: Date())
        }
        #expect(store.snapshot(for: "2026-08-05") == nil)
        #expect(store.snapshot(for: "2026-08-06") == nil)
        #expect(store.snapshot(for: "2026-08-07") != nil)
        #expect(store.snapshot(for: "2026-08-12") != nil)
        #expect(store.snapshot(for: "2026-08-13") != nil)
    }

    @Test("re-recording the same day replaces the snapshot rather than duplicating it")
    func reRecordSameDayReplaces() {
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-10", monthTotal: 130, models: [("a", 70, 100)]), at: Date())
        store.record(usage(spendDate: "2026-08-10", monthTotal: 135, models: [("a", 75, 150)]), at: Date())
        #expect(store.snapshot(for: "2026-08-10")?.monthTotalUSD == 135)
    }

    @Test("five consecutive days are all retained at cap 7")
    func fiveConsecutiveDaysAreAllRetained() {
        // A pure retention test: five consecutive recorded days all survive at
        // cap 7. This is headroom, not a fix — the split only ever needs
        // yesterday, which the split-before-record ordering preserves at any
        // cap, so a weekend never broke the baseline. Friday here is simply
        // the oldest retained day, not Tuesday's baseline (Monday is).
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-07", monthTotal: 400, models: [("a", 40, 100)]), at: Date())  // Fri
        store.record(usage(spendDate: "2026-08-08", monthTotal: 410, models: [("a", 45, 110)]), at: Date())  // Sat
        store.record(usage(spendDate: "2026-08-09", monthTotal: 420, models: [("a", 50, 120)]), at: Date())  // Sun
        store.record(usage(spendDate: "2026-08-10", monthTotal: 430, models: [("a", 55, 130)]), at: Date())  // Mon
        store.record(usage(spendDate: "2026-08-11", monthTotal: 440, models: [("a", 60, 140)]), at: Date())  // Tue
        #expect(store.snapshot(for: "2026-08-07") != nil)  // oldest of five
        #expect(store.snapshot(for: "2026-08-11") != nil)  // newest
    }

    // MARK: - spend_date key normalization (v0.3.0)

    @Test("record normalizes a full-ISO spend_date to the bare day key")
    func recordNormalizesFullISOSpendDate() {
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-10T00:00:00Z", monthTotal: 130, models: [("a", 70, 100)]), at: Date())
        // One logical day, one record — reachable under either key shape.
        #expect(store.snapshot(for: "2026-08-10")?.monthTotalUSD == 130)
        #expect(store.snapshot(for: "2026-08-10T00:00:00Z")?.monthTotalUSD == 130)
    }

    @Test("baseline is found whether today is keyed bare and yesterday ISO, or vice versa")
    func baselineNormalizesMixedKeyShapes() {
        var store = ModelSnapshots(directory: makeDirectory())
        store.record(usage(spendDate: "2026-08-09T00:00:00Z", monthTotal: 100, models: [("a", 40, 100)]), at: Date())
        // Today bare, yesterday ISO → still exactly one day apart.
        #expect(store.baseline(before: "2026-08-10")?.monthTotalUSD == 100)
    }

    @Test("prune recency treats bare and ISO keys for the same day as one")
    func pruneRecencyNormalizesKeys() {
        var store = ModelSnapshots(directory: makeDirectory())
        // Eight calendar days; 08-10 appears in both shapes (one logical day).
        for day in 5...12 {
            let key = String(format: "2026-08-%02d", day)
            store.record(usage(spendDate: key, monthTotal: Double(day * 10), models: [("a", 1, 1)]), at: Date())
        }
        store.record(usage(spendDate: "2026-08-10T00:00:00Z", monthTotal: 100, models: [("a", 1, 1)]), at: Date())
        // Seven most recent logical days survive: 08-06 … 08-12. 08-05 pruned.
        #expect(store.snapshot(for: "2026-08-05") == nil)
        #expect(store.snapshot(for: "2026-08-06") != nil)
        #expect(store.snapshot(for: "2026-08-10") != nil)
        #expect(store.snapshot(for: "2026-08-12") != nil)
    }

    @Test("load migrates legacy full-ISO keys AND recomputes stale monthKeys, persisting the canonical pruned result")
    func loadRecomputesStalePersistedMonthKey() throws {
        // Pre-GatewayDay, monthKey was derived by parsing spend_date as an
        // INSTANT, so a non-UTC-midnight label was stored with the WRONG month:
        // "2026-08-01T00:00:00+03:00" persisted under that raw ISO key with
        // monthKey "2026-07". Eight legacy rows (seven raw-offset, one bare —
        // all with the wrong month) push the store past maxKeys so the FULL
        // load sequence is exercised: re-key → recompute → prune → persist.
        // (Ordering note: GatewayDay normalizes any key shape to the same
        // label, so this test cannot distinguish re-key-before-recompute from
        // the reverse — what it pins is the observable contract: canonical
        // bare keys, correct months, pruned to 7, persisted.)
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func legacy(_ monthKey: String) -> ModelSnapshot {
            ModelSnapshot(monthKey: monthKey, monthTotalUSD: 500, models: ["a": ModelPoint(costUSD: 40, tokens: 100)], capturedAt: Date())
        }
        let payload = try JSONEncoder().encode([
            "2026-07-27T00:00:00+03:00": legacy("2026-06"),
            "2026-07-28T00:00:00+03:00": legacy("2026-06"),
            "2026-07-29T00:00:00+03:00": legacy("2026-06"),
            "2026-07-30T00:00:00+03:00": legacy("2026-06"),
            "2026-07-31T00:00:00+03:00": legacy("2026-06"),
            "2026-08-01T00:00:00+03:00": legacy("2026-07"),
            "2026-08-02T00:00:00+03:00": legacy("2026-07"),
            "2026-08-03": legacy("2026-07"),
        ])
        try payload.write(to: directory.appendingPathComponent("snapshots.json"))

        var store = ModelSnapshots(directory: directory)
        try store.load()
        // The seam case in memory: recomputed month matches the label.
        #expect(store.snapshot(for: "2026-08-01")?.monthKey == "2026-08")

        // The migration must PERSIST, not just patch memory: load() saves the
        // repaired store via `try? save()`, so read the file back and confirm
        // the on-disk payload is the canonical end state — pruned to the 7
        // newest days, every key bare, every month recomputed, no raw keys.
        let persisted = try Data(contentsOf: directory.appendingPathComponent("snapshots.json"))
        let decoded = try JSONDecoder().decode([String: ModelSnapshot].self, from: persisted)
        #expect(decoded.count == 7)
        #expect(decoded["2026-07-28"]?.monthKey == "2026-07")
        #expect(decoded["2026-08-01"]?.monthKey == "2026-08")
        #expect(decoded["2026-08-03"]?.monthKey == "2026-08")
        #expect(decoded["2026-07-27"] == nil)  // pruned: oldest of eight
        #expect(decoded.keys.allSatisfy { !$0.contains("T") })  // no raw ISO key survives
    }
}
