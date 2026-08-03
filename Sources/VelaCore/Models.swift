// Sources/VelaCore/Models.swift
// Codable DTOs for the AI Hub `GET /v1/me/usage` response, plus a tolerant
// ISO8601 date parser (the API mixes "Z" and numeric-offset timestamps, with
// and without fractional seconds).
// Why: this is the single source of truth for the wire shape everything else
// (BurnBuffer, PaceEngine, HistoryStore, the App poller) builds on.
// Note: MonthStats intentionally keeps period_start/period_end as optional
// Strings — the app derives "today" from spend_date, not from these.
// RELEVANT FILES: Tests/VelaCoreTests/ModelsTests.swift, BurnBuffer.swift, PaceEngine.swift

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

    private enum CodingKeys: String, CodingKey {
        case limitUSD = "limit_usd"
        case spentUSD = "spent_usd"
        case remainingUSD = "remaining_usd"
        case usedPercent = "used_percent"
        case limitEnabled = "limit_enabled"
        case spendDate = "spend_date"
    }

    public init(limitUSD: Double, spentUSD: Double, remainingUSD: Double, usedPercent: Double, limitEnabled: Bool, spendDate: String) {
        self.limitUSD = limitUSD
        self.spentUSD = spentUSD
        self.remainingUSD = remainingUSD
        self.usedPercent = usedPercent
        self.limitEnabled = limitEnabled
        self.spendDate = spendDate
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
        return plain.date(from: s)
    }
}
