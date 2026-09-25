// Tests/VelaCoreTests/TodayModelSplitTests.swift
// Verifies TodayModelSplitEngine.split: the reconciliation of the gateway's
// today_models rows against the authoritative daily_budget.spent_usd.
// Why: this is the one place the app could show a confident lie (a split
// that doesn't sum to the day total), so the guards and the exact wording
// of the fallback notes are pinned here.
// RELEVANT FILES: Sources/VelaCore/TodayModelSplit.swift, Sources/VelaCore/Models.swift

import Testing
import Foundation
@testable import VelaCore

struct TodayModelSplitTests {
    // MARK: - Fixtures

    /// (name, cost, tokens, requests) rows on the spend day.
    private func usage(spentToday: Double, models: [(String, Double, Int, Int)]) -> UsageResponse {
        UsageResponse(
            tokenId: "t",
            dailyBudget: DailyBudget(limitUSD: 400, spentUSD: spentToday, remainingUSD: 400 - spentToday, usedPercent: spentToday / 4, limitEnabled: true, spendDate: "2026-09-24"),
            currentMonth: MonthStats(totalCostUSD: 600, totalTokens: 1, requests: 1),
            topModels: [],
            today: MonthStats(totalCostUSD: spentToday, totalTokens: models.reduce(0) { $0 + $1.2 }, requests: models.reduce(0) { $0 + $1.3 }),
            todayModels: models.map { ModelUsage(model: $0.0, totalCostUSD: $0.1, totalTokens: $0.2, requests: $0.3) }
        )
    }

    /// A response from an older gateway build: the today section is absent.
    private func usageWithoutTodayModels(spentToday: Double) -> UsageResponse {
        UsageResponse(
            tokenId: "t",
            dailyBudget: DailyBudget(limitUSD: 400, spentUSD: spentToday, remainingUSD: 400 - spentToday, usedPercent: spentToday / 4, limitEnabled: true, spendDate: "2026-09-24"),
            currentMonth: MonthStats(totalCostUSD: 600, totalTokens: 1, requests: 1),
            topModels: [],
            today: nil,
            todayModels: nil
        )
    }

    private func split(_ result: TodayModelSplitResult) -> TodayModelSplit? {
        guard case .split(let s) = result else { return nil }
        return s
    }

    private func reason(_ result: TodayModelSplitResult) -> TodayModelSplitResult.Reason? {
        guard case .unavailable(let r) = result else { return nil }
        return r
    }

    // MARK: - The core reconciliation

    @Test("today_models rows become named rows cost-desc, keeping tokens and requests")
    func todayModelsBecomeNamedRows() {
        let s = split(TodayModelSplitEngine.split(current: usage(spentToday: 14.63, models: [
            ("z-ai/glm-5.3-flash", 7.73, 379_130_000, 2_046),
            ("moonshotai/kimi-k3", 6.69, 14_590_000, 50),
        ])))
        let rows = s?.rows.filter { !$0.isOther }
        #expect(rows?.count == 2)
        #expect(rows?.first?.name == "z-ai/glm-5.3-flash")
        #expect(rows?.first?.costUSD == 7.73)
        #expect(rows?.first?.tokens == 379_130_000)
        #expect(rows?.first?.requests == 2_046)
        #expect(rows?.last?.requests == 50)
    }

    @Test("named rows plus Other sum exactly to the authoritative day total")
    func rowsSumToAuthoritativeTotal() {
        // The day total spans all of the user's tokens; the named rows are
        // this token's share. The 0.21 residue lands in Other.
        let s = split(TodayModelSplitEngine.split(current: usage(spentToday: 14.63, models: [
            ("a", 10.00, 1_000, 5),
            ("b", 4.42, 500, 2),
        ])))
        #expect(abs((s?.rows.reduce(0) { $0 + $1.costUSD } ?? 0) - 14.63) < 0.001)
        #expect(abs((s?.rows.last { $0.isOther }?.costUSD ?? 0) - 0.21) < 0.001)
    }

