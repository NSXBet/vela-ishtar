// Sources/VelaCore/Models.swift
// Codable DTOs for the AI Hub `GET /v1/me/usage` response, plus a tolerant
// ISO8601 date parser (the API mixes "Z" and numeric-offset timestamps, with
// and without fractional seconds).
// Why: this is the single source of truth for the wire shape everything else
// (BurnBuffer, PaceEngine, HistoryStore, the App poller) builds on.
// Note: MonthStats intentionally keeps period_start/period_end as optional
// Strings — the app derives "today" from spend_date, not from these.
// Note: DailyBudget.modelBudgets carries the gateway's NESTED per-model daily
// caps (currently "aihub/claude-opus-5" at $20/day). Nested, not separate: a
// capped model's dollars count toward BOTH that cap and the global limit, so
// the cap is usually the binding one ($20 is 5% of $400). The field is decoded
// with decodeIfPresent → [] because older servers (and the checked-in OpenAPI
// spec) omit it entirely; absent and null must both mean "no caps", never a
// decode failure. A cap's limit_usd is authoritative per poll and must never be
// hardcoded — the effective value is route limit + per-user admin override.
// limit_usd == 0 means the model is BLOCKED, not unlimited.
// Note: ModelCooldown is a self-service bypass of the MODEL cap only (never the
// global one). The gateway computes spent/limit/remaining/percent_used WITHOUT
// regard to it, so an active cooldown does not soften those numbers — callers
// must consult relaxedUntil themselves before treating a cap as binding.
// RELEVANT FILES: Tests/VelaCoreTests/ModelsTests.swift, ModelBudgetSignal.swift, PaceEngine.swift

import Foundation

public struct UsageResponse: Codable, Equatable, Sendable {
    public let tokenId: String
    public let dailyBudget: DailyBudget
    public let currentMonth: MonthStats
    public let topModels: [ModelUsage]

    private enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case dailyBudget = "daily_budget"
        case currentMonth = "current_month"
        case topModels = "top_models"
    }

    public init(tokenId: String, dailyBudget: DailyBudget, currentMonth: MonthStats, topModels: [ModelUsage]) {
        self.tokenId = tokenId
        self.dailyBudget = dailyBudget
        self.currentMonth = currentMonth
        self.topModels = topModels
    }
}

public struct DailyBudget: Codable, Equatable, Sendable {
    public let limitUSD: Double
    public let spentUSD: Double
    public let remainingUSD: Double
    public let usedPercent: Double
    public let limitEnabled: Bool
    public let spendDate: String
    public let modelBudgets: [ModelBudget]

    private enum CodingKeys: String, CodingKey {
        case limitUSD = "limit_usd"
        case spentUSD = "spent_usd"
        case remainingUSD = "remaining_usd"
        case usedPercent = "used_percent"
        case limitEnabled = "limit_enabled"
        case spendDate = "spend_date"
        case modelBudgets = "model_budgets"
    }

    public init(limitUSD: Double, spentUSD: Double, remainingUSD: Double, usedPercent: Double, limitEnabled: Bool, spendDate: String, modelBudgets: [ModelBudget] = []) {
        self.limitUSD = limitUSD
        self.spentUSD = spentUSD
        self.remainingUSD = remainingUSD
        self.usedPercent = usedPercent
        self.limitEnabled = limitEnabled
        self.spendDate = spendDate
        self.modelBudgets = modelBudgets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitUSD = try container.decode(Double.self, forKey: .limitUSD)
        spentUSD = try container.decode(Double.self, forKey: .spentUSD)
        remainingUSD = try container.decode(Double.self, forKey: .remainingUSD)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        limitEnabled = try container.decode(Bool.self, forKey: .limitEnabled)
        spendDate = try container.decode(String.self, forKey: .spendDate)
        modelBudgets = try container.decodeIfPresent([ModelBudget].self, forKey: .modelBudgets) ?? []
    }
}

public struct ModelBudget: Codable, Equatable, Sendable {
    public let model: String
    public let spentUSD: Double
    public let limitUSD: Double
    public let remainingUSD: Double
    public let percentUsed: Double
    public let cooldownEligible: Bool
    public let cooldown: ModelCooldown?

