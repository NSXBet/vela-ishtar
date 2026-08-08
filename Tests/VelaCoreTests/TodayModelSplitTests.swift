// Tests/VelaCoreTests/TodayModelSplitTests.swift
// Verifies TodayModelSplitEngine.split: the pure derivation of today's
// per-model spend from two month-cumulative top_models snapshots, and the
// reconciliation rule that the rows always tie to daily_budget.spent_usd.
// Why: this is the one place the app could show a confident lie (a split
// that doesn't sum to the day total), so every guard and the exact wording
// of the fallback notes are pinned here.
// RELEVANT FILES: Sources/VelaCore/TodayModelSplit.swift, Sources/VelaCore/ModelSnapshots.swift, Tests/VelaCoreTests/ModelSnapshotsTests.swift

import Testing
import Foundation
@testable import VelaCore

struct TodayModelSplitTests {
    // MARK: - Fixtures

    private func point(_ cost: Double, _ tokens: Int = 1_000_000) -> ModelPoint {
        ModelPoint(costUSD: cost, tokens: tokens)
    }

    private func snapshot(monthKey: String, monthTotal: Double, models: [String: ModelPoint]) -> ModelSnapshot {
        ModelSnapshot(monthKey: monthKey, monthTotalUSD: monthTotal, models: models, capturedAt: Date(timeIntervalSince1970: 1_780_000_000))
    }

    private func usage(spentToday: Double, monthTotal: Double, models: [(String, Double, Int)]) -> UsageResponse {
        UsageResponse(
            tokenId: "t",
            dailyBudget: DailyBudget(limitUSD: 400, spentUSD: spentToday, remainingUSD: 400 - spentToday, usedPercent: spentToday / 4, limitEnabled: true, spendDate: "2026-08-10"),
            currentMonth: MonthStats(totalCostUSD: monthTotal, totalTokens: 1, requests: 1),
            topModels: models.map { ModelUsage(model: $0.0, totalCostUSD: $0.1, totalTokens: $0.2, requests: 1) }
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

    // MARK: - The core differencing

    @Test("a model present in both snapshots yields cost = current − baseline")
    func bothPresentPositiveDeltaBecomesNamedRow() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["kimi-k3": point(40)])
        let current = usage(spentToday: 30, monthTotal: 130, models: [("kimi-k3", 70, 2_000_000)])
        let rows = split(TodayModelSplitEngine.split(current: current, baseline: base))?.rows
        #expect(rows?.first { $0.name == "kimi-k3" }?.costUSD == 30)
        #expect(rows?.first { $0.name == "kimi-k3" }?.isOther == false)
    }