    @Test("the Other row never claims requests or tokens — they aren't derivable")
    func otherRowCarriesNoCounts() {
        let s = split(TodayModelSplitEngine.split(current: usage(spentToday: 14.63, models: [("a", 10.00, 1_000, 5)])))
        let other = s?.rows.last { $0.isOther }
        #expect(other?.tokens == 0)
        #expect(other?.requests == 0)
    }

    @Test("sub-cent today rows are dust and fall into Other, not named rows")
    func dustRowsFallIntoOther() {
        let s = split(TodayModelSplitEngine.split(current: usage(spentToday: 1.00, models: [
            ("a", 0.99, 1_000, 5),
            ("noise", 0.004, 10, 1),
        ])))
        #expect(s?.rows.filter { !$0.isOther }.count == 1)
        #expect(abs((s?.rows.last { $0.isOther }?.costUSD ?? 0) - 0.01) < 0.001)
    }

    // MARK: - The guards

    @Test("no spend yet yields noSpendYet with a nil note")
    func noSpendYetHasNoNote() {
        #expect(reason(TodayModelSplitEngine.split(current: usage(spentToday: 0, models: []))) == .noSpendYet)
        #expect(TodayModelSplitResult.Reason.noSpendYet.note == nil)
    }

    @Test("a response without today_models yields gatewayLacksSplit with its note")
    func missingTodayModelsIsUnavailable() {
        let r = reason(TodayModelSplitEngine.split(current: usageWithoutTodayModels(spentToday: 14.63)))
        #expect(r == .gatewayLacksSplit)
        #expect(r?.note == "This AI Hub gateway build doesn't expose today's split yet")
    }

    @Test("named rows exceeding the day total do not tie — unavailable, never a wrong split")
    func overAttributionBails() {
        let r = reason(TodayModelSplitEngine.split(current: usage(spentToday: 5.00, models: [
            ("a", 6.00, 1_000, 5),
        ])))
        #expect(r == .doesNotTie)
        #expect(r?.note == "Per-model split doesn't tie to today's total")
    }

    // MARK: - Gateway cache lag (v1.1.0, captured from production)

    // A REAL payload quirk: spent_usd and today.total_cost_usd have separate
    // 1-minute gateway caches, and spent_usd can TRAIL today's rows by cents.
    // Captured 2026-09-24: today_models sum $16.2054, spent_usd $16.1188 —
    // a $0.087 residue, exactly the shape that shipped as a regression when
    // the reconciliation epsilon was $0.005 (the Today models vanished).

    @Test("a small cache-lag excess shows the rows as-is, never doesNotTie")
    func cacheLagWithinToleranceStillSplits() {
        let s = split(TodayModelSplitEngine.split(current: usage(spentToday: 16.12, models: [
            ("z-ai/glm-5.3-flash", 9.2561, 442_074_448, 2_345),
            ("moonshotai/kimi-k3", 6.6866, 14_585_879, 50),
            ("openai/gpt-5.6-luna", 0.2627, 8_363_741, 59),
        ])))
        // Rows render; the $0.09 negative residue produces no Other row.
        let rows = s?.rows.filter { !$0.isOther }
        #expect(rows?.count == 3)
        #expect(s?.rows.first { $0.isOther } == nil)
    }

