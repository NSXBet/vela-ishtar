// Tests/VelaCoreTests/TodayModelRowsTests.swift
// Verifies TodayModelRows.rows: the pure display fold from the gateway's
// already-sorted, already-capped `today_models` array into named rows plus
// an optional pinned-last Other row.
// Why: this is a display fold, not a derivation, so the guards worth pinning
// are narrow — the epsilon that hides sub-cent noise, the Other row's exact
// residual math, and the never-negative guard that keeps floating-point
// noise or a data anomaly from ever rendering a bogus reconciliation row.
// RELEVANT FILES: Sources/VelaCore/TodayModelRows.swift, Sources/VelaCore/Models.swift

import Testing
import Foundation
@testable import VelaCore

struct TodayModelRowsTests {
    // MARK: - Fixtures

    private func model(_ name: String, _ cost: Double, _ tokens: Int = 1_000_000) -> ModelUsage {
        ModelUsage(model: name, totalCostUSD: cost, totalTokens: tokens, requests: 1)
    }

    // MARK: - No Other row: named rows already explain the day total

    @Test("a single model exactly matching the day total yields one named row, no Other")
    func singleModelExactlyMatchingDayTotalYieldsNoOther() {
        let rows = TodayModelRows.rows(from: [model("kimi-k3", 30)], dayTotal: 30)
        #expect(rows.count == 1)
        #expect(rows[0].name == "kimi-k3")
        #expect(rows[0].costUSD == 30)
        #expect(rows[0].isOther == false)
    }

    @Test("models within maxNamedRows summing exactly to the day total yield no Other")
    func modelsWithinMaxNamedRowsSummingExactlyYieldNoOther() {
        let models = [model("a", 12), model("b", 8), model("c", 5)]
        let rows = TodayModelRows.rows(from: models, dayTotal: 25)
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.isOther == false })
        #expect(rows.reduce(0) { $0 + $1.costUSD } == 25)
    }

    // MARK: - Other row: a real tail beyond maxNamedRows

    @Test("more than maxNamedRows models fold the tail into a pinned-last Other row")
    func moreThanMaxNamedRowsFoldsTailIntoPinnedLastOther() {
        // 5 models, cost-descending, as the gateway already delivers them.
        let models = [
            model("a", 40), model("b", 20), model("c", 15), model("d", 10), model("e", 5),
        ]
        let dayTotal = 90.0
        let rows = TodayModelRows.rows(from: models, dayTotal: dayTotal)
        #expect(rows.count == TodayModelRows.maxNamedRows + 1)
        #expect(rows.last?.isOther == true)
        #expect(rows.last?.name == "Other")
        // Named sum is 40+20+15+10 = 85, so Other absorbs the real 5th model
        // plus nothing else (dayTotal ties exactly to the 5 gateway rows).
        #expect(rows.last?.costUSD == 5)
        #expect(rows.dropLast().allSatisfy { $0.isOther == false })
    }

    @Test("a gap between the top-4 sum and the day total (multi-token case) becomes the Other row")
    func multiTokenGapBetweenTopFourAndDayTotalBecomesOther() {
        // Exactly 4 models (no real tail), but the day total — scoped to the
        // whole user across several tokens — exceeds what this token's
        // top-4 explain.
        let models = [model("a", 10), model("b", 6), model("c", 3), model("d", 1)]
        let dayTotal = 25.0 // named sum is 20, so the gap is 5.
        let rows = TodayModelRows.rows(from: models, dayTotal: dayTotal)
        #expect(rows.count == 5)
        #expect(rows.last?.isOther == true)
        #expect(rows.last?.costUSD == 5)
    }

    // MARK: - Empty-row cases

    @Test("a day total at or below the display epsilon returns no rows regardless of models")
    func dayTotalAtOrBelowEpsilonReturnsNoRows() {
        let models = [model("a", 40)]
        #expect(TodayModelRows.rows(from: models, dayTotal: 0).isEmpty)
        #expect(TodayModelRows.rows(from: models, dayTotal: 0.005).isEmpty)
        #expect(TodayModelRows.rows(from: models, dayTotal: -1).isEmpty)
    }

    @Test("an empty models array with a positive day total returns no rows (defensive fallback)")
    func emptyModelsWithPositiveDayTotalReturnsNoRows() {
        #expect(TodayModelRows.rows(from: [], dayTotal: 30).isEmpty)
    }

    // MARK: - Never-negative-Other guard

    @Test("named rows summing slightly more than the day total append no Other row")
    func namedRowsSummingSlightlyMoreThanDayTotalAppendNoOther() {
        // Floating-point noise / a data anomaly: named sum (30.01) exceeds
        // dayTotal (30.00) by a cent — must never render a negative or
        // dust-sized reconciliation row.
        let models = [model("a", 20.00), model("b", 10.01)]
        let rows = TodayModelRows.rows(from: models, dayTotal: 30.00)
        #expect(rows.count == min(models.count, TodayModelRows.maxNamedRows))
        #expect(rows.contains { $0.isOther } == false)
    }
}

