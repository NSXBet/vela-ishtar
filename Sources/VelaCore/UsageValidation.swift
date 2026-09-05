// Sources/VelaCore/UsageValidation.swift
// The validated-domain layer: turns a raw, tolerant-decoded `UsageResponse`
// into a `UsageSnapshot` (§7.2) and a presentation-safe `ModelBreakdownState`,
// plus a per-model row reconciler that can never masquerade an inconsistent
// payload as a reconciled breakdown.
// Why: B03 (used_percent=1e100 reaches an Int() cast and traps), B07 (named
// rows $80+$70 render against a $100 day total as if $150 were reconciled),
// B08 (month shares divide by the named-rows sum, not the authoritative
// month total), and the general "raw DTO defaults masquerade as domain
// facts" hazard all live at this one boundary. Validation happens HERE,
// once; downstream display code only ever sees safe values.
// RELEVANT FILES: Sources/VelaCore/UsageContracts.swift, Sources/VelaCore/Models.swift,
// Sources/VelaCore/MoneyFormat.swift, Tests/VelaCoreTests/UsageValidationTests.swift

import Foundation

// MARK: - ValidatedBudget

/// A `DailyBudget` whose numbers have passed the safe-numeric boundary.
/// Every monetary value is finite and non-negative; every percentage is
/// finite and already clamped-safe for integer conversion; the limit is
/// finite. Where the wire value was invalid, the snapshot records a
/// `SchemaWarning` and the derived value falls back to a safe neutral.
public struct ValidatedBudget: Equatable, Sendable {
    /// Always finite and >= 0. 0 means unlimited when `limitEnabled` is false.
    public let limitUSD: Double
    public let spentUSD: Double
    /// Always finite and >= 0; negative wire values clamp to 0.
    public let remainingUSD: Double
    /// Finite, in 0...10_000 (percentages far above 100 are legal in the
    /// domain — overspend — but 1e100 never reaches an Int() cast: anything
    /// past this cap is display-clamped to the cap; drawing clamps again).
    public let usedPercent: Double
    /// The wire's limit_enabled, unmodified — the B11 policy bit.
    public let limitEnabled: Bool
    /// Safe for any integer consumer: `Int(usedPercent.rounded())` cannot
    /// trap because `usedPercent` is bounded.
    public var usedPercentInt: Int { Int(usedPercent.rounded()) }

    public init(limitUSD: Double, spentUSD: Double, remainingUSD: Double, usedPercent: Double, limitEnabled: Bool) {
        self.limitUSD = limitUSD
        self.spentUSD = spentUSD
        self.remainingUSD = remainingUSD
        self.usedPercent = usedPercent
        self.limitEnabled = limitEnabled
    }
}

/// Safe money constants shared by validation and formatting.
public enum UsageValidation {
    /// Upper bound on any displayed percentage. Overspend far past 100% is
    /// real in the domain (gateway can report 400%), but no Int conversion
    /// may ever see a value past this bound. Generous, not arbitrary-low.
    public static let maxDisplayPercent: Double = 10_000
    /// Tolerance for "named rows vs comparable total" reconciliation: sums
    /// within one cent of the total count as reconciled (rounding), sums
    /// beyond it are inconsistent.
    public static let reconciliationTolerance = 0.01

    // MARK: - Money safety (01.2)

