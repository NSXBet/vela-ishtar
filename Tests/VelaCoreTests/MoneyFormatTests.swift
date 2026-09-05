// Tests/VelaCoreTests/MoneyFormatTests.swift
// Pins the shared money/percent/rate formatting rules: safe-before-Int-cast
// percentages (B03), the truthful unlimited hero suffix (B11), and the
// observed blended $/M rate with its compact form and em-dash fallbacks.
// RELEVANT FILES: Sources/VelaCore/MoneyFormat.swift, Tests/VelaCoreTests/UsageValidationTests.swift

import Testing
import Foundation
@testable import VelaCore

struct MoneyFormatTests {
    // MARK: - Dollars

    @Test("dollars formats cents truthfully")
    func dollarsBasic() {
        #expect(MoneyFormat.dollars(109.42) == "$109.42")
        #expect(MoneyFormat.dollars(0) == "$0.00")
    }

    @Test("dollars renders unsafe values as an em-dash, never a lie or a trap")
    func dollarsUnsafeValues() {
        #expect(MoneyFormat.dollars(-1) == "—")
        #expect(MoneyFormat.dollars(.nan) == "—")
        #expect(MoneyFormat.dollars(.infinity) == "—")
    }

    @Test("dollarsRounded formats huge finite values without loss of truth")
    func dollarsRoundedHuge() {
        #expect(MoneyFormat.dollarsRounded(1e9) == "$1000000000")
        #expect(MoneyFormat.dollarsRounded(400.4) == "$400")
    }

    // MARK: - Hero suffix (B11)

    @Test("no-limit hero never renders a limit suffix")
    func noLimitNoSuffix() {
        #expect(MoneyFormat.heroSuffix(limit: 400, limitEnabled: false) == nil)
        #expect(MoneyFormat.heroSuffix(limit: 0, limitEnabled: false) == nil)
    }

    @Test("enabled limit renders the suffix, including a real $0 limit")
    func enabledLimitRendersSuffix() {
        #expect(MoneyFormat.heroSuffix(limit: 400, limitEnabled: true) == " of $400 today")
        #expect(MoneyFormat.heroSuffix(limit: 0, limitEnabled: true) == " of $0 today")
    }

    // MARK: - Percent (B03)

    @Test("percent clamps huge finite cost safely before the Int conversion")
    func percentHugeCostSafe() {
        #expect(MoneyFormat.percent(cost: 1e100, total: 100) == 100)
        #expect(MoneyFormat.percent(cost: .infinity, total: 100) == 0)
        #expect(MoneyFormat.percent(cost: .nan, total: 100) == 0)
        #expect(MoneyFormat.percent(cost: 50, total: 0) == 0)
        #expect(MoneyFormat.percent(cost: 50, total: .nan) == 0)
    }

    @Test("percent rounds to nearest and floors at zero")
    func percentRounding() {
        #expect(MoneyFormat.percent(cost: 0.5, total: 100) == 1)   // 0.5% → 1
        #expect(MoneyFormat.percent(cost: 0.001, total: 100) == 0) // rounds to 0
        #expect(MoneyFormat.percent(cost: -1, total: 100) == 0)
    }

    // MARK: - Blended $/M rate

    @Test("blended rate formats under and over the compact threshold")
    func blendedRateThresholds() {
        #expect(MoneyFormat.blendedRate(cost: 5, tokens: 1_000_000) == "$5.00/M")
        #expect(MoneyFormat.blendedRate(cost: 1_500, tokens: 1_000_000) == "$1.5k/M")
    }

    @Test("blended rate falls back to em-dash for no-usage and unsafe inputs")
    func blendedRateFallbacks() {
        #expect(MoneyFormat.blendedRate(cost: 5, tokens: 0) == "—")
        #expect(MoneyFormat.blendedRate(cost: .nan, tokens: 1_000_000) == "—")
        #expect(MoneyFormat.blendedRate(cost: -1, tokens: 1_000_000) == "—")
        #expect(MoneyFormat.blendedRate(cost: 1e300, tokens: 1) == "—")  // overflows to inf
    }
}