    private enum CodingKeys: String, CodingKey {
        case model
        case spentUSD = "spent_usd"
        case limitUSD = "limit_usd"
        case remainingUSD = "remaining_usd"
        case percentUsed = "percent_used"
        case cooldownEligible = "cooldown_eligible"
        case cooldown
    }

    public init(model: String, spentUSD: Double, limitUSD: Double, remainingUSD: Double, percentUsed: Double, cooldownEligible: Bool, cooldown: ModelCooldown? = nil) {
        self.model = model
        self.spentUSD = spentUSD
        self.limitUSD = limitUSD
        self.remainingUSD = remainingUSD
        self.percentUsed = percentUsed
        self.cooldownEligible = cooldownEligible
        self.cooldown = cooldown
    }
}

public struct ModelCooldown: Codable, Equatable, Sendable {
    public let createdAt: String?
    public let relaxedUntil: String?

    private enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case relaxedUntil = "relaxed_until"
    }

    public init(createdAt: String? = nil, relaxedUntil: String? = nil) {
        self.createdAt = createdAt
        self.relaxedUntil = relaxedUntil
    }
}

public struct MonthStats: Codable, Equatable, Sendable {
    public let totalCostUSD: Double
    public let totalTokens: Int
    public let requests: Int
    public let periodStart: String?
    public let periodEnd: String?

    private enum CodingKeys: String, CodingKey {
        case totalCostUSD = "total_cost_usd"
        case totalTokens = "total_tokens"
        case requests
        case periodStart = "period_start"
        case periodEnd = "period_end"
    }

    public init(totalCostUSD: Double, totalTokens: Int, requests: Int, periodStart: String? = nil, periodEnd: String? = nil) {
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.requests = requests
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }
}

public struct ModelUsage: Codable, Equatable, Sendable {
    public let model: String
    public let totalCostUSD: Double
    public let totalTokens: Int
    public let requests: Int

    private enum CodingKeys: String, CodingKey {
        case model
        case totalCostUSD = "total_cost_usd"
        case totalTokens = "total_tokens"
        case requests
    }

    public init(model: String, totalCostUSD: Double, totalTokens: Int, requests: Int) {
        self.model = model
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.requests = requests
    }
}

// Best-effort ISO8601 parsing. The API emits both "...Z" and "...-03:00",
// and both with and without fractional seconds. ISO8601DateFormatter needs
// the fractional-seconds option flipped on/off per-string, so we try both.
public enum ISODate {
    public static func parse(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }

        // Date-only strings ("2026-08-01") have no time component at all,
        // so neither formatter above matches -- try that shape last.
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: s)
    }

    /// The calendar-day label ("yyyy-MM-dd") a spend_date CARRIES, in any
    /// shape the API emits: bare dates return verbatim, timestamps return
    /// their first 10 characters. Why the prefix and not parse→reformat:
    /// spend_date is the gateway's billing-day LABEL, not an instant — the
    /// API has emitted both "2026-08-06" and "2026-08-07T00:00:00Z" for the
    /// same logical day, and Models.swift's parse() handles numeric offsets
    /// ("...+03:00") too. Parsing a timestamp as an instant and reformatting
    /// in UTC would shift a non-UTC-midnight label onto the wrong day
    /// ("2026-08-07T00:00:00+03:00" is the gateway's Aug 7, not UTC's Aug 6),
    /// re-splitting one day across two history keys — the exact bug this
    /// normalization exists to fix. Anything not matching the expected
    /// shapes falls back to parse→UTC-format, then to the raw string.
    public static func dayKey(_ s: String) -> String {
        // yyyy-MM-dd (bare date or the date portion of a timestamp).
        if s.count >= 10 {
            let prefix = s.prefix(10)
            let digits = prefix.filter(\.isNumber)
            if digits.count == 8, prefix.dropFirst(4).first == "-", prefix.dropFirst(7).first == "-" {
                return String(prefix)
            }
        }
        // Fallback for anything unexpected: parse as an instant, format UTC.
        guard let date = parse(s) else { return s }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return s }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
