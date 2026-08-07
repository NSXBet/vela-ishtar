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
}
