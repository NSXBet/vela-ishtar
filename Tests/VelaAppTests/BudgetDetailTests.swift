// Tests/VelaAppTests/BudgetDetailTests.swift
// WP-08 08.2/08.3: the detail-surface tests. Pins the view's copy builders —
// row values, freshness wording, the availability disclaimer, stable row IDs
// — and the cooldown-expiry behavior: exactly ONE scheduled redraw, armed
// only while a cooldown is pending, never a repeating timer. View rendering
// itself runs on @MainActor via Swift Concurrency's MainActor.run so no
// window/panel is needed.
// RELEVANT FILES: Sources/App/BudgetDetailView.swift, Sources/VelaCore/BudgetOverview.swift,
// Tests/VelaCoreTests/BudgetOverviewTests.swift

import AppKit
import Foundation
import Testing
@testable import VelaCore

@MainActor
@Suite("BudgetDetailView")
struct BudgetDetailTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: fixtures (same builders as the core suite — one shape, reused)

    private static func overview(
        globalLimit: Double = 400,
        globalSpent: Double = 60,
        limitEnabled: Bool = true,
        models: [ModelBudget] = [],
        freshness: Freshness = .fresh(receivedAt: now, maxAgeSeconds: Freshness.maxAgeSeconds)
    ) -> BudgetOverview {
        let budget = DailyBudget(
            limitUSD: globalLimit, spentUSD: globalSpent,
            remainingUSD: max(0, globalLimit - globalSpent),
            usedPercent: globalLimit > 0 ? globalSpent / globalLimit * 100 : 0,
            limitEnabled: limitEnabled, spendDate: "2026-09-05",
            modelBudgets: models
        )
        let response = UsageResponse(
            tokenId: "11111111-2222-4333-8444-555555555555",
            dailyBudget: budget,
            currentMonth: MonthStats(totalCostUSD: globalSpent, totalTokens: 1_000, requests: 10),
            topModels: []
        )
        let snapshot = UsageValidation.snapshot(
            from: response,
            scope: UsageScope(kind: .credential, opaqueID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, gatewayOrigin: "https://gateway.test"),
            receivedAt: now
        )
        return BudgetOverview.derive(from: snapshot, freshness: freshness, now: now, calendar: utcCalendar)
    }

    private static func cap(
        model: String, spent: Double, limit: Double, relaxedUntil: String? = nil
    ) -> ModelBudget {
        ModelBudget(
            model: model, spentUSD: spent, limitUSD: limit,
            remainingUSD: max(0, limit - spent),
            percentUsed: limit > 0 ? spent / limit * 100 : 0,
            cooldownEligible: relaxedUntil != nil,
            cooldown: relaxedUntil.map { ModelCooldown(createdAt: nil, relaxedUntil: $0) }
        )
    }

    // MARK: row copy (08.2)

    @Test("row value shows spend, cap, and room for an enabled cap")
    func rowValueEnabledCap() {
        let value = BudgetDetailView.rowValue(BudgetOverview.ModelSignal(
            model: "aihub/claude-opus-5", spentUSD: 15, limitUSD: 20, headroomUSD: 5, relaxedUntil: nil
        ))
        #expect(value == "$15.00 of $20 · $5.00 room")
    }

    @Test("row value with unknown room never invents a number")
    func rowValueUnknownRoom() {
        let value = BudgetDetailView.rowValue(BudgetOverview.ModelSignal(
            model: "aihub/odd-model", spentUSD: 3, limitUSD: 20, headroomUSD: nil, relaxedUntil: nil
        ))
        #expect(value.contains("room unknown"))
        #expect(value.hasSuffix("room unknown"))
    }

    @Test("failed refresh at expiry → stale freshness renders as last observed")
    func staleRendersAsLastObserved() {
        let lastObserved = Self.now.addingTimeInterval(-120)
        let text = BudgetDetailView.freshnessText(
            overview: Self.overview(freshness: .stale(lastReceivedAt: lastObserved)),
            calendar: Self.utcCalendar
        )
        #expect(text.hasPrefix("last observed"))
        #expect(text != "current")

        let invalidated = BudgetDetailView.freshnessText(
            overview: Self.overview(freshness: .invalidated(reason: "authentication failure")),
            calendar: Self.utcCalendar
        )
        #expect(invalidated == "last observed: unknown")
    }

    @Test("fresh readings say current; disabled global says no limit")
    func freshAndDisabledCopy() {
        let fresh = BudgetDetailView.freshnessText(
            overview: Self.overview(), calendar: Self.utcCalendar
        )
        #expect(fresh == "current")

        let summary = BudgetDetailView.accessibilitySummary(
            overview: Self.overview(limitEnabled: false), calendar: Self.utcCalendar
        )
        #expect(summary.hasPrefix("No global daily limit"))
    }

    @Test("row IDs derive from the gateway route ID, stable across refreshes")
    func rowIDsAreStable() {
        let id = BudgetDetailView.rowID(for: "aihub/claude-opus-5")
        #expect(id == BudgetDetailView.rowID(for: "aihub/claude-opus-5"))
        #expect(id != BudgetDetailView.rowID(for: "aihub/claude-haiku-5"))
        #expect(id.contains("aihub/claude-opus-5"))
    }

    @Test("disclaimer states returned limits are not a model-availability catalog")
    func disclaimerPresent() {
        #expect(BudgetDetailView.disclaimerText.contains("not a complete model catalog"))
        #expect(BudgetDetailView.disclaimerText.contains("Other limits may apply"))
    }

    @Test("accessibility summary covers global, every cap, reset, freshness, disclaimer")
    func accessibilitySummaryComplete() {
        let summary = BudgetDetailView.accessibilitySummary(
            overview: Self.overview(globalLimit: 400, globalSpent: 360, models: [
                Self.cap(model: "aihub/relaxed-model", spent: 19, limit: 20, relaxedUntil: "2026-09-05T12:00:00Z"),
                Self.cap(model: "aihub/blocked-model", spent: 2, limit: 0),
            ]),
            calendar: Self.utcCalendar
        )

        // Global.
        #expect(summary.contains("Global budget $360.00 of $400"))
        // Every concurrent condition surfaces — relaxed AND blocked both named.
        #expect(summary.contains("Relaxed Model"))
        #expect(summary.contains("Blocked Model"))
        #expect(summary.contains("blocked"))
        #expect(summary.contains("relaxed until"))
        // Reset + freshness + honesty footer.
        #expect(summary.contains("resets at UTC midnight"))
        #expect(summary.contains("current"))
        #expect(summary.contains("not a complete model catalog"))
    }

    @Test("no model caps → summary is global + reset + freshness + disclaimer only")
    func emptyModelSummary() {
        let summary = BudgetDetailView.accessibilitySummary(
            overview: Self.overview(models: []), calendar: Self.utcCalendar
        )
        #expect(summary.contains("Global budget $60.00 of $400"))
        #expect(!summary.contains("Model"))
    }

    // MARK: rendering + cooldown expiry (08.3)

    @Test("render produces a subview per cap plus global/notes rows")
    func renderProducesRows() {
        let view = BudgetDetailView(overview: Self.overview(models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 15, limit: 20),
            Self.cap(model: "aihub/blocked-model", spent: 2, limit: 0),
        ]), calendar: Self.utcCalendar)

        // 1 vertical stack; inside it: global + 2 cap rows + reset + freshness + disclaimer.
        let stack = view.subviews.first as? NSStackView
        #expect(stack != nil)
        #expect(stack?.arrangedSubviews.count == 6)

        let ids = stack?.arrangedSubviews.compactMap { $0.identifier?.rawValue }
        #expect(ids == [BudgetDetailView.rowID(for: "aihub/claude-opus-5"),
                        BudgetDetailView.rowID(for: "aihub/blocked-model")])
    }

    @Test("cooldown expiry fires exactly one redraw, then none — no repeating timer")
    func cooldownExpirySingleRedraw() async {
        // Whole-second stamps because ISO8601DateFormatter output is second-
        // precise. Stamping the NEXT whole second keeps relaxedUntil genuinely
        // future on the wall clock no matter where inside the second the test
        // starts; it expires ~1-2s later.
        let calendar = Self.utcCalendar
        let whole = ISODate.parse(ISO8601DateFormatter().string(from: Date()))!
        let expiry = whole.addingTimeInterval(2.0)
        let relaxedStamp = ISO8601DateFormatter().string(from: whole.addingTimeInterval(1.0))
        let response = UsageResponse(
            tokenId: "11111111-2222-4333-8444-555555555555",
            dailyBudget: DailyBudget(
                limitUSD: 400, spentUSD: 360, remainingUSD: 40, usedPercent: 90,
                limitEnabled: true, spendDate: "1970-01-12",
                modelBudgets: [Self.cap(model: "aihub/relaxed-model", spent: 19, limit: 20,
                                        relaxedUntil: relaxedStamp)]
            ),
            currentMonth: MonthStats(totalCostUSD: 360, totalTokens: 1_000, requests: 10),
            topModels: []
        )
        let snapshot = UsageValidation.snapshot(
            from: response,
            scope: UsageScope(kind: .credential, opaqueID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, gatewayOrigin: "https://gateway.test"),
            receivedAt: expiry
        )
        // Derive BEFORE the cooldown instant so it is still active at
        // construction; it then expires ~1-2s later on the wall clock.
        let derived = BudgetOverview.derive(
            from: snapshot,
            freshness: .fresh(receivedAt: whole, maxAgeSeconds: Freshness.maxAgeSeconds),
            now: whole.addingTimeInterval(-0.1),
            calendar: calendar
        )
        #expect(derived.modelSignals.count == 1)
        #expect(derived.modelSignals[0].relaxedUntil == whole.addingTimeInterval(1.0), "fixture must produce an ACTIVE cooldown")

        var expiryRedraws = 0
        let view = BudgetDetailView(overview: derived, calendar: calendar)
        view.onCooldownExpired = { expiryRedraws += 1 }

        // The scheduled invalidation is the ONLY mechanism — assert exactly
        // one fire within a bounded window, then silence.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(expiryRedraws == 1)
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(expiryRedraws == 1, "no repeating timer — one redraw only")
    }

    @Test("no pending cooldown → no scheduled invalidation")
    func noCooldownNoInvalidation() async {
        var fires = 0
        let view = BudgetDetailView(overview: Self.overview(models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 15, limit: 20),
        ]), calendar: Self.utcCalendar)
        view.onCooldownExpired = { fires += 1 }

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(fires == 0)
    }

    @Test("re-render replaces rows; stale rows removed")
    func rerenderReplacesRows() {
        let view = BudgetDetailView(overview: Self.overview(models: [
            Self.cap(model: "aihub/claude-opus-5", spent: 15, limit: 20),
        ]), calendar: Self.utcCalendar)

        view.render(overview: Self.overview(models: [
            Self.cap(model: "aihub/claude-haiku-5", spent: 5, limit: 20),
        ]))

        let stack = view.subviews.first as? NSStackView
        let ids = stack?.arrangedSubviews.compactMap { $0.identifier?.rawValue }
        #expect(ids == [BudgetDetailView.rowID(for: "aihub/claude-haiku-5")])
    }
}
