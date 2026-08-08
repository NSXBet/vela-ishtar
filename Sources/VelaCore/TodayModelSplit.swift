// Sources/VelaCore/TodayModelSplit.swift
// Derives TODAY's per-model spend by differencing two month-cumulative
// top_models snapshots (yesterday's baseline vs. the current response),
// reconciled against the authoritative daily_budget.spent_usd so the rows
// always sum to the day total.
// Why: the API only exposes month-cumulative per-model figures, so "today
// by model" is a derived number. The derivation can lie (truncated
// top_models, cross-midnight snapshots, month rollovers) — every guard
// here exists to prefer a labeled fallback over a confident wrong number.
// RELEVANT FILES: Tests/VelaCoreTests/TodayModelSplitTests.swift, Sources/VelaCore/ModelSnapshots.swift, Sources/VelaCore/PollStateMachine.swift

import Foundation

/// One row of the Today-by-model breakdown.
public struct TodayModelRow: Equatable, Sendable {
    public let name: String
    public let costUSD: Double
    public let tokens: Int
    /// The residual bucket that absorbs truncation/dropped/new models so the
    /// rows still tie to the day total. Renders without a bar, tokens as "—".
    public let isOther: Bool

    public init(name: String, costUSD: Double, tokens: Int, isOther: Bool) {
        self.name = name
        self.costUSD = costUSD
        self.tokens = tokens
        self.isOther = isOther
    }
}

/// The derived split: named rows (cost desc) + an optional pinned-last
/// Other row. `totalUSD` is the authoritative daily_budget.spent_usd.
public struct TodayModelSplit: Equatable, Sendable {
    public let rows: [TodayModelRow]
    public let totalUSD: Double

    public init(rows: [TodayModelRow], totalUSD: Double) {
        self.rows = rows
        self.totalUSD = totalUSD
    }
}

public enum TodayModelSplitResult: Equatable, Sendable {
    case split(TodayModelSplit)
    case unavailable(Reason)

    public enum Reason: Equatable, Sendable {
        /// No yesterday snapshot yet (first run, or app was off over the seam).
        case noBaseline
        /// The nearest stored snapshot isn't exactly one day behind today.
        case baselineNotAdjacent
        /// Baseline and current are in different UTC months (rollover seam).
        case monthChanged
        /// current_month.total_cost_usd fell below the baseline's beyond
        /// tolerance — the month series was reset/restated underneath us.
        case monthRegressed
        /// Named deltas exceed the day total — the baseline is untrustworthy.
        /// Unlike monthRegressed there is NO tolerance slack here: too much
        /// explained is always wrong.
        case overAttributed
        /// Nothing spent today yet — not an error, just nothing to split.
        case noSpendYet

        /// The sentence the Today section shows in place of the rows.
        public var note: String? {
            switch self {
            case .noBaseline, .baselineNotAdjacent:
                // Not "midnight UTC": the gateway's day rolls at ITS midnight,
                // which for an offset label ("+03:00") can be 21:00 UTC. Claim
                // the gateway day, never a UTC clock time.
                return "Per-model split starts after the next gateway day"
            case .monthChanged, .monthRegressed:
                return "Per-model split resumes tomorrow (new month)"
            case .overAttributed:
                // The baseline was untrustworthy — almost always because the
                // app wasn't running at yesterday's close, so yesterday's
                // stored snapshot is stale and folds yesterday-afternoon
                // spend into "today". Say THAT, not a permanent-sounding
                // error: the split self-heals from tomorrow's baseline.
                return "Per-model split needs one full day of the app running"
            case .noSpendYet:
                return nil
            }
        }
    }
}

/// Pure differencing engine — no clock, no I/O. Callers parse spend_date and
/// resolve the baseline; this type only sees the two payloads.
public enum TodayModelSplitEngine {
    /// Sub-cent amounts round-trip the display as $0.00, so they're noise.
    static let displayEpsilon = 0.005

    /// Downward month restatement is tolerated up to 1% of the baseline month
    /// total (floor $0.50) — the gateway re-slices recent rows by cents.
    static func monthTolerance(base: Double) -> Double {
        max(base * 0.01, 0.50)
    }

    /// The month key ("yyyy-MM") a spend_date CARRIES, read from its calendar
    /// label via GatewayDay — never from parsing it as an instant. A
    /// non-UTC-midnight label ("2026-08-01T00:00:00+03:00") is the gateway's
    /// Aug 1, so its month is "2026-08"; reading the UTC instant would say
    /// "2026-07" and keep the split unavailable an extra day across the seam.
    /// Both "2026-08-10" and "2026-08-10T00:00:00Z" resolve identically.
    public static func monthKey(of spendDate: String) -> String? {
        GatewayDay(spendDate: spendDate)?.monthKey()
    }

    public static func split(current: UsageResponse, baseline: ModelSnapshot?) -> TodayModelSplitResult {
        let spentUSD = current.dailyBudget.spentUSD

        // 0. Nothing spent today — the honest answer is "no rows", not a
        // split of zeros.
        guard spentUSD > displayEpsilon else { return .unavailable(.noSpendYet) }

        // 1. No baseline to difference against.
        guard let baseline else { return .unavailable(.noBaseline) }

        // 2. Month seam: baseline belongs to a different UTC month, so its
        // cumulative figures aren't on the same series as current's.
        guard let currentMonthKey = monthKey(of: current.dailyBudget.spendDate),
              currentMonthKey == baseline.monthKey else {
            return .unavailable(.monthChanged)
        }

        // 3. Month regression: current_month.total_cost_usd should be
        // monotonic within a month. A drop beyond tolerance means the series
        // reset under us — the deltas would be garbage.
        let monthTotal = current.currentMonth.totalCostUSD
        if monthTotal < baseline.monthTotalUSD - monthTolerance(base: baseline.monthTotalUSD) {
            return .unavailable(.monthRegressed)
        }

        // 4. Named rows: only models present in BOTH snapshots with a
        // strictly-positive cost delta above the display epsilon. Everything
        // else (new-in-current, dropped, restated-down, flat, dust) falls
        // into Other so the rows still tie.
        var named: [TodayModelRow] = []
        for model in current.topModels {
            guard let base = baseline.models[model.model] else { continue }
            let deltaCost = model.totalCostUSD - base.costUSD
            guard deltaCost > displayEpsilon else { continue }
            let deltaTokens = max(model.totalTokens - base.tokens, 0)
            named.append(TodayModelRow(name: model.model, costUSD: deltaCost, tokens: deltaTokens, isOther: false))
        }
        named.sort { $0.costUSD > $1.costUSD }

        // 5. Reconcile against the authoritative day total. Over-attribution
        // bails with NO tolerance: named rows claiming more than the day
        // means the baseline is wrong, and a wrong split is worse than none.
        let namedSum = named.reduce(0) { $0 + $1.costUSD }
        let other = spentUSD - namedSum
        guard other >= -displayEpsilon else { return .unavailable(.overAttributed) }

        var rows = named
        if other > displayEpsilon {
            rows.append(TodayModelRow(name: "Other", costUSD: other, tokens: 0, isOther: true))
        }
        return .split(TodayModelSplit(rows: rows, totalUSD: spentUSD))
    }
}
