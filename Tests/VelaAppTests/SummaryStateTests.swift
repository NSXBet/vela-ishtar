// Tests/VelaAppTests/SummaryStateTests.swift
// WP-07 07.1/07.2: the summary's state behavior, pinned at the display-state
// boundary the view consumes. The B07/B08/B11 regressions live here: the
// unlimited hero carries no "of $400" suffix, month shares divide by the
// authoritative month total, and inconsistent rows never masquerade as a
// reconciled breakdown.
// RELEVANT FILES: Sources/App/SummaryPresenter.swift, Sources/VelaCore/MoneyFormat.swift,
// Sources/VelaCore/SummaryDisplayState.swift, Sources/App/SummaryHeaderView.swift

import Foundation
import Testing
@testable import VelaCore

@Suite("WP-07 summary state")
@MainActor
struct SummaryStateTests {

    private static let scope = UsageScope(kind: .credential,
                                          opaqueID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
                                          gatewayOrigin: "https://gateway.test")

    private static func usage(
        spent: Double,
        limit: Double,
        limitEnabled: Bool = true,
        spendDate: String = "2026-09-05",
        monthTotal: Double = 1000,
        topModels: [ModelUsage] = [],
        todayModels: [ModelUsage] = [],
        todayModelsPresent: Bool? = nil
    ) -> UsageResponse {
        UsageResponse(
            tokenId: "11111111-2222-4333-8444-555555555555",
            dailyBudget: DailyBudget(
                limitUSD: limit, spentUSD: spent, remainingUSD: limit - spent,
                usedPercent: limitEnabled ? spent / limit * 100 : 0,
                limitEnabled: limitEnabled, spendDate: spendDate
            ),
            currentMonth: MonthStats(totalCostUSD: monthTotal, totalTokens: 500, requests: 5),
            topModels: topModels,
            todayModels: todayModels,
            todayModelsPresent: todayModelsPresent
        )
    }

    private static func presenterState(
        _ response: UsageResponse,
        connection: ConnectionState = .live,
        now: Date = Date(timeIntervalSince1970: 1_787_000_000),
        period: String = "today"
    ) -> SummaryDisplayState {
        let snapshot = UsageValidation.snapshot(from: response, scope: scope, receivedAt: now)
        let presenter = SummaryPresenter()
        return presenter.displayState(
            from: .init(snapshot: snapshot, connection: connection, repository: HistoryRepository(directory: URL(fileURLWithPath: "/tmp/vela-wp07-tests-\(UUID().uuidString))"))),
            selectedPeriod: period,
            now: now
        )
    }

    // MARK: - B11: unlimited hero

    @Test("disabled limit: hero suffix omits 'of $X today' entirely")
    func unlimitedHeroHasNoFalseCeiling() {
        let state = Self.presenterState(Self.usage(spent: 12.88, limit: 400, limitEnabled: false))
        #expect(!state.hero.detail.contains("of $"))
        #expect(state.hero.detail.contains("no daily limit"))
        #expect(state.hero.title == "$12.88")   // real spend, never $0.00
        #expect(state.hero.fraction == nil)
    }

    @Test("enabled limit: hero suffix is the factual remaining-of figure via MoneyFormat.heroSuffix")
    func limitedHeroKeepsSuffix() {
        let suffix = MoneyFormat.heroSuffix(limit: 400, limitEnabled: true)
        #expect(suffix == " of $400 today")
        #expect(MoneyFormat.heroSuffix(limit: 400, limitEnabled: false) == nil)
    }

    // MARK: - B07: reconciled rows

