// Tests/VelaCoreTests/ModelsTests.swift
// Verifies UsageResponse decodes the real GET /v1/me/usage payload exactly,
// and that ISODate.parse handles both "Z" and fractional-offset timestamps.
// Why: this fixture was captured from a live response; if the DTOs drift
// from the wire shape, this test is the first thing that breaks.
// RELEVANT FILES: Sources/VelaCore/Models.swift

import Testing
import Foundation
@testable import VelaCore

struct ModelsTests {
    static let fixture = """
    {"token_id":"00000000-0000-4000-8000-000000000000","daily_budget":{"user_id":"00u000000000000000000","spend_date":"2026-08-01T00:00:00Z","limit_usd":400,"spent_usd":54.51088648,"remaining_usd":345.48911352,"used_percent":13.627721619999999,"limit_enabled":true},"current_month":{"period_start":"2026-08-01T00:00:00-03:00","period_end":"2026-08-01T07:34:44.608728233-03:00","total_cost_usd":54.51088648,"total_tokens":72972818,"requests":525},"top_models":[{"model":"moonshotai/kimi-k3","total_cost_usd":52.30068038,"total_tokens":68013553,"requests":426},{"model":"anthropic/claude-haiku-4.5","total_cost_usd":2.2102061,"total_tokens":4959265,"requests":99}]}
    """

    @Test("decodes real usage payload")
    func decodesRealPayload() throws {
        let data = Self.fixture.data(using: .utf8)!
        let usage = try JSONDecoder().decode(UsageResponse.self, from: data)

        #expect(usage.tokenId == "00000000-0000-4000-8000-000000000000")
        #expect(usage.dailyBudget.spentUSD == 54.51088648)
        #expect(abs(usage.dailyBudget.usedPercent - 13.6277) < 0.0001)
        #expect(usage.dailyBudget.limitEnabled == true)
        #expect(usage.dailyBudget.spendDate == "2026-08-01T00:00:00Z")
        #expect(usage.currentMonth.totalTokens == 72972818)
        #expect(usage.currentMonth.requests == 525)
        #expect(usage.topModels.count == 2)
        #expect(usage.topModels[0].model == "moonshotai/kimi-k3")
        #expect(usage.topModels[1].model == "anthropic/claude-haiku-4.5")
    }

    @Test("ISODate parses Z-suffixed timestamp")
    func parsesZSuffix() {
        #expect(ISODate.parse("2026-08-01T00:00:00Z") != nil)
    }

    @Test("ISODate parses fractional numeric-offset timestamp")
    func parsesFractionalOffset() {
        #expect(ISODate.parse("2026-08-01T07:34:44.608728233-03:00") != nil)
    }

    @Test("ISODate returns nil on garbage input")
    func parsesGarbage() {
        #expect(ISODate.parse("not-a-date") == nil)
    }

    @Test("ISODate parses a date-only string")
    func parsesDateOnly() {
        #expect(ISODate.parse("2026-08-01") != nil)
    }

    @Test("dayKey keeps the gateway's calendar label, never the UTC instant's date")
    func dayKeyTreatsSpendDateAsCalendarLabel() {
        // Bare dates pass through verbatim.
        #expect(ISODate.dayKey("2026-08-07") == "2026-08-07")
        // Z-suffixed timestamps keep their date portion.
        #expect(ISODate.dayKey("2026-08-07T00:00:00Z") == "2026-08-07")
        // The regression this guards: a numeric-offset timestamp whose LOCAL
        // date is the gateway's billing day must not be shifted onto the UTC
        // instant's date — "the gateway's Aug 7" stays Aug 7 even though the
        // instant is Aug 6 21:00 UTC. Parse→reformat-in-UTC returned
        // "2026-08-06" here, splitting one gateway day across two keys.
        #expect(ISODate.dayKey("2026-08-07T00:00:00+03:00") == "2026-08-07")
        #expect(ISODate.dayKey("2026-08-06T23:00:00-03:00") == "2026-08-06")
        // Fractional seconds + offset, the other observed wire shape.
        #expect(ISODate.dayKey("2026-08-07T00:00:00.608728233Z") == "2026-08-07")
        // Garbage falls back to the raw string (never crashes, never invents).
        #expect(ISODate.dayKey("not-a-date") == "not-a-date")
    }