// MARK: - WP-01 validated fold (B07 and friends)

struct TodayModelRowsValidationTests {
    private func model(_ name: String, _ cost: Double, _ tokens: Int = 1_000_000) -> ModelUsage {
        ModelUsage(model: name, totalCostUSD: cost, totalTokens: tokens, requests: 1)
    }

    @Test("B07 superseded (user decision): named rows ALWAYS render, even summing past the day total")
    func rowsExceedingDayTotalStillRender() {
        // Gateway lag: today_models can exceed daily_budget.spent by real
        // cents (or more) until the next poll. The user decided the models
        // and their prices display ALWAYS — the total self-corrects.
        let rows = TodayModelRows.validatedRows(
            from: [model("a", 80), model("b", 70)],
            dayTotal: 100
        )
        #expect(rows != nil)
        #expect(rows?.count == 2)
    }

    @Test("rows within tolerance of the day total fold normally with a residual Other")
    func rowsWithinToleranceFoldNormally() {
        let rows = TodayModelRows.validatedRows(
            from: [model("a", 30), model("b", 20)],
            dayTotal: 100
        )
        #expect(rows?.count == 3)
        #expect(rows?.last?.isOther == true)
        #expect(rows?.last?.costUSD == 50)
    }

    @Test("duplicate model names are rejected by the validated fold")
    func duplicatesRejected() {
        let rows = TodayModelRows.validatedRows(
            from: [model("same", 10), model("same", 20)],
            dayTotal: 100
        )
        #expect(rows == nil)
    }

    @Test("negative or non-finite row costs are rejected")
    func negativeCostsRejected() {
        #expect(TodayModelRows.validatedRows(from: [model("a", -5)], dayTotal: 100) == nil)
        #expect(TodayModelRows.validatedRows(from: [model("a", .nan)], dayTotal: 100) == nil)
    }

    @Test("a negative day total is rejected outright")
    func negativeDayTotalRejected() {
        #expect(TodayModelRows.validatedRows(from: [model("a", 5)], dayTotal: -10) == nil)
    }

    @Test("sub-cent residual after folding stays hidden (dust guard preserved)")
    func subCentResidualHidden() {
        // Named sum $99.999 vs $100 total → residual $0.001 < epsilon.
        let rows = TodayModelRows.validatedRows(
            from: [model("a", 99.999)],
            dayTotal: 100
        )
        #expect(rows?.count == 1)
        #expect(rows?.last?.isOther == false)
    }

    @Test("unknown model IDs pass through as factual rows")
    func unknownModelIDsPassThrough() {
        let rows = TodayModelRows.validatedRows(
            from: [model("obscure/unknown-model-42", 5)],
            dayTotal: 10
        )
        #expect(rows?.first?.name == "obscure/unknown-model-42")
    }

    @Test("more than maxNamedRows models still fold the tail into Other after validation")
    func tailFoldPreserved() {
        let rows = TodayModelRows.validatedRows(
            from: (1...6).map { model("m\($0)", 10) },
            dayTotal: 70
        )
        #expect(rows?.count == 5)
        #expect(rows?.last?.name == "Other")
        #expect(rows?.last?.costUSD == 30)
    }
}
