// Tests/VelaCoreTests/PollStateMachineTests.swift
// Verifies PollStateMachine's success/failure transition rules: failure
// counting, the 2-failures-with-last-good -> .stale threshold, the
// no-last-good-yet hold at .neverFetched, counter reset on recovery, and
// that BurnBuffer/HistoryStore/exhaustedAt are fed correctly on success.
// Why: this is the one piece of poll logic dense enough to hide a bug (wrong
// threshold, wrong counter reset, or double-counting a midnight rollover as
// a real spike) -- it must be tested directly, not just eyeballed.
// RELEVANT FILES: Sources/VelaCore/PollStateMachine.swift, Sources/App/UsagePoller.swift, Sources/VelaCore/BurnBuffer.swift, Sources/VelaCore/HistoryStore.swift

import Testing
import Foundation
@testable import VelaCore

struct PollStateMachineTests {
    // A fresh, never-before-used subdirectory of the system temp dir, so
    // tests never touch a real user's history.json and never collide with
    // each other. Mirrors HistoryStoreTests.freshDirectory().
    static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaPollStateMachineTests-\(UUID().uuidString)")
    }

    // A minimal, otherwise-fixed UsageResponse so each test only has to name
    // the one or two fields it actually cares about.
    static func usage(spentUSD: Double, limitUSD: Double = 50) -> UsageResponse {
        UsageResponse(
            tokenId: "tok_test",
            dailyBudget: DailyBudget(
                limitUSD: limitUSD,
                spentUSD: spentUSD,
                remainingUSD: limitUSD - spentUSD,
                usedPercent: spentUSD / limitUSD * 100,
                limitEnabled: true,
                spendDate: "2026-08-01"
            ),
            currentMonth: MonthStats(totalCostUSD: spentUSD, totalTokens: 1000, requests: 10),
            topModels: []
        )
    }

    @Test("first successful fetch emits .fresh and feeds the burn buffer")
    func firstSuccessIsFresh() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        let now = ISODate.parse("2026-08-01T14:23:00Z")!
        let usage = Self.usage(spentUSD: 10)

        let state = machine.ingest(.success(usage), at: now)

        #expect(state == .fresh(usage))
        #expect(machine.state == .fresh(usage))
        // BurnBuffer's first record after init has no baseline, so it
        // stores a zero delta -- confirms ingest actually called record().
        #expect(machine.burnBuffer.slots == [0.0])
    }

    @Test("two consecutive failures with a last-good response emit .stale with counter 2")
    func twoFailuresWithLastGoodGoStale() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        let t0 = ISODate.parse("2026-08-01T14:00:00Z")!
        let usage = Self.usage(spentUSD: 10)
        machine.ingest(.success(usage), at: t0)

        // First failure alone must NOT flip the state yet.
        let afterOneFailure = machine.ingest(.failure(.network("timeout")), at: t0.addingTimeInterval(60))
        #expect(afterOneFailure == .fresh(usage))

        let afterTwoFailures = machine.ingest(.failure(.network("timeout")), at: t0.addingTimeInterval(120))
        #expect(afterTwoFailures == .stale(usage, consecutiveFailures: 2))
    }

    @Test("failures with no last-good response yet stay .neverFetched, still counting")
    func failuresWithNoLastGoodStayNeverFetched() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        let t0 = ISODate.parse("2026-08-01T14:00:00Z")!

        machine.ingest(.failure(.network("timeout")), at: t0)
        let state = machine.ingest(.failure(.network("timeout")), at: t0.addingTimeInterval(60))

        // Even with 2+ failures, there's nothing good to fall back on, so
        // the state must stay .neverFetched rather than fabricate a .stale.
        #expect(state == .neverFetched)
    }

    @Test("a success after .stale resets the failure counter and returns to .fresh")
    func successAfterStaleResetsCounter() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        let t0 = ISODate.parse("2026-08-01T14:00:00Z")!
        let firstGood = Self.usage(spentUSD: 10)
        machine.ingest(.success(firstGood), at: t0)
        machine.ingest(.failure(.network("timeout")), at: t0.addingTimeInterval(60))
        machine.ingest(.failure(.network("timeout")), at: t0.addingTimeInterval(120))

        let recovered = Self.usage(spentUSD: 12)
        let state = machine.ingest(.success(recovered), at: t0.addingTimeInterval(180))
        #expect(state == .fresh(recovered))

        // Counter reset means the NEXT single failure must NOT go straight
        // to .stale -- it should hold at .fresh, exactly like a fresh start.
        let afterOneMoreFailure = machine.ingest(.failure(.network("timeout")), at: t0.addingTimeInterval(240))
        #expect(afterOneMoreFailure == .fresh(recovered))
    }

    @Test("a midnight-UTC rollover (lower spentToday) clamps the burn buffer delta instead of wiping it")
    func midnightRolloverClampsBurnBuffer() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        let t0 = ISODate.parse("2026-08-01T23:59:00Z")!
        machine.ingest(.success(Self.usage(spentUSD: 20)), at: t0)
        machine.ingest(.success(Self.usage(spentUSD: 25)), at: t0.addingTimeInterval(60))

        // Spend counter reset at UTC midnight: today's cumulative spend
        // dropped even though real usage never went backwards.
        let afterRollover = t0.addingTimeInterval(120)
        machine.ingest(.success(Self.usage(spentUSD: 1)), at: afterRollover)

        // Prior real deltas (0, 5) survive; the rollover itself clamps to 0
        // rather than going negative or wiping the buffer.
        #expect(machine.burnBuffer.slots == [0.0, 5.0, 0.0])
    }

    @Test("exhaustedAt surfaces once spent reaches the limit, and holds at the first-crossing instant")
    func exhaustedAtSurfacesOnCrossing() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        let underLimit = ISODate.parse("2026-08-01T09:00:00Z")!
        let crossing = ISODate.parse("2026-08-01T14:23:00Z")!
        let laterStillOver = ISODate.parse("2026-08-01T16:00:00Z")!

        machine.ingest(.success(Self.usage(spentUSD: 40, limitUSD: 50)), at: underLimit)
        #expect(machine.exhaustedAt == nil)

        machine.ingest(.success(Self.usage(spentUSD: 50, limitUSD: 50)), at: crossing)
        #expect(machine.exhaustedAt == crossing)

        // A later poll still over budget must not re-stamp exhaustedAt.
        machine.ingest(.success(Self.usage(spentUSD: 55, limitUSD: 50)), at: laterStillOver)
        #expect(machine.exhaustedAt == crossing)
    }

    // MARK: - Today-models split (server-driven, v1.1.0)

    // A response whose today_models the split renders verbatim.
    static func usageOn(spendDate: String, spentToday: Double, monthTotal: Double, models: [(String, Double, Int, Int)]) -> UsageResponse {
        UsageResponse(
            tokenId: "tok_test",
            dailyBudget: DailyBudget(
                limitUSD: 400,
                spentUSD: spentToday,
                remainingUSD: 400 - spentToday,
                usedPercent: spentToday / 4,
                limitEnabled: true,
                spendDate: spendDate
            ),
            currentMonth: MonthStats(totalCostUSD: monthTotal, totalTokens: 1, requests: 1),
            topModels: [],
            today: MonthStats(totalCostUSD: spentToday, totalTokens: models.reduce(0) { $0 + $1.2 }, requests: models.reduce(0) { $0 + $1.3 }),
            todayModels: models.map { ModelUsage(model: $0.0, totalCostUSD: $0.1, totalTokens: $0.2, requests: $0.3) }
        )
    }

    @Test("ingest renders the response's today_models as the split")
    func ingestRendersTodayModelsAsTheSplit() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        machine.ingest(.success(Self.usageOn(spendDate: "2026-08-10", spentToday: 25, monthTotal: 125, models: [("a", 15, 1500, 10), ("b", 10, 200, 3)])), at: ISODate.parse("2026-08-10T12:00:00Z")!)

        guard case .split(let s) = machine.todayModelSplit else {
            Issue.record("expected a split, got \(machine.todayModelSplit)")
            return
        }
        // Rows are the server's own today rows, not a derivation.
        #expect(s.rows.first?.name == "a")
        #expect(s.rows.first?.requests == 10)
        #expect(s.rows.first { $0.isOther } == nil)
    }

    @Test("a failed fetch leaves the last good split untouched")
    func aFailedFetchLeavesTheLastGoodSplitUntouched() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        let goodResponse = Self.usageOn(spendDate: "2026-08-10", spentToday: 20, monthTotal: 120, models: [("a", 20, 2000, 40)])
        machine.ingest(.success(goodResponse), at: ISODate.parse("2026-08-10T12:00:00Z")!)
        let goodSplit = machine.todayModelSplit

        // Two failures → .stale, but the split must not be recomputed or cleared.
        machine.ingest(.failure(.network("timeout")), at: ISODate.parse("2026-08-10T12:01:00Z")!)
        machine.ingest(.failure(.network("timeout")), at: ISODate.parse("2026-08-10T12:02:00Z")!)

        #expect(machine.todayModelSplit == goodSplit)
        #expect(machine.state == .stale(goodResponse, consecutiveFailures: 2))
    }
}