    static let modelBudgetUsageFixture = """
    {"token_id":"00000000-0000-4000-8000-000000000000","daily_budget":{"user_id":"00u000000000000000000","spend_date":"2026-08-28T00:00:00Z","limit_usd":400,"spent_usd":54.51088648,"remaining_usd":345.48911352,"used_percent":13.627721619999999,"limit_enabled":true,"model_budgets":[{"model":"aihub/claude-opus-5","spent_usd":14.7532,"limit_usd":20,"remaining_usd":5.2468,"percent_used":73.766,"cooldown_eligible":false,"cooldown":null}]},"current_month":{"period_start":"2026-08-01T00:00:00-03:00","period_end":"2026-08-28T07:34:44.608728233-03:00","total_cost_usd":54.51088648,"total_tokens":72972818,"requests":525},"top_models":[]}
    """

    static func dailyBudgetFixture(modelBudgets: String) -> String {
        """
        {"spend_date":"2026-08-28T00:00:00Z","limit_usd":400,"spent_usd":54.51088648,"remaining_usd":345.48911352,"used_percent":13.627721619999999,"limit_enabled":true,"model_budgets":\(modelBudgets)}
        """
    }

    static func decodeModelBudget(_ fixture: String) throws -> ModelBudget {
        try JSONDecoder().decode(ModelBudget.self, from: Data(fixture.utf8))
    }

    @Test("decodes captured model budget payload")
    func decodesCapturedModelBudgetPayload() throws {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(Self.modelBudgetUsageFixture.utf8))
        let modelBudget = usage.dailyBudget.modelBudgets[0]