    @Test("today rows that exceed the day total render total-only, never $150-of-$100")
    func inconsistentRowsRenderTotalOnly() {
        let response = Self.usage(
            spent: 100, limit: 400,
            todayModels: [
                ModelUsage(model: "alpha", totalCostUSD: 80, totalTokens: 1000, requests: 2),
                ModelUsage(model: "beta", totalCostUSD: 70, totalTokens: 1000, requests: 2),
            ],
            todayModelsPresent: true
        )
        let state = Self.presenterState(response)
        // The validated fold flags inconsistency: no named row may claim a
        // cost that sums past the hero.
        let namedSum = state.rows.filter { $0.id.hasPrefix("model-") }
            .compactMap { Double($0.detail.dropFirst()) }.reduce(0, +)
        #expect(namedSum <= 100.01)
    }

    @Test("reconciled rows keep stable IDs across spend changes")
    func rowIDsStableAcrossRefresh() {
        var response = Self.usage(
            spent: 100, limit: 400,
            todayModels: [
                ModelUsage(model: "alpha", totalCostUSD: 60, totalTokens: 1000, requests: 2),
                ModelUsage(model: "beta", totalCostUSD: 40, totalTokens: 1000, requests: 2),
            ],
            todayModelsPresent: true
        )
        let first = Self.presenterState(response)
        response = Self.usage(
            spent: 150, limit: 400,
            todayModels: [
                ModelUsage(model: "alpha", totalCostUSD: 110, totalTokens: 1000, requests: 2),
                ModelUsage(model: "beta", totalCostUSD: 40, totalTokens: 1000, requests: 2),
            ],
            todayModelsPresent: true
        )
        let second = Self.presenterState(response)
        #expect(first.rows.map(\.id) == second.rows.map(\.id))
    }

    // MARK: - B08: month denominator

    @Test("month shares divide by current_month.totalCostUSD, not the row sum")
    func monthSharesUseAuthoritativeTotal() {
        let response = Self.usage(
            spent: 300, limit: 400, monthTotal: 1000,
            topModels: [
                ModelUsage(model: "alpha", totalCostUSD: 300, totalTokens: 100, requests: 1),
                ModelUsage(model: "beta", totalCostUSD: 200, totalTokens: 100, requests: 1),
            ]
        )
        let state = Self.presenterState(response, period: "month")
        // $300 of $1000 = 30%, not 60% (the truncated-row-sum lie).
        #expect(state.selectedPeriodTotalUSD == 1000)
        #expect(state.rows.first { $0.id == "model-alpha" }?.fraction == 0.3)
        #expect(state.rows.first { $0.id == "model-beta" }?.fraction == 0.2)
    }

    // MARK: - 07.2: period scoping is unambiguous

    @Test("selected period total follows the switcher without changing the daily hero")
    func periodSwitchScopesTotalOnly() {
        let response = Self.usage(
            spent: 54.51, limit: 400, monthTotal: 812.34,
            topModels: [ModelUsage(model: "alpha", totalCostUSD: 812.34, totalTokens: 10, requests: 1)]
        )
        let today = Self.presenterState(response, period: "today")
        let month = Self.presenterState(response, period: "month")
        #expect(today.selectedPeriod == "today")
        #expect(today.selectedPeriodTotalUSD == 54.51)
        #expect(month.selectedPeriodTotalUSD == 812.34)
        // One daily hero — the hero is NOT a period surface.
        #expect(today.hero.title == month.hero.title)
    }

    // MARK: - 07.1: status slot is always filled

    @Test("every connection state yields non-empty freshness copy (no blank slot)")
    func freshnessTextNeverEmpty() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let response = Self.usage(spent: 10, limit: 400)
        for connection: ConnectionState in [.connecting, .live, .stale, .retrying(attempt: 2), .authenticationRequired, .invalidResponse, .keychainBlocked, .noCredential] {
            let state = Self.presenterState(response, connection: connection, now: now)
            #expect(!state.freshnessText.isEmpty)
            #expect(!state.accessibilitySummary.isEmpty)
        }
    }

    @Test("identical states stay equatable so the view's no-op guard holds")
    func identicalStateIsNoOp() {
        let response = Self.usage(spent: 10, limit: 400)
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        #expect(Self.presenterState(response, now: now) == Self.presenterState(response, now: now))
    }
}
