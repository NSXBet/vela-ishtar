// Tests/VelaCoreTests/UsageValidationTests.swift
// Regression coverage for the validated-domain layer: B03 (huge percentages
// never reach an Int cast), B07 (rows contradicting the day total never
// pass as reconciled), B08 (month shares divide by the authoritative total),
// and the availability distinctions the frozen contracts demand (absent vs
// null vs empty vs zero vs malformed).
// RELEVANT FILES: Sources/VelaCore/UsageValidation.swift, Sources/VelaCore/Models.swift

import Testing
import Foundation
@testable import VelaCore

struct UsageValidationTests {
    private let scope = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example")

    // MARK: - B03: used_percent boundary

    @Test("used_percent = 1e100 clamps before any integer conversion")
    func usedPercentHugeClampsSafely() {
        let budget = DailyBudget(limitUSD: 400, spentUSD: 100, remainingUSD: 300, usedPercent: 1e100, limitEnabled: true, spendDate: "2026-09-05")
        let (validated, warnings) = UsageValidation.budget(from: budget)
        // The Int() cast that used to trap (B03) must be safe on the
        // validated value.
        let _ = Int(validated.usedPercent.rounded())
        #expect(validated.usedPercent == UsageValidation.maxDisplayPercent)
        #expect(validated.usedPercentInt == Int(UsageValidation.maxDisplayPercent))
        #expect(warnings.contains { $0.field == "daily_budget.used_percent" })
    }

    @Test("used_percent NaN or infinity falls back to 0 with a warning")
    func usedPercentNonFiniteFallsBackToZero() {
        for bad in [Double.nan, Double.infinity, -Double.infinity] {
            let budget = DailyBudget(limitUSD: 400, spentUSD: 100, remainingUSD: 300, usedPercent: bad, limitEnabled: true, spendDate: "2026-09-05")
            let (validated, warnings) = UsageValidation.budget(from: budget)
            #expect(validated.usedPercent == 0)
            #expect(warnings.contains { $0.field == "daily_budget.used_percent" })
        }
    }

    @Test("huge finite limit is kept, not clamped to an arbitrary small maximum")
    func hugeLimitIsKept() {
        let budget = DailyBudget(limitUSD: 1e9, spentUSD: 5, remainingUSD: 1e9 - 5, usedPercent: 0.0005, limitEnabled: true, spendDate: "2026-09-05")
        let (validated, _) = UsageValidation.budget(from: budget)
        #expect(validated.limitUSD == 1e9)
        // Whole-dollar formatting stays truthful at scale.
        #expect(MoneyFormat.dollarsRounded(validated.limitUSD) == "$1000000000")
    }

    @Test("negative costs and tokens are rejected, not silently clamped into facts")
    func negativeMonetaryValuesRejected() {
        #expect(UsageValidation.money(-0.01) == nil)
        #expect(UsageValidation.money(.nan) == nil)
        #expect(UsageValidation.money(.infinity) == nil)
        #expect(UsageValidation.count(-1) == nil)

        let state = UsageValidation.breakdown(
            models: [ModelUsage(model: "m", totalCostUSD: -1, totalTokens: 10, requests: 1)],
            dayTotal: 100,
            scope: scope
        )
        guard case .inconsistent = state else { Issue.record("expected inconsistent"); return }
    }

    // MARK: - 01.1: availability distinctions

