// Sources/VelaCore/TodayModelSplit.swift
// Today's per-model breakdown, straight from the gateway: `/v1/me/usage`
// carries `today_models` (cost/tokens/requests per model over the enforced
// spend day, ranked by cost, capped at 5 rows) alongside
// `daily_budget.spent_usd`. The rows are reconciled against that
// authoritative day total so the block always ties to the hero figure.
// Why: the gateway used to expose only month-cumulative per-model figures,
// which forced a snapshot-differencing derivation; `today_models` made the
// derivation (and its baseline store) dead weight.
// RELEVANT FILES: Tests/VelaCoreTests/TodayModelSplitTests.swift, Sources/VelaCore/Models.swift

import Foundation

/// One row of the Today-by-model breakdown.
public struct TodayModelRow: Equatable, Sendable {
    public let name: String
    public let costUSD: Double
    public let tokens: Int
    public let requests: Int
    /// The residual bucket that absorbs multi-token share, beyond-cap rows
    /// and dust so the rows still tie to the day total. Renders without a
    /// bar; requests and tokens as "—".
    public let isOther: Bool

    public init(name: String, costUSD: Double, tokens: Int, requests: Int = 0, isOther: Bool) {
        self.name = name
        self.costUSD = costUSD
        self.tokens = tokens
        self.requests = requests
        self.isOther = isOther
    }
}

/// The split: named rows (cost desc) + an optional pinned-last Other row.
/// `totalUSD` is the authoritative daily_budget.spent_usd.
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
        /// Nothing spent today yet — not an error, just nothing to split.
        case noSpendYet
        /// The response carries no `today_models` (an older gateway build).
        case gatewayLacksSplit
        /// Named rows exceed the day total — the two figures don't tie, so
        /// any split would be a confident wrong one.
        case doesNotTie

        /// The sentence the Today section shows in place of the rows.
        public var note: String? {
            switch self {
            case .noSpendYet:
                return nil
            case .gatewayLacksSplit:
                return "This AI Hub gateway build doesn't expose today's split yet"
            case .doesNotTie:
                return "Per-model split doesn't tie to today's total"
            }
        }
    }
}

/// Compact count formatting for the model rows' subtitle ("50", "2.0K",
/// "379.13M"). Zero renders as an em-dash, never "0": the Other row's counts
/// aren't derivable, and silence beats a claim.
public enum UsageCounts {
    public static func compact(_ n: Int) -> String {
        let v = Double(n)
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return String(n)
    }

    public static func requestsLabel(_ n: Int) -> String {
        n > 0 ? "\(compact(n)) requests" : "—"
    }

    public static func tokensLabel(_ n: Int) -> String {
        n > 0 ? "\(compact(n)) tokens" : "—"
    }
}

/// Pure reconciliation — no clock, no I/O, no stored state. Sees one payload.
public enum TodayModelSplitEngine {
    /// Sub-cent amounts round-trip the display as $0.00, so they're noise.
    static let displayEpsilon = 0.005

    /// The month key ("yyyy-MM") a spend_date CARRIES, read from its calendar
    /// label via GatewayDay — never from parsing it as an instant. Used by
    /// ModelSnapshots to tag recorded snapshots.
    public static func monthKey(of spendDate: String) -> String? {
        GatewayDay(spendDate: spendDate)?.monthKey()
    }

    /// `baseline` is IGNORED since v1.1.0: the gateway's today_models replaced
    /// the old snapshot-differencing derivation. The parameter survives so
    /// PollStateMachine's call site (and its snapshot recording) stays
    /// untouched; it is dead weight and a candidate for removal once callers
    /// stop passing it.
    public static func split(current: UsageResponse, baseline: ModelSnapshot? = nil) -> TodayModelSplitResult {
        let spentUSD = current.dailyBudget.spentUSD

        // 0. Nothing spent today — the honest answer is "no rows", not a
        // split of zeros.
        guard spentUSD > displayEpsilon else { return .unavailable(.noSpendYet) }

        // 1. The gateway build must carry today's breakdown.
        guard let models = current.todayModels else { return .unavailable(.gatewayLacksSplit) }

        // 2. Named rows: the server's today rows above display noise, cost desc.
        let named = models
            .filter { $0.totalCostUSD > displayEpsilon }
            .map { TodayModelRow(name: $0.model, costUSD: $0.totalCostUSD, tokens: $0.totalTokens, requests: $0.requests, isOther: false) }
            .sorted { $0.costUSD > $1.costUSD }

        // 3. Reconcile against the authoritative day total. today_models is
        // scoped to this token; spent_usd spans the whole user, so the delta
        // (other tokens' share, beyond-cap rows, dust) lands in Other and the
        // rows always sum to the day total.
        //
        // Gateway cache lag (v1.1.0, observed in production): spent_usd and
        // today.total_cost_usd are two aggregates with independent 1-minute
        // caches, and spent_usd can trail by cents — the docs' "today_models
        // ≤ spent_usd" is the steady state, not a guarantee mid-minute. A
        // small NEGATIVE residue is therefore restatement noise, not a lie:
        // show the rows as-is (they tie to today.total_cost_usd, the figure
        // they actually sum to) rather than bailing or showing a negative
        // Other. Beyond that tolerance the two figures genuinely disagree,
        // and a split that doesn't tie is worse than none.
        let namedSum = named.reduce(0) { $0 + $1.costUSD }
        let other = spentUSD - namedSum
        let restatementTolerance = max(spentUSD * 0.01, 0.50)
        guard other >= -restatementTolerance else { return .unavailable(.doesNotTie) }

        var rows = named
        if other > displayEpsilon {
            rows.append(TodayModelRow(name: "Other", costUSD: other, tokens: 0, isOther: true))
        }
        return .split(TodayModelSplit(rows: rows, totalUSD: spentUSD))
    }
}
