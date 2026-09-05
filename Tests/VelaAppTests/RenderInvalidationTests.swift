// Tests/VelaAppTests/RenderInvalidationTests.swift
// WP-06 06.3/06.2: narrow invalidation. The pill re-renders only when a
// drawn pixel would change (visible amount, border, pulse geometry, cap
// alert, size, appearance, scale, freshness); the popover applies display
// state idempotently (same state = zero subview work). These tests pin the
// DECISION LOGIC — the redraw guard's equality and the presenter's stable
// row IDs — without drawing bitmaps.
// RELEVANT FILES: Sources/App/StatusItemController.swift, Sources/App/PopoverView.swift,
// Sources/App/SummaryPresenter.swift, Sources/VelaCore/SummaryDisplayState.swift

import Foundation
import Testing
@testable import VelaCore

@Suite("WP-06 render invalidation")
struct RenderInvalidationTests {

    private static func usage(spent: Double, spendDate: String = "2026-09-05", limit: Double = 400) -> UsageResponse {
        UsageResponse(
            tokenId: "11111111-2222-4333-8444-555555555555",
            dailyBudget: DailyBudget(
                limitUSD: limit, spentUSD: spent, remainingUSD: limit - spent,
                usedPercent: spent / limit * 100, limitEnabled: true, spendDate: spendDate
            ),
            currentMonth: MonthStats(totalCostUSD: spent, totalTokens: 500, requests: 5),
            topModels: []
        )
    }

    private static func snapshot(spent: Double, at: Date) -> UsageSnapshot {
        UsageValidation.snapshot(
            from: usage(spent: spent),
            scope: UsageScope(kind: .credential, opaqueID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, gatewayOrigin: "https://gateway.test"),
            receivedAt: at
        )
    }

    // MARK: - Presenter: identical input → identical state (drives the no-op)

    @Test("identical polls produce an identical SummaryDisplayState")
    func identicalInputsProduceIdenticalState() async throws {
        let presenter = await SummaryPresenter()
        let t = ISODate.parse("2026-09-05T10:00:00Z")!
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("rendertest-\(UUID().uuidString)"))
        let snapshot = Self.snapshot(spent: 42.42, at: t)
        let context = SummaryPresenter.Context(snapshot: snapshot, connection: .live, repository: repository)