    /// Rejects negative and non-finite monetary values. Returns nil instead
    /// of a "safe" guess — the caller records unavailability, never 0-as-fact.
    public static func money(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// Validates a token/request count: finite and non-negative.
    public static func count(_ value: Int) -> Int? {
        guard value >= 0 else { return nil }
        return value
    }

    /// Validates a spend_date through GatewayDay (label, not instant).
    public static func gatewayDay(_ spendDate: String) -> GatewayDay? {
        GatewayDay(spendDate: spendDate)
    }

    // MARK: - Snapshot assembly (01.1)

    /// Builds a snapshot from a raw response. Absence of `today` /
    /// `today_models` survives as availability facts; invalid numerics
    /// produce schema warnings and safe fallbacks; a malformed spend_date
    /// falls back to the received-at UTC day and warns.
    public static func snapshot(
        from response: UsageResponse,
        scope: UsageScope,
        receivedAt: Date
    ) -> UsageSnapshot {
        var warnings: [UsageSnapshot.SchemaWarning] = []

        if !response.todayPresent {
            warnings.append(.init(field: "today", detail: "absent in payload; not a zero total"))
        }
        // An explicit JSON null decodes as "present" (container.contains is
        // key-based) but with tolerant-decoded zero/empty defaults — record
        // that ambiguity so null never masquerades as a real zero.
        if response.todayPresent && response.today.totalCostUSD == 0
            && response.today.totalTokens == 0 && response.today.requests == 0 {
            warnings.append(.init(field: "today", detail: "null tolerated as zeroed default"))
        }
        if !response.todayModelsPresent {
            warnings.append(.init(field: "today_models", detail: "absent in payload; model rows unavailable"))
        }

        // Malformed spend_date: fall back to the received-at UTC calendar
        // day so the snapshot still has a well-formed billing-day label.
        let gatewayDay: GatewayDay
        if let parsed = GatewayDay(spendDate: response.dailyBudget.spendDate) {
            gatewayDay = parsed
        } else {
            let fallback = ISODate.dayKey(receivedAt.description)
            gatewayDay = GatewayDay(spendDate: fallback)
                ?? GatewayDay(spendDate: "1970-01-01")!
            warnings.append(.init(field: "spend_date", detail: "unparseable; using received-at day"))
        }

        // Validate today numerics when the field was present: a negative or
        // non-finite total is malformed data, recorded as a warning with the
        // value replaced by a safe 0 — the UI shows total-only with the
        // warning, never a fabricated figure.
        if response.todayPresent {
            if money(response.today.totalCostUSD) == nil {
                warnings.append(.init(field: "today.total_cost_usd", detail: "negative or non-finite; treated as unusable"))
            }
        }

        return UsageSnapshot(
            response: response,
            scope: scope,
            receivedAt: receivedAt,
            gatewayDay: gatewayDay,
            modelData: modelAvailability(of: response, scope: scope),
            schemaWarnings: warnings
        )
    }

    /// Which parts of the model breakdown the payload really carried.
    public static func modelAvailability(of response: UsageResponse, scope: UsageScope? = nil) -> UsageSnapshot.ModelDataAvailability {
        switch (response.todayModelsPresent, response.todayPresent) {
        case (true, _):
            guard !response.todayModels.isEmpty else { return .empty }
            // Reconcile against the day total (B07): rows that sum past the
            // authoritative total are INCONSISTENT — the UI renders
            // total-only, never $150-of-$100. Requires a scope for the
            // available case; without one (legacy callers) rows still pass
            // through reconciliation with a placeholder-free day-total check.
            guard let scope else { return .available }
            switch breakdown(models: response.todayModels, dayTotal: response.dailyBudget.spentUSD, scope: scope) {
            case .available: return .available
            case .empty: return .empty
            case .inconsistent(let reason): return .inconsistent(reason: reason)
            case .unavailable(let reason): return .inconsistent(reason: reason)
            }
        case (false, _):
            return .unavailable
        }
    }

    // MARK: - Budget boundary (01.2, B03)

    /// Validates the global daily budget. Invalid numerics become the
    /// schema warnings driving the fallbacks; nothing unsafe survives.
    public static func budget(from raw: DailyBudget) -> (budget: ValidatedBudget, warnings: [UsageSnapshot.SchemaWarning]) {
        var warnings: [UsageSnapshot.SchemaWarning] = []

        let limit = money(raw.limitUSD) ?? 0
        if limit != raw.limitUSD {
            warnings.append(.init(field: "daily_budget.limit_usd", detail: "negative or non-finite; treated as 0"))
        }
        let spent = money(raw.spentUSD) ?? 0
        if spent != raw.spentUSD {
            warnings.append(.init(field: "daily_budget.spent_usd", detail: "negative or non-finite; treated as 0"))
        }
        let remaining = money(raw.remainingUSD) ?? 0
        if remaining != raw.remainingUSD {
            warnings.append(.init(field: "daily_budget.remaining_usd", detail: "negative or non-finite; treated as 0"))
        }

        // used_percent: the B03 path. Huge finite values are clamped to
        // maxDisplayPercent BEFORE any integer conversion; non-finite to 0.
        let percent: Double
        if raw.usedPercent.isFinite {
            percent = min(raw.usedPercent, maxDisplayPercent)
        } else {
            percent = 0
        }
        if percent != raw.usedPercent {
            warnings.append(.init(field: "daily_budget.used_percent", detail: "out of displayable range; clamped"))
        }

        return (ValidatedBudget(limitUSD: limit, spentUSD: spent, remainingUSD: remaining, usedPercent: percent, limitEnabled: raw.limitEnabled), warnings)
    }

    // MARK: - Model breakdown (01.3)

    /// Validates one day's model rows against the day total, producing the
    /// frozen `ModelBreakdownState`. Reconciliation rules:
    /// - duplicate model names → inconsistent (cost order is ambiguous);
    /// - negative or non-finite costs → inconsistent (malformed data);
    /// - named sum exceeding the comparable total by > $0.01 → inconsistent;
    /// - within tolerance → available with factual rows (no rescaling) and
    ///   the residual kept separate from the named rows.
    public static func breakdown(
        models: [ModelUsage],
        dayTotal: Double,
        scope: UsageScope
    ) -> ModelBreakdownState {
        // Comparable total must itself be safe.
        guard let total = money(dayTotal) else {
            return .inconsistent(reason: "day total is negative or non-finite")
        }

        // Explicitly empty is a fact, distinct from absence upstream.
        if models.isEmpty { return .empty }

        // Validate rows first: negative/non-finite costs and invalid counts
        // are malformed data, not displayable facts.
        var validated: [ModelUsage] = []
        for model in models {
            guard let cost = money(model.totalCostUSD),
                  count(model.totalTokens) != nil else {
                return .inconsistent(reason: "model '\(model.model)' has invalid cost or token count")
            }
            validated.append(model)
        }

        // Duplicates make the cost order and any fold ambiguous.
        let names = validated.map(\.model)
        if Set(names).count != names.count {
            return .inconsistent(reason: "duplicate model entries")
        }

        let namedSum = validated.reduce(0.0) { $0 + $1.totalCostUSD }
        if namedSum > total + reconciliationTolerance {
            return .inconsistent(
                reason: String(format: "named models sum to %@ but the day total is %@", MoneyFormat.dollars(namedSum), MoneyFormat.dollars(total))
            )
        }

        return .available(rows: validated, total: total, scope: scope)
    }

    // MARK: - Month reconciliation (01.4, B08)

    /// The authoritative denominator for month model shares: the month
    /// total from `current_month.totalCostUSD`, never the sum of listed
    /// top_models (which truncates). Returns nil when the total is invalid
    /// or no comparison is possible — callers then say "share of listed
    /// models" instead of inventing one.
    public static func monthShareDenominator(currentMonth: MonthStats, topModels: [ModelUsage]) -> Double? {
        guard let total = money(currentMonth.totalCostUSD), total > 0 else { return nil }
        // The denominator is comparable only if it can actually cover the
        // named rows (it includes all tokens' spend, month view included).
        return total
    }

    /// True when the named top-model rows understate the authoritative month
    /// total by more than a cent — i.e. there is a real omitted-model tail
    /// and shares must divide by the month total (B08), not the row sum.
    public static func hasOmittedTail(currentMonth: MonthStats, topModels: [ModelUsage]) -> Bool {
        guard let total = monthShareDenominator(currentMonth: currentMonth, topModels: topModels) else { return false }
        let namedSum = topModels.reduce(0.0) { $0 + $1.totalCostUSD }
        return namedSum < total - reconciliationTolerance
    }
}
