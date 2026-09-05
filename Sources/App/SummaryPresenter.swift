// Sources/App/SummaryPresenter.swift
// WP-06 06.1: builds the immutable SummaryDisplayState from a PollOutcome
// and repository context. Pure derivation — no Keychain, no network, no
// disk reads while constructing or applying a state (§7.2). This is where
// derived values (pace sentence, model rows, share percents, freshness
// text) are computed ONCE per poll instead of being reparsed in child
// views on every render.
// Why: the popover used to derive all of that inside its layout pass from
// raw fetch state; centralizing it here makes display state Equatable and
// testable without AppKit.
// RELEVANT FILES: Sources/VelaCore/SummaryDisplayState.swift,
// Sources/App/PollCoordinator.swift, Sources/App/AppCoordinator.swift,
// Sources/VelaCore/PaceEngine.swift

import Foundation

/// Turns the poll pipeline's committed state into display values.
@MainActor
public final class SummaryPresenter {

    /// Inputs captured per poll: the committed snapshot, the connection
    /// state it left, and the legacy HistoryStore view the curve/strip
    /// still render from (v1 views; WP-07 owns the visual conversion).
    public struct Context {
        public let snapshot: UsageSnapshot?
        public let connection: ConnectionState
        public let repository: HistoryRepository

        public init(snapshot: UsageSnapshot?, connection: ConnectionState, repository: HistoryRepository) {
            self.snapshot = snapshot
            self.connection = connection
            self.repository = repository
        }
    }

    public init() {}

    // MARK: - Display state

    /// Builds the full display state. `now` is injectable so tests pin
    /// freshness and pace text. Rows are stable-ID: the "Other" residual
    /// and month rows keep their IDs across refreshes.
    public func displayState(
        from context: Context,
        selectedPeriod: String,
        now: Date
    ) -> SummaryDisplayState {
        guard let snapshot = context.snapshot else {
            // No committed reading yet: the honest connecting state. The
            // view's loading branch renders this without touching data.
            return SummaryDisplayState(
                hero: SummaryDisplayState.Row(id: "hero", title: "$0.00", detail: "", fraction: nil),
                rows: [],
                selectedPeriod: selectedPeriod,
                selectedPeriodTotalUSD: 0,
                freshnessText: Self.freshnessText(
                    for: context.connection, receivedAt: nil, now: now,
                    freshness: Freshness.derive(receivedAt: nil, now: now)
                ),
                accessibilitySummary: "Connecting to AI Hub."
            )
        }

        let budget = snapshot.response.dailyBudget
        // Derive freshness ONCE on the injected clock — the row fold, the
        // freshness line, and the accessibility text all gate on it.
        let freshness = Freshness.derive(receivedAt: snapshot.receivedAt, now: now)

        // Hero: real spend even when the limit is disabled — "$0.00" lies.
        let heroDetail = budget.limitEnabled
            ? String(format: " of $%.0f today", budget.limitUSD)
            : " today · no daily limit"
        let hero = SummaryDisplayState.Row(
            id: "hero",
            title: String(format: "$%.2f", budget.spentUSD),
            detail: heroDetail,
            fraction: budget.limitEnabled ? min(max(budget.usedPercent / 100, 0), 1) : nil
        )

        // Model rows for the selected period. Today uses the validated
        // today_models fold; month uses the API's top_models directly.
        let rows: [SummaryDisplayState.Row]
        if selectedPeriod == "today" {
            rows = Self.todayRows(snapshot: snapshot, dayTotal: budget.spentUSD, freshness: freshness)
        } else {
            rows = Self.monthRows(response: snapshot.response)
        }
        let periodTotal = selectedPeriod == "today"
            ? budget.spentUSD
            : snapshot.response.currentMonth.totalCostUSD
        let freshnessLine = Self.freshnessText(
            for: context.connection, receivedAt: snapshot.receivedAt,
            now: now, freshness: freshness
        )
        return SummaryDisplayState(
            hero: hero,
            rows: rows,
            selectedPeriod: selectedPeriod,
            selectedPeriodTotalUSD: periodTotal,
            freshnessText: freshnessLine,
            accessibilitySummary: Self.accessibilitySummary(
                hero: hero, period: selectedPeriod, total: periodTotal,
                freshnessText: freshnessLine
            )
        )
    }