        #expect(usage.dailyBudget.modelBudgets.count == 1)
        #expect(modelBudget.model == "aihub/claude-opus-5")
        #expect(modelBudget.spentUSD == 14.7532)
        #expect(modelBudget.limitUSD == 20)
        #expect(modelBudget.remainingUSD == 5.2468)
        #expect(modelBudget.percentUsed == 73.766)
        #expect(modelBudget.cooldownEligible == false)
        #expect(modelBudget.cooldown == nil)
    }

    @Test("missing model budgets decode as an empty array")
    func decodesMissingModelBudgetsAsEmptyArray() throws {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(Self.fixture.utf8))

        #expect(usage.dailyBudget.modelBudgets == [])
    }

    @Test("empty model budgets decode as an empty array")
    func decodesEmptyModelBudgetsAsEmptyArray() throws {
        let budget = try JSONDecoder().decode(
            DailyBudget.self,
            from: Data(Self.dailyBudgetFixture(modelBudgets: "[]").utf8)
        )

        #expect(budget.modelBudgets == [])
    }

    @Test("decodes active model cooldown")
    func decodesActiveModelCooldown() throws {
        let modelBudget = try Self.decodeModelBudget("""
        {"model":"aihub/claude-opus-5","spent_usd":20,"limit_usd":20,"remaining_usd":0,"percent_used":100,"cooldown_eligible":false,"cooldown":{"created_at":"2026-08-28T01:00:00Z","relaxed_until":"2026-08-28T03:00:00Z"}}
        """)

        #expect(modelBudget.cooldown?.createdAt == "2026-08-28T01:00:00Z")
        #expect(modelBudget.cooldown?.relaxedUntil == "2026-08-28T03:00:00Z")
        #expect(ISODate.parse(modelBudget.cooldown?.relaxedUntil ?? "") != nil)
    }

    @Test("decodes cooldown eligibility")
    func decodesCooldownEligibility() throws {
        let modelBudget = try Self.decodeModelBudget("""
        {"model":"aihub/claude-opus-5","spent_usd":20,"limit_usd":20,"remaining_usd":0,"percent_used":100,"cooldown_eligible":true,"cooldown":null}
        """)

        #expect(modelBudget.cooldownEligible == true)
    }

    @Test("decodes admin-overridden model limit")
    func decodesAdminOverriddenModelLimit() throws {
        let modelBudget = try Self.decodeModelBudget("""
        {"model":"aihub/claude-opus-5","spent_usd":14.7532,"limit_usd":30,"remaining_usd":15.2468,"percent_used":49.1773,"cooldown_eligible":false,"cooldown":null}
        """)

        #expect(modelBudget.limitUSD == 30)
    }

    @Test("preserves zero model limit")
    func preservesZeroModelLimit() throws {
        let modelBudget = try Self.decodeModelBudget("""
        {"model":"aihub/claude-opus-5","spent_usd":0,"limit_usd":0,"remaining_usd":0,"percent_used":0,"cooldown_eligible":false,"cooldown":null}
        """)

        #expect(modelBudget.limitUSD == 0)
    }

    @Test("decodes model budgets in API order")
    func decodesModelBudgetsInAPIOrder() throws {
        let budget = try JSONDecoder().decode(
            DailyBudget.self,
            from: Data(Self.dailyBudgetFixture(modelBudgets: """
            [{"model":"aihub/claude-opus-5","spent_usd":14.7532,"limit_usd":20,"remaining_usd":5.2468,"percent_used":73.766,"cooldown_eligible":false,"cooldown":null},{"model":"anthropic/claude-haiku-4.5","spent_usd":2,"limit_usd":10,"remaining_usd":8,"percent_used":20,"cooldown_eligible":true,"cooldown":null}]
            """).utf8)
        )

        #expect(budget.modelBudgets.count == 2)
        #expect(budget.modelBudgets[0].model == "aihub/claude-opus-5")
        #expect(budget.modelBudgets[1].model == "anthropic/claude-haiku-4.5")
    }

    @Test("model budget round-trips through Codable")
    func modelBudgetRoundTripsThroughCodable() throws {
        let original = try Self.decodeModelBudget("""
        {"model":"aihub/claude-opus-5","spent_usd":20,"limit_usd":20,"remaining_usd":0,"percent_used":100,"cooldown_eligible":true,"cooldown":{"created_at":"2026-08-28T01:00:00Z","relaxed_until":"2026-08-28T03:00:00Z"}}
        """)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelBudget.self, from: encoded)

        #expect(decoded == original)
    }

    static let todayModelsFixture = """
    {"token_id":"00000000-0000-4000-8000-000000000000","daily_budget":{"user_id":"00u000000000000000000","spend_date":"2026-08-28T00:00:00Z","limit_usd":400,"spent_usd":54.51088648,"remaining_usd":345.48911352,"used_percent":13.627721619999999,"limit_enabled":true},"current_month":{"period_start":"2026-08-01T00:00:00-03:00","period_end":"2026-08-28T07:34:44.608728233-03:00","total_cost_usd":3049.237736017,"total_tokens":4215745301,"requests":22634},"top_models":[{"model":"moonshotai/kimi-k3","total_cost_usd":1450.1,"total_tokens":1884123755,"requests":9652}],"today":{"period_start":"2026-08-28T00:00:00-03:00","period_end":"2026-08-28T18:38:31-03:00","total_cost_usd":22.47,"total_tokens":86480000,"requests":421},"today_models":[{"model":"anthropic/claude-sonnet-5","total_cost_usd":12.13,"total_tokens":40000000,"requests":180},{"model":"openai/gpt-5.6-luna-pro","total_cost_usd":5.81,"total_tokens":20000000,"requests":90}]}
    """

    @Test("decodes today and today_models distinct from current_month and top_models")
    func decodesTodayModelsPayload() throws {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(Self.todayModelsFixture.utf8))

        // today must not be confused with current_month — the two totals differ
        // by two orders of magnitude in this fixture, so a wrong key mapping
        // (e.g. decoding "today" into currentMonth) fails loudly.
        #expect(usage.today.totalCostUSD == 22.47)
        #expect(usage.today.totalTokens == 86480000)
        #expect(usage.today.requests == 421)
        #expect(usage.currentMonth.totalCostUSD == 3049.237736017)

        #expect(usage.todayModels.count == 2)
        #expect(usage.todayModels[0].model == "anthropic/claude-sonnet-5")
        #expect(usage.todayModels[0].totalCostUSD == 12.13)
        #expect(usage.todayModels[1].model == "openai/gpt-5.6-luna-pro")
        #expect(usage.todayModels[1].totalCostUSD == 5.81)
        #expect(usage.topModels.count == 1)
        #expect(usage.topModels[0].model == "moonshotai/kimi-k3")
    }

    @Test("missing today and today_models decode as zeroed/empty (backward compat)")
    func decodesMissingTodayModelsAsZeroedAndEmpty() throws {
        // Self.fixture predates the gateway's today/today_models fields entirely.
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(Self.fixture.utf8))

        #expect(usage.today == MonthStats(totalCostUSD: 0, totalTokens: 0, requests: 0))
        #expect(usage.todayModels == [])
    }

}