    @Test("absent today_models reads unavailable, not empty")
    func absentTodayModelsIsUnavailable() throws {
        let json = #"{"token_id":"t","daily_budget":{"limit_usd":400,"spent_usd":10,"remaining_usd":390,"used_percent":2.5,"limit_enabled":true,"spend_date":"2026-09-05"},"current_month":{"total_cost_usd":100,"total_tokens":1,"requests":1},"top_models":[]}"#
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.todayModelsPresent == false)
        #expect(UsageValidation.modelAvailability(of: response) == .unavailable)
    }

    @Test("present but empty today_models reads empty")
    func presentEmptyTodayModelsIsEmpty() throws {
        let json = #"{"token_id":"t","daily_budget":{"limit_usd":400,"spent_usd":0,"remaining_usd":400,"used_percent":0,"limit_enabled":true,"spend_date":"2026-09-05"},"current_month":{"total_cost_usd":0,"total_tokens":0,"requests":0},"top_models":[],"today":{"total_cost_usd":0,"total_tokens":0,"requests":0},"today_models":[]}"#
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(UsageValidation.modelAvailability(of: response) == .empty)
    }

    @Test("present rows with zero day total stay available (zero is a fact, not malformed)")
    func rowsWithZeroDayTotalAreAvailable() {
        let models = [ModelUsage(model: "m", totalCostUSD: 0.003, totalTokens: 10, requests: 1)]
        let state = UsageValidation.breakdown(models: models, dayTotal: 0.0, scope: scope)
        // Zero total with sub-cent rows: within tolerance, factual rows kept.
        guard case .available = state else { Issue.record("expected available"); return }
    }

    @Test("null today survives decoding and warns in the snapshot")
    func nullTodayWarns() throws {
        let json = #"{"token_id":"t","daily_budget":{"limit_usd":400,"spent_usd":10,"remaining_usd":390,"used_percent":2.5,"limit_enabled":true,"spend_date":"2026-09-05"},"current_month":{"total_cost_usd":0,"total_tokens":0,"requests":0},"top_models":[],"today":null,"today_models":null}"#
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.todayPresent)  // key present (null tolerated), zeroed default
        let snapshot = UsageValidation.snapshot(from: response, scope: scope, receivedAt: Date(timeIntervalSince1970: 0))
        #expect(snapshot.schemaWarnings.contains { $0.field == "today" && $0.detail.contains("null") })
    }

    @Test("malformed spend_date falls back to received-at day with a warning")
    func malformedSpendDateFallsBack() throws {
        var response = UsageResponse(
            tokenId: "t",
            dailyBudget: DailyBudget(limitUSD: 400, spentUSD: 0, remainingUSD: 400, usedPercent: 0, limitEnabled: true, spendDate: "not-a-date"),
            currentMonth: MonthStats(totalCostUSD: 0, totalTokens: 0, requests: 0),
            topModels: []
        )
        let received = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06-15 UTC
        let snapshot = UsageValidation.snapshot(from: response, scope: scope, receivedAt: received)
        #expect(snapshot.gatewayDay.key == "2025-06-15")  // received-at UTC day
        #expect(snapshot.schemaWarnings.contains { $0.field == "spend_date" })
    }

    // MARK: - B07: $80+$70 vs $100 day total

    @Test("named rows $80+$70 against a $100 day total render (gateway lag, user decision)")
    func namedRowsExceedingDayTotalStillRender() {
        let models = [
            ModelUsage(model: "a", totalCostUSD: 80, totalTokens: 100, requests: 1),
            ModelUsage(model: "b", totalCostUSD: 70, totalTokens: 100, requests: 1),
        ]
        let state = UsageValidation.breakdown(models: models, dayTotal: 100, scope: scope)
        guard case .available(let rows) = state else { Issue.record("expected available rows"); return }
        #expect(rows.rows.count == 2)
        // The validated fold renders too.
        #expect(TodayModelRows.validatedRows(from: models, dayTotal: 100) != nil)
    }

    @Test("named sum within a cent of the day total reconciles as available")
    func namedSumWithinToleranceIsAvailable() {
        let models = [ModelUsage(model: "a", totalCostUSD: 99.995, totalTokens: 100, requests: 1)]
        let state = UsageValidation.breakdown(models: models, dayTotal: 100, scope: scope)
        guard case .available(let rows, let total, _) = state else { Issue.record("expected available"); return }
        #expect(total == 100)
        #expect(rows.count == 1)
    }

    // MARK: - B08: month denominator

    @Test("month share denominator is the authoritative month total, not the row sum")
    func monthDenominatorIsAuthoritative() {
        let month = MonthStats(totalCostUSD: 1_000, totalTokens: 0, requests: 0)
        let top = [
            ModelUsage(model: "a", totalCostUSD: 300, totalTokens: 0, requests: 0),
            ModelUsage(model: "b", totalCostUSD: 200, totalTokens: 0, requests: 0),
        ]
        #expect(UsageValidation.monthShareDenominator(currentMonth: month, topModels: top) == 1_000)
        #expect(UsageValidation.hasOmittedTail(currentMonth: month, topModels: top))

        // B08's exact numbers: shares are 30% / 20%, never 60% / 40%.
        #expect(MoneyFormat.percent(cost: 300, total: 1_000) == 30)
        #expect(MoneyFormat.percent(cost: 200, total: 1_000) == 20)
    }

    @Test("no omitted tail when named rows cover the month total")
    func noTailWhenRowsCoverMonth() {
        let month = MonthStats(totalCostUSD: 500, totalTokens: 0, requests: 0)
        let top = [
            ModelUsage(model: "a", totalCostUSD: 300, totalTokens: 0, requests: 0),
            ModelUsage(model: "b", totalCostUSD: 200, totalTokens: 0, requests: 0),
        ]
        #expect(!UsageValidation.hasOmittedTail(currentMonth: month, topModels: top))
    }

    @Test("invalid month total means no comparable denominator")
    func invalidMonthTotalHasNoDenominator() {
        let month = MonthStats(totalCostUSD: -5, totalTokens: 0, requests: 0)
        #expect(UsageValidation.monthShareDenominator(currentMonth: month, topModels: []) == nil)
    }

    // MARK: - 01.3: duplicates, sub-cent residual, unknown models

    @Test("duplicate model names are inconsistent")
    func duplicateModelsInconsistent() {
        let models = [
            ModelUsage(model: "same", totalCostUSD: 10, totalTokens: 1, requests: 1),
            ModelUsage(model: "same", totalCostUSD: 20, totalTokens: 1, requests: 1),
        ]
        let state = UsageValidation.breakdown(models: models, dayTotal: 100, scope: scope)
        guard case .inconsistent(let reason) = state else { Issue.record("expected inconsistent"); return }
        #expect(reason.contains("duplicate"))
    }

    @Test("sub-cent residual against the day total is within tolerance, rows kept factual")
    func subCentResidualKeepsFactualRows() {
        let models = [ModelUsage(model: "a", totalCostUSD: 0.003, totalTokens: 1, requests: 1)]
        let state = UsageValidation.breakdown(models: models, dayTotal: 0.005, scope: scope)
        guard case .available = state else { Issue.record("expected available"); return }
    }

    @Test("unknown model IDs are preserved as facts, not dropped")
    func unknownModelIDsPreserved() {
        let models = [ModelUsage(model: "some-unheard-of/model-x", totalCostUSD: 5, totalTokens: 1, requests: 1)]
        let state = UsageValidation.breakdown(models: models, dayTotal: 10, scope: scope)
        guard case .available(let rows, _, _) = state else { Issue.record("expected available"); return }
        #expect(rows.first?.model == "some-unheard-of/model-x")
    }

    // MARK: - 01.2: zero limit enabled/disabled (B11 policy bit)

    @Test("zero enabled limit is a real $0 limit, zero disabled limit is unlimited")
    func zeroLimitEnabledVsDisabled() {
        let enabled = DailyBudget(limitUSD: 0, spentUSD: 0, remainingUSD: 0, usedPercent: 0, limitEnabled: true, spendDate: "2026-09-05")
        let (vb, _) = UsageValidation.budget(from: enabled)
        #expect(vb.limitEnabled)
        #expect(MoneyFormat.heroSuffix(limit: vb.limitUSD, limitEnabled: vb.limitEnabled) == " of $0 today")

        let disabled = DailyBudget(limitUSD: 0, spentUSD: 0, remainingUSD: 0, usedPercent: 0, limitEnabled: false, spendDate: "2026-09-05")
        let (vd, _) = UsageValidation.budget(from: disabled)
        #expect(MoneyFormat.heroSuffix(limit: vd.limitUSD, limitEnabled: vd.limitEnabled) == nil)
    }

    // MARK: - reconciliation (live smoke-test fix)

    @Test("exact-1¢ rounding gap reconciles (cents comparison, not raw doubles)")
    func oneCentGapReconciles() {
        #expect(UsageValidation.reconciles(namedSum: 27.51, total: 27.50, modelCount: 2))
    }

    @Test("per-model rounding allowance: a few cents of drift across models reconciles")
    func perModelAllowance() {
        // 2 models: 1¢ base + 2 allowance = 3¢ tolerated
        #expect(UsageValidation.reconciles(namedSum: 28.56, total: 28.53, modelCount: 2))
        #expect(UsageValidation.reconciles(namedSum: 28.59, total: 28.53, modelCount: 2) == false,
                "6¢ on 2 models exceeds the allowance")
    }

    @Test("a real contradiction (way past the total) still rejects")
    func realContradictionRejects() {
        #expect(!UsageValidation.reconciles(namedSum: 150, total: 100, modelCount: 2))
        #expect(!UsageValidation.reconciles(namedSum: 28.90, total: 28.53, modelCount: 2))
    }
}