    // MARK: - Row folds (stable IDs)

    /// Today rows: up to 4 named models + pinned "other". IDs are the
    /// model name (the gateway's identity for a model is its name), the
    /// Other bucket is pinned "other".
    private static func todayRows(snapshot: UsageSnapshot, dayTotal: Double, freshness: Freshness) -> [SummaryDisplayState.Row] {
        // B07: rows that don't reconcile with the day total render as
        // total-only — never numbers that sum past the hero figure.
        guard case .fresh = freshness else {
            // DESIGN.md §5.3 state/copy matrix, stale state: the models
            // section states WHY it has no rows — never a silent blank.
            return [SummaryDisplayState.Row(
                id: "stale-breakdown",
                title: "Per-model breakdown needs a fresh reading",
                detail: "will return when the next poll lands",
                fraction: nil
            )]
        }
        switch snapshot.modelData {
        case .available:
            let folded = TodayModelRows.rows(from: snapshot.response.todayModels, dayTotal: dayTotal)
            guard !folded.isEmpty else { return [] }
            return folded.map { row in
                let share = ModelShare.percent(cost: row.costUSD, total: dayTotal)
                return SummaryDisplayState.Row(
                    id: row.isOther ? "other" : "model-\(row.name)",
                    title: row.name,
                    detail: String(format: "$%.2f", row.costUSD),
                    fraction: row.isOther ? nil : Double(share) / 100
                )
            }
        case .empty:
            return []
        case .unavailable:
            return [SummaryDisplayState.Row(id: "unavailable", title: "Per-model breakdown is monthly only", detail: "this gateway build does not report per-model daily spend", fraction: nil)]
        case .inconsistent(let reason):
            return [SummaryDisplayState.Row(id: "inconsistent", title: "Model breakdown inconsistent", detail: reason, fraction: nil)]
        }
    }

    /// Month rows: the API's top_models against the authoritative month
    /// total (B08 denominator rule).
    private static func monthRows(response: UsageResponse) -> [SummaryDisplayState.Row] {
        let total = response.currentMonth.totalCostUSD
        guard total > 0 else { return [] }
        return response.topModels.map { model in
            let share = ModelShare.percent(cost: model.totalCostUSD, total: total)
            return SummaryDisplayState.Row(
                id: "model-\(model.model)",
                title: model.model,
                detail: String(format: "$%.2f", model.totalCostUSD),
                fraction: Double(share) / 100
            )
        }
    }

    // MARK: - Text derivations

    /// The freshness line, from an ALREADY-DERIVED verdict. `displayState`
    /// derives freshness exactly once on the injected clock; this function
    /// only words it — it never derives. Fresh copy per DESIGN.md §5.1
    /// status slot: "Latest observation · HH:mm · resets at UTC midnight"
    /// where HH:mm is the OBSERVATION time (UTC), never the current time.
    nonisolated static func freshnessText(
        for connection: ConnectionState,
        receivedAt: Date?,
        now: Date,
        freshness: Freshness
    ) -> String {
        switch connection {
        case .authenticationRequired:
            return "Token rejected — action needed"
        case .invalidResponse:
            return "Gateway sent unreadable data"
        case .connecting, .noCredential, .keychainBlocked, .retrying:
            return "Connecting to AI Hub…"
        case .live, .stale:
            if freshness.isFresh, let receivedAt {
                // The observation's own receipt time — labeling `now` here
                // would present the wall clock as the observation.
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                formatter.timeZone = TimeZone(identifier: "UTC")!
                let clock = formatter.string(from: receivedAt)
                return "Latest observation · \(clock) · resets at UTC midnight"
            }
            guard let receivedAt else { return "Waiting for first reading" }
            let minutes = max(0, Int(now.timeIntervalSince(receivedAt) / 60))
            return "Last reading · \(minutes)m ago"
        }
    }

    /// No-snapshot overload for the loading state: nothing observed yet, so
    /// deriving is safe (receivedAt is nil either way).

    private static func accessibilitySummary(
        hero: SummaryDisplayState.Row,
        period: String,
        total: Double,
        freshnessText: String
    ) -> String {
        "\(hero.title)\(hero.detail). \(period) total \(String(format: "$%.2f", total)). \(freshnessText)."
    }
}