// A VERBATIM capture of the live gateway response (ids redacted), taken while
// Opus stood at 92.1% of its $20 cap and the global budget at 35.1% of $400 —
// the exact divergence this feature exists to surface. Kept byte-for-byte so a
// wire-shape change (a renamed key, a field promoted out of daily_budget) fails
// here loudly instead of silently decoding to an empty model_budgets and
// quietly removing the row from the popover.
@Suite("Live payload regression")
struct LiveModelBudgetPayloadTests {
    static let liveFixture = """
    {
      "token_id": "REDACTED",
      "daily_budget": {
        "user_id": "REDACTED",
        "spend_date": "2026-08-27T00:00:00Z",
        "limit_usd": 400,
        "spent_usd": 140.56805112,
        "remaining_usd": 259.43194888,
        "used_percent": 35.14201278,
        "limit_enabled": true,
        "cooldown_eligible": false,
        "grace_amount_usd": 5,
        "maximum_daily_spend_usd": 405,
        "cooldown": null,
        "model_budgets": [
          {
            "model": "aihub/claude-opus-5",
            "spent_usd": 18.4227045,
            "limit_usd": 20,
            "remaining_usd": 1.5772955000000017,
            "percent_used": 92.11352249999999,
            "cooldown_eligible": false,
            "cooldown": null
          }
        ]
      },
      "current_month": {
        "period_start": "2026-08-01T00:00:00-03:00",
        "period_end": "2026-08-27T18:38:31.171114877-03:00",
        "total_cost_usd": 3049.237736017,
        "total_tokens": 4215745301,
        "requests": 22634
      },
      "top_models": [
        {"model": "moonshotai/kimi-k3", "total_cost_usd": 1450.1, "total_tokens": 1884123755, "requests": 9652}
      ],
      "today": {
        "period_start": "2026-08-27T00:00:00-03:00",
        "period_end": "2026-08-27T18:38:31.171114877-03:00",
        "total_cost_usd": 22.47,
        "total_tokens": 86480000,
        "requests": 421
      },
      "today_models": [
        {"model": "moonshotai/kimi-k3", "total_cost_usd": 12.13, "total_tokens": 30000000, "requests": 190},
        {"model": "openai/gpt-5.6-luna-pro", "total_cost_usd": 5.81, "total_tokens": 15000000, "requests": 88},
        {"model": "openai/gpt-5.6-terra-pro", "total_cost_usd": 1.78, "total_tokens": 4000000, "requests": 22}
      ]
    }
    """

