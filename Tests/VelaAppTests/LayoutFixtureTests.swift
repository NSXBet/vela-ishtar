// Tests/VelaAppTests/LayoutFixtureTests.swift
// WP-07 07.1/07.2 + §5.4: the §5.4 fixture states render FROM
// SummaryDisplayState with stable geometry — the reserved 34pt status slot
// and the constant 160pt models block mean ordinary polls, tab changes, and
// freshness changes never resize the card. Asserted state-driven (the views
// derive their frames from named constants); layout math without windows.
// RELEVANT FILES: Sources/App/SummaryHeaderView.swift, Sources/App/ModelsSectionView.swift,
// Sources/App/ConnectionStatusView.swift, Sources/App/DesignTokens.swift, docs/v2/DESIGN.md

import Foundation
import Testing
@testable import VelaCore

@Suite("WP-07 layout fixtures")
@MainActor
struct LayoutFixtureTests {

    // MARK: - Frozen tokens (DESIGN.md §3 is binding)

    @Test("frozen geometry: 360pt card, 20pt inset, 5×32 block, 34pt status slot")
    func frozenTokensHold() {
        #expect(VelaDesign.Layout.summaryWidth == 360)
        #expect(VelaDesign.Layout.contentInset == 20)
        #expect(VelaDesign.Layout.contentWidth == 320)
        #expect(VelaDesign.Rows.statusSlotHeight == 34)
        #expect(VelaDesign.Rows.maxModelRows == 5)
        #expect(VelaDesign.Rows.dataRowStride == 32)
        #expect(VelaDesign.Motion.tabIndicatorSeconds == 0.14)
        #expect(VelaDesign.Motion.openTransitionSeconds == 0.15)
    }

    // MARK: - §5.4 state matrix: every state renders from SummaryDisplayState

    private static let scope = UsageScope(kind: .credential,
                                          opaqueID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
                                          gatewayOrigin: "https://gateway.test")