    @Test("named rows plus Other sum exactly to the authoritative day total")
    func namedRowsSumPlusOtherEqualsAuthoritativeTotal() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(40), "b": point(20)])
        // Truncation: the day total is 50 but named deltas only explain 30.
        let current = usage(spentToday: 50, monthTotal: 150, models: [("a", 60, 100), ("b", 30, 100)])
        let s = split(TodayModelSplitEngine.split(current: current, baseline: base))
        #expect(s?.rows.reduce(0) { $0 + $1.costUSD } == 50)
        #expect(s?.rows.last { $0.isOther }?.costUSD == 20)
    }

    @Test("a model new in current only is absorbed into Other, not credited current − 0")
    func newModelInCurrentOnlyIsAbsorbedIntoOther() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(40)])
        // "new" has $35 of MONTH spend but no baseline position — its today
        // delta is unknown, so it must not become a $35 named row.
        let current = usage(spentToday: 50, monthTotal: 150, models: [("a", 50, 100), ("new", 35, 100)])
        let s = split(TodayModelSplitEngine.split(current: current, baseline: base))
        #expect(s?.rows.contains { $0.name == "new" } == false)
        #expect(s?.rows.first { $0.name == "a" }?.costUSD == 10)
        #expect(s?.rows.first { $0.isOther }?.costUSD == 40)
    }

    @Test("a model dropped from the truncated current list is ignored entirely")
    func modelDroppedFromCurrentIsIgnoredEntirely() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(40), "gone": point(25)])
        let current = usage(spentToday: 50, monthTotal: 150, models: [("a", 60, 100)])
        let s = split(TodayModelSplitEngine.split(current: current, baseline: base))
        // No "$0.00" row for "gone", and it silently lands in Other.
        #expect(s?.rows.contains { $0.name == "gone" } == false)
        #expect(s?.rows.first { $0.isOther }?.costUSD == 30)
    }

    @Test("a negative (restated-down) delta drops the row rather than clamping to zero")
    func negativeDeltaDropsTheRowRatherThanClampingToZero() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(40), "restated": point(30)])
        let current = usage(spentToday: 50, monthTotal: 140, models: [("a", 60, 100), ("restated", 28, 100)])
        let s = split(TodayModelSplitEngine.split(current: current, baseline: base))
        #expect(s?.rows.contains { $0.name == "restated" } == false)
        #expect(s?.rows.first { $0.isOther }?.costUSD == 30)
    }

    @Test("a zero delta emits no row — a model that didn't run today isn't listed")
    func zeroDeltaEmitsNoRow() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(40), "idle": point(10)])
        let current = usage(spentToday: 20, monthTotal: 120, models: [("a", 60, 100), ("idle", 10, 100)])
        let s = split(TodayModelSplitEngine.split(current: current, baseline: base))
        #expect(s?.rows.contains { $0.name == "idle" } == false)
    }

    @Test("a sub-cent delta emits no row rather than rendering $0.00")
    func subCentDeltaEmitsNoRow() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(40.001)])
        let current = usage(spentToday: 20, monthTotal: 120, models: [("a", 40.004, 100)])
        let s = split(TodayModelSplitEngine.split(current: current, baseline: base))
        #expect(s?.rows.contains { $0.name == "a" } == false)
    }

    // MARK: - The Other row

    @Test("Other is suppressed when the named rows already explain the day to the cent")
    func otherRowIsSuppressedWhenTheGapIsSubCent() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(40)])
        let current = usage(spentToday: 20, monthTotal: 120, models: [("a", 60, 100)])
        let s = split(TodayModelSplitEngine.split(current: current, baseline: base))
        #expect(s?.rows.contains { $0.isOther } == false)
        #expect(s?.rows.count == 1)
    }

    @Test("Other is always last and flagged isOther")
    func otherRowIsAlwaysLastAndFlaggedIsOther() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(10), "b": point(20)])
        let current = usage(spentToday: 60, monthTotal: 160, models: [("a", 40, 100), ("b", 25, 100)])
        let s = split(TodayModelSplitEngine.split(current: current, baseline: base))
        #expect(s?.rows.last?.isOther == true)
        #expect(s?.rows.dropLast().contains { $0.isOther } == false)
    }

    @Test("named rows are sorted descending by cost")
    func namedRowsAreSortedDescendingByCost() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["small": point(0), "big": point(0)])
        let current = usage(spentToday: 50, monthTotal: 150, models: [("small", 5, 100), ("big", 45, 100)])
        let s = split(TodayModelSplitEngine.split(current: current, baseline: base))
        #expect(s?.rows.first?.name == "big")
    }

    // MARK: - Reconciliation guards

    @Test("named deltas exceeding the day total bails to overAttributed, never a non-tying split")
    func overAttributionBailsToUnavailable() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(0), "b": point(0)])
        // Deltas explain 60 but the day total is 50 — the baseline is wrong.
        let current = usage(spentToday: 50, monthTotal: 160, models: [("a", 40, 100), ("b", 20, 100)])
        #expect(reason(TodayModelSplitEngine.split(current: current, baseline: base)) == .overAttributed)
    }

    @Test("over-attribution has no tolerance slack — a $0.40 excess bails even though restatement tolerance would be $0.50")
    func overAttributionHasNoToleranceSlack() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(0)])
        let current = usage(spentToday: 50, monthTotal: 150.40, models: [("a", 50.40, 100)])
        #expect(reason(TodayModelSplitEngine.split(current: current, baseline: base)) == .overAttributed)
    }

    @Test("a month total regressed beyond tolerance bails to monthRegressed (the rollover case)")
    func monthRegressionBailsToUnavailable() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 200, models: ["a": point(40)])
        let current = usage(spentToday: 10, monthTotal: 100, models: [("a", 41, 100)])
        #expect(reason(TodayModelSplitEngine.split(current: current, baseline: base)) == .monthRegressed)
    }

    @Test("a few cents of downward month restatement within tolerance still splits")
    func tinyMonthRestatementWithinToleranceStillSplits() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100.00, models: ["a": point(40)])
        let current = usage(spentToday: 20, monthTotal: 99.90, models: [("a", 60, 100)])
        #expect(split(TodayModelSplitEngine.split(current: current, baseline: base)) != nil)
    }

    @Test("a different month key bails even when the month total grew")
    func differentMonthKeyBailsEvenWhenTheMonthTotalGrew() {
        let base = snapshot(monthKey: "2026-07", monthTotal: 500, models: ["a": point(40)])
        let current = usage(spentToday: 20, monthTotal: 600, models: [("a", 60, 100)])
        #expect(reason(TodayModelSplitEngine.split(current: current, baseline: base)) == .monthChanged)
    }

    // MARK: - monthKey (label, not instant)

    @Test("monthKey reads the label's month on a non-UTC-midnight seam, not the UTC month")
    func monthKeyReadsLabelNotInstantOnMonthSeam() {
        // "2026-08-01T00:00:00+03:00" is the gateway's label for Aug 1. Parsed
        // as an INSTANT it is Jul 31 21:00 UTC → month "2026-07", so the split
        // would bail "monthChanged" against a correct Aug baseline and stay
        // unavailable an extra day. On the LABEL the month is "2026-08".
        #expect(TodayModelSplitEngine.monthKey(of: "2026-08-01T00:00:00+03:00") == "2026-08")
        // Same label rule mid-month, and the bare-date shape stays stable.
        #expect(TodayModelSplitEngine.monthKey(of: "2026-08-10T00:00:00+03:00") == "2026-08")
        #expect(TodayModelSplitEngine.monthKey(of: "2026-08-10") == "2026-08")
    }

    // MARK: - Baseline absence and trivial states

    @Test("a nil baseline returns noBaseline (first run / app off across the seam)")
    func nilBaselineReturnsNoBaseline() {
        let current = usage(spentToday: 20, monthTotal: 120, models: [("a", 60, 100)])
        #expect(reason(TodayModelSplitEngine.split(current: current, baseline: nil)) == .noBaseline)
    }

    @Test("zero spend today returns noSpendYet — no split before any spend")
    func zeroSpendTodayReturnsNoSpendYet() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(40)])
        let current = usage(spentToday: 0, monthTotal: 100, models: [("a", 40, 100)])
        #expect(reason(TodayModelSplitEngine.split(current: current, baseline: base)) == .noSpendYet)
    }

    // MARK: - Tokens and wording

    @Test("a negative token delta clamps to zero so the efficiency column renders an em-dash")
    func tokenDeltaClampsAtZeroSoEfficiencyRendersEmDash() {
        let base = snapshot(monthKey: "2026-08", monthTotal: 100, models: ["a": point(40, 5_000_000)])
        let current = usage(spentToday: 20, monthTotal: 120, models: [("a", 60, 4_000_000)])
        let row = split(TodayModelSplitEngine.split(current: current, baseline: base))?.rows.first { $0.name == "a" }
        #expect(row?.tokens == 0)
    }

    @Test("the unavailable-reason note wording is exact")
    func unavailableReasonNoteWordingIsExact() {
        #expect(TodayModelSplitResult.Reason.noBaseline.note == "Per-model split starts after the next gateway day")
        #expect(TodayModelSplitResult.Reason.monthChanged.note == "Per-model split resumes tomorrow (new month)")
        #expect(TodayModelSplitResult.Reason.monthRegressed.note == "Per-model split resumes tomorrow (new month)")
        #expect(TodayModelSplitResult.Reason.overAttributed.note == "Per-model split needs one full day of the app running")
        #expect(TodayModelSplitResult.Reason.noSpendYet.note == nil)
    }
}