    @Test("over-attribution beyond the restatement tolerance still bails")
    func overAttributionBeyondToleranceBails() {
        // $1.00 over a $16.12 day is far past max(1%, $0.50) — the two
        // aggregates genuinely disagree.
        let r = reason(TodayModelSplitEngine.split(current: usage(spentToday: 16.12, models: [
            ("a", 17.20, 1_000, 5),
        ])))
        #expect(r == .doesNotTie)
    }

// MARK: - Formatter (UsageCounts, v1.1.0)

@Test("count formatter matches the dashboard's compact conventions")
func formatterConventions() {
    #expect(UsageCounts.compact(50) == "50")
    #expect(UsageCounts.compact(999) == "999")
    #expect(UsageCounts.compact(1_000) == "1.0K")
    #expect(UsageCounts.compact(2_046) == "2.0K")
    #expect(UsageCounts.compact(14_590) == "14.6K")
    #expect(UsageCounts.compact(379_130_000) == "379.13M")
    #expect(UsageCounts.compact(8_360_000) == "8.36M")
}

@Test("zero count labels render as an em-dash, never a claimed 0")
func formatterZeroIsSilent() {
    #expect(UsageCounts.requestsLabel(0) == "—")
    #expect(UsageCounts.tokensLabel(0) == "—")
    #expect(UsageCounts.requestsLabel(2_046) == "2.0K requests")
    #expect(UsageCounts.tokensLabel(14_590_000) == "14.59M tokens")
}

// MARK: - Wire decode (v1.1.0)

@Test("a gateway response carrying today fields decodes them; one without decodes nil")
func decodeToleranceOmitsTodayFields() throws {
    let full = """
    {"token_id":"t",
     "daily_budget":{"limit_usd":300,"spent_usd":16.2,"remaining_usd":283.8,"used_percent":5.4,"limit_enabled":true,"spend_date":"2026-09-24"},
     "current_month":{"total_cost_usd":620.5,"total_tokens":1,"requests":1},
     "top_models":[],
     "today":{"period_start":"2026-09-24T00:00:00-03:00","period_end":"2026-09-25T00:00:00-03:00","total_cost_usd":16.2,"total_tokens":450000000,"requests":2400},
     "today_models":[{"model":"z-ai/glm-5.3-flash","total_cost_usd":9.25,"total_tokens":442000000,"requests":2345}]}
    """
    let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(full.utf8))
    #expect(usage.today?.totalCostUSD == 16.2)
    #expect(usage.todayModels?.count == 1)
    #expect(usage.todayModels?.first?.requests == 2345)

    let legacy = """
    {"token_id":"t",
     "daily_budget":{"limit_usd":300,"spent_usd":16.2,"remaining_usd":283.8,"used_percent":5.4,"limit_enabled":true,"spend_date":"2026-09-24"},
     "current_month":{"total_cost_usd":620.5,"total_tokens":1,"requests":1},
     "top_models":[]}
    """
    let old = try JSONDecoder().decode(UsageResponse.self, from: Data(legacy.utf8))
    #expect(old.today == nil)
    #expect(old.todayModels == nil)
}

// MARK: - Tolerance boundaries (v1.1.0)

@Test("a residue exactly at the $0.50 tolerance floor still splits; one cent past does not tie")
func toleranceBoundary() {
    // Named rows sum to 5.50 against a 5.00 day: residue −$0.50 = exactly at
    // the floor (max(1% of 5.00, $0.50)) → tolerated, rows shown as-is.
    let atFloor = split(TodayModelSplitEngine.split(current: usage(spentToday: 5.00, models: [("a", 5.50, 1_000, 5)])))
    #expect(atFloor?.rows.first { $0.isOther } == nil)
    #expect(atFloor?.rows.first { !$0.isOther }?.costUSD == 5.50)

    // One cent past the floor genuinely disagrees → no split.
    #expect(reason(TodayModelSplitEngine.split(current: usage(spentToday: 5.00, models: [("a", 5.51, 1_000, 5)]))) == .doesNotTie)
}

@Test("the $0.50 floor permits documented over-attribution on small days")
func smallDayOverAttributionIsAccepted() {
    // Documented accepted behavior (pr-deep-review residual risk): on a
    // $10 day the floor is $0.50, so a named row claiming up to $0.50 over
    // the day total still renders. The cost figures are the gateway's own
    // today_models rows, so this is bounded noise, not a wrong breakdown.
    let s = split(TodayModelSplitEngine.split(current: usage(spentToday: 10.00, models: [("a", 10.40, 1_000, 5)])))
    #expect(s?.rows.first { !$0.isOther }?.costUSD == 10.40)
    #expect(s?.rows.first { $0.isOther } == nil)
}
}