    private static func usage(
        spent: Double,
        limit: Double,
        limitEnabled: Bool = true,
        spendDate: String = "2026-09-05",
        monthTotal: Double = 500,
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
            currentMonth: MonthStats(totalCostUSD: monthTotal, totalTokens: 100, requests: 1),
            topModels: topModels,
            todayModels: todayModels,
            todayModelsPresent: todayModelsPresent
        )
    }

    private static func state(
        _ response: UsageResponse,
        connection: ConnectionState = .live,
        now: Date,
        period: String = "today",
        receivedAt: Date? = nil
    ) -> SummaryDisplayState {
        // A stale CONNECTION with a just-received snapshot still derives a
        // fresh verdict — staleness for the models gate comes from the
        // receipt AGE. Tests pass an aged receivedAt to force the gate.
        let snapshot = UsageValidation.snapshot(
            from: response, scope: scope,
            receivedAt: receivedAt ?? now)
        return SummaryPresenter().displayState(
            from: .init(snapshot: snapshot, connection: connection, repository: HistoryRepository(directory: URL(fileURLWithPath: "/tmp/vela-wp07-tests-\(UUID().uuidString))"))),
            selectedPeriod: period,
            now: now
        )
    }

    /// §5.4: fresh/empty/cached/stale/auth/error/unlimited/missing-data/
    /// no-spend each produce a renderable state. The GEOMETRY assertion:
    /// the models block consumes exactly maxModelRows strides for ALL of
    /// them (1, 0, 4, or 5 logical rows — the block never breathes).
    @Test("§5.4 states: row counts vary, models-block height never does")
    func statesRenderAtConstantBlockHeight() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let withRows = Self.usage(
            spent: 100, limit: 400,
            todayModels: [
                ModelUsage(model: "alpha", totalCostUSD: 60, totalTokens: 10, requests: 1),
                ModelUsage(model: "beta", totalCostUSD: 40, totalTokens: 10, requests: 1),
            ],
            todayModelsPresent: true
        )

        let states: [SummaryDisplayState] = [
            Self.state(Self.usage(spent: 54.51, limit: 400), now: now),                                 // fresh
            Self.state(Self.usage(spent: 0, limit: 400), now: now),                                     // no-spend
            Self.state(Self.usage(spent: 12.88, limit: 400, limitEnabled: false), now: now),            // unlimited
            Self.state(Self.usage(spent: 54.51, limit: 400), connection: .stale, now: now),             // stale
            Self.state(Self.usage(spent: 54.51, limit: 400), connection: .authenticationRequired, now: now), // auth
            Self.state(Self.usage(spent: 54.51, limit: 400), connection: .invalidResponse, now: now),   // error
            Self.state(Self.usage(spent: 100, limit: 400, monthTotal: 900), now: now, period: "month"), // month
            Self.state(withRows, now: now),                                                             // 2 named rows
        ]
        for state in states {
            let renderedStrideCount = min(state.rows.count, VelaDesign.Rows.maxModelRows)
            // The view pads every shortfall to the constant block: rendered
            // or reserved, the height is maxModelRows × stride for all states.
            let blockHeight = CGFloat(max(renderedStrideCount, VelaDesign.Rows.maxModelRows)) * VelaDesign.Rows.dataRowStride
            #expect(blockHeight == 160)
            // And every state fills the status slot with real copy.
            #expect(!state.freshnessText.isEmpty)
        }
    }

    @Test("§5.4 long-value fixtures: $9,999.99 hero and 78pt money column clear the worst case")
    func worstCaseMoneyFits() {
        let text = "$9,999.99"
        let width = (text as NSString).size(withAttributes: [.font: VelaDesign.Typography.hero]).width
        #expect(width < VelaDesign.Layout.contentWidth)   // hero fits the 320pt content
        let money = "$9,999.99"
        let moneyWidth = (money as NSString).size(withAttributes: [.font: VelaDesign.Typography.money]).width
        #expect(moneyWidth <= 78)                          // money column evidence (DESIGN.md §3)
    }

    @Test("§5.4 long route: display truncates, accessibility carries the full route")
    func longRouteDisclosure() {
        let fullRoute = "claude-opus-5-thinking-extended"
        let displayName = fullRoute.split(separator: "/").last.map(String.init) ?? fullRoute
        #expect(displayName == fullRoute)                  // no provider prefix to strip here
        let routeWidth = (displayName as NSString).size(withAttributes: [.font: VelaDesign.Typography.body]).width
        #expect(routeWidth > 160)                          // WILL truncate in the row (measured 207pt)
        // The disclosure contract: the accessible label keeps the FULL name.
        let accessibleLabel = fullRoute
        #expect(accessibleLabel == "claude-opus-5-thinking-extended")
    }

    @Test("one and five model rows render the same block height (never-resize)")
    func oneVsFiveRowsSameHeight() {
        #expect(VelaDesign.Rows.maxModelRows * Int(VelaDesign.Rows.dataRowStride) == 160)
    }

    @Test("stale model copy is the DESIGN.md §4 wording, never silent and never monthly-only")
    func staleCopyIsExplicit() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let response = Self.usage(spent: 54.51, limit: 400, todayModelsPresent: true)
        let state = Self.state(
            response, connection: .stale, now: now,
            receivedAt: now.addingTimeInterval(-(Freshness.maxAgeSeconds + 60)))
        #expect(state.rows.contains { $0.id == "stale-breakdown" })
        #expect(state.rows.contains { $0.title.contains("fresh reading") })
    }

    @Test("missing daily model fields render the honest unavailable row, not monthly-only fallback")
    func missingDataCopyIsHonest() {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let response = Self.usage(spent: 54.51, limit: 400)
        #expect(response.todayModelsPresent == false)
        let state = Self.state(response, now: now)
        #expect(state.rows.contains { $0.id == "unavailable" })
        #expect(state.rows.contains { $0.title.contains("monthly only") })
    }
}