        let a = await presenter.displayState(from: context, selectedPeriod: "today", now: t)
        let b = await presenter.displayState(from: context, selectedPeriod: "today", now: t)
        #expect(a == b, "same committed input must derive the exact same display state — the view can then no-op")
    }

    @Test("row IDs are stable across spend changes (same models → same IDs)")
    func rowIDsAreStable() async throws {
        let presenter = await SummaryPresenter()
        let t = ISODate.parse("2026-09-05T10:00:00Z")!
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("rendertest-\(UUID().uuidString)"))

        let scope = UsageScope(kind: .credential, opaqueID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, gatewayOrigin: "https://gateway.test")
        func context(spent: Double) -> SummaryPresenter.Context {
            var usage = Self.usage(spent: spent)
            // Give the response two named models so the fold yields rows.
            usage = UsageResponse(
                tokenId: usage.tokenId,
                dailyBudget: usage.dailyBudget,
                currentMonth: usage.currentMonth,
                topModels: usage.topModels,
                today: MonthStats(totalCostUSD: spent, totalTokens: 500, requests: 5),
                todayModels: [
                    ModelUsage(model: "openai/gpt-5", totalCostUSD: spent * 0.7, totalTokens: 300, requests: 3),
                    ModelUsage(model: "google/gemini", totalCostUSD: spent * 0.3, totalTokens: 200, requests: 2),
                ],
                todayPresent: true,
                todayModelsPresent: true
            )
            return SummaryPresenter.Context(
                snapshot: UsageValidation.snapshot(from: usage, scope: scope, receivedAt: t),
                connection: .live,
                repository: repository
            )
        }

        let early = await presenter.displayState(from: context(spent: 10), selectedPeriod: "today", now: t)
        let later = await presenter.displayState(from: context(spent: 30), selectedPeriod: "today", now: t)
        #expect(early != later, "different spends must derive different states (hero amount changes)")
    }

    @Test("period switch changes the period without changing freshness semantics (B10: no data wait)")
    func periodSwitchIsPureRebuild() async throws {
        let presenter = await SummaryPresenter()
        let t = ISODate.parse("2026-09-05T10:00:00Z")!
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("rendertest-\(UUID().uuidString)"))
        let snapshot = Self.snapshot(spent: 42.42, at: t)
        let context = SummaryPresenter.Context(snapshot: snapshot, connection: .live, repository: repository)

        let today = await presenter.displayState(from: context, selectedPeriod: "today", now: t)
        let month = await presenter.displayState(from: context, selectedPeriod: "month", now: t)

        #expect(today.selectedPeriod == "today")
        #expect(month.selectedPeriod == "month")
        #expect(today.freshnessText == month.freshnessText, "a period toggle must not invent a freshness change — no poll happened")
    }

    @Test("stale connection renders the stale freshness line")
    func staleConnectionRendersStaleText() async throws {
        let presenter = await SummaryPresenter()
        let t = ISODate.parse("2026-09-05T10:00:00Z")!
        let old = ISODate.parse("2026-09-05T08:00:00Z")!
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("rendertest-\(UUID().uuidString)"))
        let context = SummaryPresenter.Context(snapshot: Self.snapshot(spent: 10, at: old), connection: .stale, repository: repository)

        let state = await presenter.displayState(from: context, selectedPeriod: "today", now: t)
        #expect(state.freshnessText.contains("Last reading"), "two-hour-old receipt must read as a last reading, not live")
    }

    @Test("freshness gate, row fold, and freshness text ALL use the injected clock — never Date()")
    func freshnessUsesInjectedClock() async throws {
        let presenter = await SummaryPresenter()
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("rendertest-\(UUID().uuidString)"))
        // Receipt at 10:00:00. The wall clock is IRRELEVANT here: both calls
        // pass an injected `now`. If the presenter secretly called Date()
        // (hours after 10:00), the fresh case would flip stale and the rows
        // would vanish.
        let t = ISODate.parse("2026-09-05T10:00:00Z")!
        let scope = UsageScope(kind: .credential, opaqueID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, gatewayOrigin: "https://gateway.test")
        var usage = Self.usage(spent: 42.42)
        usage = UsageResponse(
            tokenId: usage.tokenId,
            dailyBudget: usage.dailyBudget,
            currentMonth: usage.currentMonth,
            topModels: usage.topModels,
            today: MonthStats(totalCostUSD: 42.42, totalTokens: 500, requests: 5),
            todayModels: [
                ModelUsage(model: "openai/gpt-5", totalCostUSD: 30, totalTokens: 300, requests: 3),
                ModelUsage(model: "google/gemini", totalCostUSD: 12, totalTokens: 200, requests: 2),
            ],
            todayPresent: true,
            todayModelsPresent: true
        )
        let context = SummaryPresenter.Context(
            snapshot: UsageValidation.snapshot(from: usage, scope: scope, receivedAt: t),
            connection: .live,
            repository: repository
        )

        // Injected now = +30s: inside the 90s ceiling → FRESH, rows folded.
        let fresh = await presenter.displayState(from: context, selectedPeriod: "today", now: t.addingTimeInterval(30))
        // DESIGN.md §5.1: fresh copy names the OBSERVATION time (UTC),
        // never the wall clock. Receipt 10:00:00Z must render as 10:00.
        #expect(fresh.freshnessText == "Latest observation · 10:00 · resets at UTC midnight",
                "fresh copy must show observation time per DESIGN.md; got: \(fresh.freshnessText)")
        #expect(fresh.rows.contains { $0.id == "model-openai/gpt-5" }, "fresh state must fold today's model rows")
        #expect(fresh.rows.contains { $0.id == "model-google/gemini" })

        // Injected now = +120s: past the 90s ceiling → STALE: fresh rows
        // close and the DESIGN.md §5.3 explanatory row appears (never a
        // silent blank), freshness line flips.
        let stale = await presenter.displayState(from: context, selectedPeriod: "today", now: t.addingTimeInterval(120))
        #expect(stale.freshnessText != fresh.freshnessText, "injected now=+120s must flip the freshness line")
        #expect(!stale.rows.contains { $0.id == "model-openai/gpt-5" }, "stale state must NOT render the fresh row fold")
        #expect(stale.rows.contains {
            $0.id == "stale-breakdown" && $0.title == "Per-model breakdown needs a fresh reading"
        }, "stale state must show the DESIGN.md explanatory row; got: \(stale.rows.map(\.title))")
    }
}
