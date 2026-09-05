// Sources/VelaCore/TodayModelRows.swift
// Folds the gateway's real-time `today_models` array (already cost-descending,
// already capped at 5) into display rows: up to 4 named models plus one
// pinned "Other" row that absorbs any remainder.
// Why: the gateway used to expose only month-cumulative per-model figures, so
// "today by model" had to be derived by differencing two snapshots — a whole
// subsystem of guesswork (baseline lookups, month-seam guards, over-
// attribution bailouts). The gateway now returns today's per-model totals
// directly (see `UsageResponse.todayModels` / `.today`), so there is nothing
// left to derive: this type is a pure display fold, not a derivation. It
// does not re-sort or re-rank — it trusts the gateway's ordering — and it
// exists only to compact 5 gateway rows into the app's 4-named-plus-Other
// display shape and to reconcile the residual against the authoritative day
// total (`daily_budget.spent_usd`), which can exceed the sum of one token's
// `today_models` when the user has more than one active gateway token.
// RELEVANT FILES: Tests/VelaCoreTests/TodayModelRowsTests.swift, Sources/VelaCore/Models.swift

import Foundation

/// One row of the Today-by-model display.
public struct TodayModelRow: Equatable, Sendable {
    public let name: String
    public let costUSD: Double
    public let tokens: Int
    /// The residual bucket that absorbs a real 5th-model tail and/or the gap
    /// between this token's today total and the whole user's day spend.
    /// Renders without a bar, tokens as "—".
    public let isOther: Bool

    public init(name: String, costUSD: Double, tokens: Int, isOther: Bool) {
        self.name = name
        self.costUSD = costUSD
        self.tokens = tokens
        self.isOther = isOther
    }
}

/// Pure fold from the gateway's `today_models` + `today`/`daily_budget` totals
/// to display rows. No clock, no I/O, no re-sorting: the input is already
/// cost-descending and already capped at 5 by the gateway.
public enum TodayModelRows {
    /// Sub-cent amounts round-trip the display as $0.00, so they're noise —
    /// both for "has anything been spent today" and for "is the Other
    /// residual worth a row". Same epsilon the retired differencing engine
    /// used, kept for continuity of the displayed numbers.
    private static let displayEpsilon = 0.005

    /// 4 named rows + 1 pinned Other = 5 total, matching the gateway's cap
    /// and the app's existing 5-slot display block.
    public static let maxNamedRows = 4

    public static func rows(from models: [ModelUsage], dayTotal: Double) -> [TodayModelRow] {
        // Nothing spent today: no rows, regardless of what `models` says.
        guard dayTotal > displayEpsilon else { return [] }

        // Defensive: a positive day total with no model rows can't be
        // rendered as named rows, so fall back to empty rather than guessing.
        guard !models.isEmpty else { return [] }

        let named = models.prefix(maxNamedRows).map { model in
            TodayModelRow(name: model.model, costUSD: model.totalCostUSD, tokens: model.totalTokens, isOther: false)
        }

        let namedSum = named.reduce(0) { $0 + $1.costUSD }
        let other = dayTotal - namedSum

        // `other` absorbs a real 5th-model tail (dropped by `prefix`) and any
        // multi-token gap between this token's named sum and the whole
        // user's day total. A non-positive or dust-sized remainder is never
        // shown — floating-point noise or a data anomaly must not render a
        // negative or all-but-empty reconciliation row.
        guard other > displayEpsilon else { return named }

        return named + [TodayModelRow(name: "Other", costUSD: other, tokens: 0, isOther: true)]
    }
}
