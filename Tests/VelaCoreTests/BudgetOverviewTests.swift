// Tests/VelaCoreTests/BudgetOverviewTests.swift
// WP-08 08.1: the budget-rule tests. Every fixture from the plan's WP-08
// list pins one headroom/policy rule: global+model nesting, disabled global,
// relaxed cooldown, blocked (zero) cap, invalid figures, deterministic
// sorting, concurrent conditions, reset wording, and freshness passthrough.
// Why: these are the rules BudgetDetailView renders — a wrong headroom here
// becomes a wrong dollar figure on screen.
// RELEVANT FILES: Sources/VelaCore/BudgetOverview.swift, Sources/VelaCore/ModelBudgetSignal.swift,
// Sources/VelaCore/UsageValidation.swift

import Foundation
import Testing
@testable import VelaCore

@Suite("BudgetOverview")
struct BudgetOverviewTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let later = Self.now.addingTimeInterval(3_600)
    private static let earlier = Self.now.addingTimeInterval(-60)

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: fixtures

    private static func budget(
        globalLimit: Double = 400,
        globalSpent: Double = 60,
        limitEnabled: Bool = true,
        models: [ModelBudget] = []
    ) -> DailyBudget {
        DailyBudget(
            limitUSD: globalLimit,
            spentUSD: globalSpent,
            remainingUSD: max(0, globalLimit - globalSpent),
            usedPercent: globalLimit > 0 ? globalSpent / globalLimit * 100 : 0,
            limitEnabled: limitEnabled,
            spendDate: "2026-09-05",
            modelBudgets: models
        )
    }

    private static func cap(
        model: String,
        spent: Double,
        limit: Double,
        relaxedUntil: String? = nil
    ) -> ModelBudget {
        ModelBudget(
            model: model,
            spentUSD: spent,
            limitUSD: limit,
            remainingUSD: max(0, limit - spent),
            percentUsed: limit > 0 ? spent / limit * 100 : 0,
            cooldownEligible: relaxedUntil != nil,
            cooldown: relaxedUntil.map { ModelCooldown(createdAt: nil, relaxedUntil: $0) }
        )
    }

    private static func overview(
        budget: DailyBudget,
        freshness: Freshness = .fresh(receivedAt: Self.now, maxAgeSeconds: Freshness.maxAgeSeconds)
    ) -> BudgetOverview {
        let response = UsageResponse(
            tokenId: "11111111-2222-4333-8444-555555555555",
            dailyBudget: budget,
            currentMonth: MonthStats(totalCostUSD: budget.spentUSD, totalTokens: 1_000, requests: 10),
            topModels: []
        )
        let snapshot = UsageValidation.snapshot(
            from: response,
            scope: UsageScope(kind: .credential, opaqueID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, gatewayOrigin: "https://gateway.test"),
            receivedAt: Self.now
        )
        return BudgetOverview.derive(from: snapshot, freshness: freshness, now: Self.now, calendar: utcCalendar)
    }

    // MARK: 08.1 headroom rules

    @Test("global 40 left, model 5 left → model headroom 5 (model is binding)")
    func globalBountifulModelBinding() {
        let result = Self.overview(budget: Self.budget(globalLimit: 400, globalSpent: 360, models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 15, limit: 20),
        ]))

        #expect(result.globalRemainingUSD == 40)
        #expect(result.modelSignals.count == 1)
        #expect(result.modelSignals[0].headroomUSD == 5)
        #expect(result.modelSignals[0].state == .enabled)
    }

    @Test("global 2 left, model 5 left → headroom 2 (global is binding)")
    func globalBinding() {
        let result = Self.overview(budget: Self.budget(globalLimit: 400, globalSpent: 398, models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 3, limit: 20),
        ]))

        #expect(result.globalRemainingUSD == 2)
        #expect(result.modelSignals[0].headroomUSD == 2)
    }

    @Test("disabled global limit → model headroom is the model room alone")
    func disabledGlobalContributesNoBound() {
        let result = Self.overview(budget: Self.budget(limitEnabled: false, models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 15, limit: 20),
        ]))

        #expect(result.globalState == .disabled)
        #expect(result.globalRemainingUSD == nil)
        #expect(result.modelSignals[0].headroomUSD == 5)
    }

    @Test("active cooldown → global room with explicit relaxed marker")
    func activeCooldownUsesGlobalRoom() {
        let result = Self.overview(budget: Self.budget(globalLimit: 400, globalSpent: 360, models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 19, limit: 20, relaxedUntil: "2026-09-05T12:00:00Z"),
        ]))

        let signal = result.modelSignals[0]
        #expect(signal.state == .relaxed(until: ISODate.parse("2026-09-05T12:00:00Z")!))
        // The model cap ($1 left) is NOT enforced; the global room ($40) binds.
        #expect(signal.headroomUSD == 40)
    }

    @Test("expired cooldown is not relaxed — cap enforces again")
    func expiredCooldownEnforces() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expired = calendar.date(from: DateComponents(year: 1970, month: 1, day: 12, hour: 13, minute: 0))!
        let expiredString = "1970-01-12T13:00:00Z"
        #expect(expired < Self.now)

        let result = Self.overview(budget: Self.budget(models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 19, limit: 20, relaxedUntil: expiredString),
        ]))

        #expect(result.modelSignals[0].state == .enabled)
        #expect(result.modelSignals[0].headroomUSD == 1)
    }

    @Test("zero model cap → blocked with zero room, never unlimited")
    func zeroCapIsBlocked() {
        let result = Self.overview(budget: Self.budget(models: [
            Self.cap(model: "aihub/blocked-model", spent: 4, limit: 0),
        ]))

        #expect(result.modelSignals[0].state == .blocked)
        #expect(result.modelSignals[0].headroomUSD == 0)
    }

    @Test("invalid (negative) cap figures → invalid state, no invented room")
    func invalidCapStated() {
        let result = Self.overview(budget: Self.budget(models: [
            Self.cap(model: "aihub/bad-model", spent: -5, limit: 20),
        ]))

        #expect(result.modelSignals[0].state == .invalid)
        #expect(result.modelSignals[0].headroomUSD == nil)
    }

    @Test("invalid global figures → global contributes no bound")
    func invalidGlobalContributesNoBound() {
        let result = Self.overview(budget: Self.budget(globalLimit: .infinity, globalSpent: 60, models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 15, limit: 20),
        ]))

        #expect(result.globalState == .invalid)
        #expect(result.globalRemainingUSD == nil)
        #expect(result.modelSignals[0].headroomUSD == 5)
    }

    @Test("concurrent conditions all surface — relaxed cap does not hide a blocked cap")
    func concurrentConditionsAllSurface() {
        let result = Self.overview(budget: Self.budget(globalLimit: 400, globalSpent: 360, models: [
            Self.cap(model: "aihub/relaxed-model", spent: 19, limit: 20, relaxedUntil: "2026-09-05T12:00:00Z"),
            Self.cap(model: "aihub/blocked-model", spent: 2, limit: 0),
        ]))

        #expect(result.modelSignals.count == 2)
        let relaxed = result.modelSignals.first { $0.model == "aihub/relaxed-model" }
        let blocked = result.modelSignals.first { $0.model == "aihub/blocked-model" }
        #expect(relaxed?.state == .relaxed(until: ISODate.parse("2026-09-05T12:00:00Z")!))
        #expect(blocked?.state == .blocked)
        #expect(blocked?.headroomUSD == 0)
    }

    @Test("no model caps → empty signal list, global alone")
    func noModelCaps() {
        let result = Self.overview(budget: Self.budget(models: []))

        #expect(result.modelSignals.isEmpty)
        #expect(result.globalRemainingUSD == 340)
    }

    @Test("removed cap disappears from the next overview")
    func removedCapDropsOut() {
        let before = Self.overview(budget: Self.budget(models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 15, limit: 20),
        ]))
        #expect(before.modelSignals.count == 1)

        let after = Self.overview(budget: Self.budget(models: []))
        #expect(after.modelSignals.isEmpty)
    }

    // MARK: deterministic sorting

    @Test("sorting is spend descending, then model name ascending")
    func deterministicSort() {
        let result = Self.overview(budget: Self.budget(models: [
            Self.cap(model: "b/second-tie", spent: 5, limit: 20),
            Self.cap(model: "c/lowest", spent: 1, limit: 20),
            Self.cap(model: "a/first-tie", spent: 5, limit: 20),
            Self.cap(model: "d/highest", spent: 12, limit: 20),
        ]))

        #expect(result.modelSignals.map(\.model) == [
            "d/highest",
            "a/first-tie",
            "b/second-tie",
            "c/lowest",
        ])
    }

    // MARK: reset description + freshness

    @Test("reset description names UTC midnight with local time; disabled says no daily limit")
    func resetDescriptions() {
        let enabled = Self.overview(budget: Self.budget(globalLimit: 400, globalSpent: 60))
        #expect(enabled.resetDescription == "resets at UTC midnight (12:00 am local)")

        let disabled = Self.overview(budget: Self.budget(limitEnabled: false))
        #expect(disabled.resetDescription == "no daily limit")
    }

    @Test("stale freshness passes through — unknown/old policy is visibly last observed")
    func freshnessPassesThrough() {
        let stale = Self.overview(
            budget: Self.budget(),
            freshness: .stale(lastReceivedAt: Self.earlier)
        )
        #expect(stale.freshness == .stale(lastReceivedAt: Self.earlier))

        let invalidated = Self.overview(
            budget: Self.budget(),
            freshness: .invalidated(reason: "authentication failure")
        )
        #expect(invalidated.freshness == .invalidated(reason: "authentication failure"))
    }

    // MARK: status copy

    @Test("status copy names blocked, relaxed, and reached caps distinctly")
    func statusCopy() {
        #expect(Self.overview(budget: Self.budget(models: [
            Self.cap(model: "aihub/blocked-model", spent: 4, limit: 0),
        ])).modelSignals[0].statusDescription == "blocked")

        let exhausted = Self.overview(budget: Self.budget(models: [
            Self.cap(model: "aihub/full-model", spent: 20, limit: 20),
        ])).modelSignals[0]
        #expect(exhausted.statusDescription == "limit reached")
    }
}
