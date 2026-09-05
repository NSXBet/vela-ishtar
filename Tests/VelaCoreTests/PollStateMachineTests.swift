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

    @Test("ingest's fresh state exposes the same today/todayModels the fixture carried in")
    func ingestPassesThroughTodayAndTodayModelsUnchanged() {
        var machine = PollStateMachine(historyDirectory: Self.freshDirectory())
        let now = ISODate.parse("2026-08-01T14:23:00Z")!
        let todayModels = [
            ModelUsage(model: "anthropic/claude-sonnet-5", totalCostUSD: 12.13, totalTokens: 1000, requests: 5),
            ModelUsage(model: "openai/gpt-5.6-luna-pro", totalCostUSD: 5.81, totalTokens: 500, requests: 2),
        ]
        let today = MonthStats(totalCostUSD: 22.47, totalTokens: 1500, requests: 7, periodStart: "2026-08-01", periodEnd: "2026-08-02")
        let usage = UsageResponse(
            tokenId: "tok_test",
            dailyBudget: DailyBudget(
                limitUSD: 50,
                spentUSD: 10,
                remainingUSD: 40,
                usedPercent: 20,
                limitEnabled: true,
                spendDate: "2026-08-01"
            ),
            currentMonth: MonthStats(totalCostUSD: 10, totalTokens: 1000, requests: 10),
            topModels: [],
            today: today,
            todayModels: todayModels
        )

        let state = machine.ingest(.success(usage), at: now)

        guard case .fresh(let fresh) = state else {
            Issue.record("expected .fresh, got \(state)")
            return
        }
        #expect(fresh.today == today)
        #expect(fresh.todayModels == todayModels)
    }
}