    @Test("the live payload decodes, and the model cap reads as the binding constraint")
    func livePayloadDecodes() throws {
        let usage = try JSONDecoder().decode(
            UsageResponse.self,
            from: Data(Self.liveFixture.utf8)
        )

        // The global budget looks calm...
        #expect(usage.dailyBudget.usedPercent < 40)

        // ...while the nested cap is nearly gone. Both are true at once, which
        // is precisely why the global gauge alone cannot tell the whole story.
        let cap = try #require(usage.dailyBudget.modelBudgets.first)
        #expect(cap.model == "aihub/claude-opus-5")
        #expect(cap.limitUSD == 20)
        #expect(cap.percentUsed > 90)
        #expect(cap.cooldown == nil)

        // The gateway's own arithmetic, which our display must not re-derive
        // differently: remaining is exactly limit - spent.
        #expect(abs((cap.limitUSD - cap.spentUSD) - cap.remainingUSD) < 1e-9)

        // today / today_models are new fields on this same live fixture: this
        // test's whole purpose is to fail loudly on wire-shape drift, so it
        // must reflect the fields the gateway now actually returns.
        #expect(usage.today.totalCostUSD == 22.47)
        #expect(usage.today.totalTokens == 86480000)
        #expect(usage.today.requests == 421)
        #expect(usage.todayModels.count == 3)
        #expect(usage.todayModels[0].model == "moonshotai/kimi-k3")
        #expect(usage.todayModels[1].model == "openai/gpt-5.6-luna-pro")
        #expect(usage.todayModels[2].model == "openai/gpt-5.6-terra-pro")
    }

    @Test("grace applies to the global budget only, so a model cap is a hard ceiling")
    func graceIsGlobalOnly() throws {
        let usage = try JSONDecoder().decode(
            UsageResponse.self,
            from: Data(Self.liveFixture.utf8)
        )
        // maximum_daily_spend_usd (405) = limit (400) + grace (5) is a GLOBAL
        // concept; nothing analogous exists per model, so the cap's own
        // limit_usd is the wall and must be rendered as such.
        let cap = try #require(usage.dailyBudget.modelBudgets.first)
        #expect(cap.remainingUSD < 2)
    }
}

// MARK: - WP-01: wire-presence facts (raw absence survives decoding)

struct UsageResponsePresenceTests {
    private let budgetJSON = #"{"limit_usd":400,"spent_usd":10,"remaining_usd":390,"used_percent":2.5,"limit_enabled":true,"spend_date":"2026-09-05"}"#

    @Test("missing today/today_models record as absent, not as zeroed facts")
    func absenceRecordedNotZeroed() throws {
        let json = #"{"token_id":"t","daily_budget":\#(budgetJSON),"current_month":{"total_cost_usd":0,"total_tokens":0,"requests":0},"top_models":[]}"#
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(!response.todayPresent)
        #expect(!response.todayModelsPresent)
        #expect(response.today.totalCostUSD == 0)      // tolerant default still applies
        #expect(response.todayModels.isEmpty)
    }

    @Test("present today/today_models mark the flags true, even at zero totals")
    func presenceAtZero() throws {
        let json = #"{"token_id":"t","daily_budget":\#(budgetJSON),"current_month":{"total_cost_usd":0,"total_tokens":0,"requests":0},"top_models":[],"today":{"total_cost_usd":0,"total_tokens":0,"requests":0},"today_models":[]}"#
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.todayPresent)
        #expect(response.todayModelsPresent)
        #expect(response.todayModels.isEmpty)          // explicitly empty ≠ absent
    }

    @Test("memberwise init infers presence from provided values for convenience")
    func memberwiseInference() {
        let present = UsageResponse(
            tokenId: "t",
            dailyBudget: DailyBudget(limitUSD: 1, spentUSD: 0, remainingUSD: 1, usedPercent: 0, limitEnabled: true, spendDate: "2026-09-05"),
            currentMonth: MonthStats(totalCostUSD: 0, totalTokens: 0, requests: 0),
            topModels: [],
            today: MonthStats(totalCostUSD: 5, totalTokens: 0, requests: 0),
            todayModels: [ModelUsage(model: "m", totalCostUSD: 5, totalTokens: 0, requests: 0)]
        )
        #expect(present.todayPresent && present.todayModelsPresent)
    }
}
