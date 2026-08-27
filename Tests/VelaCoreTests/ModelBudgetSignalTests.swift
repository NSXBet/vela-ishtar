// Tests/VelaCoreTests/ModelBudgetSignalTests.swift
// Verifies model-budget classification, selection, display naming, and the
// narrative priority that combines an opaque global pace sentence with a
// model-specific cap signal.
// Why: model caps are nested constraints with distinct zero-limit and cooldown
// semantics; these tests keep those facts deterministic and out of AppKit.
// RELEVANT FILES: Sources/VelaCore/ModelBudgetSignal.swift, Sources/VelaCore/BorderDash.swift, Sources/VelaCore/PaceEngine.swift

import Foundation
import Testing
@testable import VelaCore

@Suite("ModelBudgetSignal")
struct ModelBudgetSignalTests {
    private static let now = Date(timeIntervalSince1970: 1_000_000)
    private static let utc = TimeZone(secondsFromGMT: 0)!

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    private static func input(
        model: String = "aihub/claude-opus-5",
        spentUSD: Double,
        limitUSD: Double,
        relaxedUntil: Date? = nil
    ) -> ModelBudgetInput {
        ModelBudgetInput(
            model: model,
            spentUSD: spentUSD,
            limitUSD: limitUSD,
            relaxedUntil: relaxedUntil
        )
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    @Test("a zero limit is blocked with no fraction, never a zero-percent gauge")
    func zeroLimitIsBlocked() {
        let signal = ModelBudgetSignal(
            input: Self.input(spentUSD: 0, limitUSD: 0),
            now: Self.now
        )

        #expect(signal.state == .blocked)
        #expect(signal.fraction == nil)
        #expect(signal.isAlarming)
    }

    @Test("threshold boundaries use the shared BorderDash levels and exhaust at 100 percent")
    func thresholdBoundaries() {
        let cases: [(spentUSD: Double, expectedState: ModelBudgetSignal.State)] = [
            (49.99, .trace),
            (50.00, .notice),
            (74.99, .notice),
            (75.00, .amber),
            (89.99, .amber),
            (90.00, .alarm),
            (99.99, .alarm),
            (100.00, .exhausted),
            (125.00, .exhausted),
        ]

        for testCase in cases {
            let signal = ModelBudgetSignal(
                input: Self.input(spentUSD: testCase.spentUSD, limitUSD: 100),
                now: Self.now
            )
            #expect(signal.state == testCase.expectedState)
        }
    }

    @Test("drawing fraction clamps while factual amounts remain honest")
    func drawingFractionClampsWithoutChangingAmounts() {
        let signal = ModelBudgetSignal(
            input: Self.input(spentUSD: 125, limitUSD: 100),
            now: Self.now
        )

        #expect(signal.fraction == 1)
        #expect(signal.spentUSD == 125)
        #expect(signal.limitUSD == 100)
    }

    @Test("negative and non-finite values are invalid without a fraction")
    func invalidNumericInputs() {
        let cases = [
            Self.input(spentUSD: -0.01, limitUSD: 100),
            Self.input(spentUSD: 1, limitUSD: -0.01),
            Self.input(spentUSD: .nan, limitUSD: 100),
            Self.input(spentUSD: .infinity, limitUSD: 100),
            Self.input(spentUSD: 1, limitUSD: .nan),
            Self.input(spentUSD: 1, limitUSD: .infinity),
        ]

        for input in cases {
            let signal = ModelBudgetSignal(input: input, now: Self.now)
            #expect(signal.state == .invalid)
            #expect(signal.fraction == nil)
            #expect(!signal.isAlarming)
        }
    }

    @Test("an active cooldown suppresses alarm only before its expiry boundary")
    func cooldownExpiryBoundary() {
        let until = Self.now.addingTimeInterval(60)
        let input = Self.input(spentUSD: 90, limitUSD: 100, relaxedUntil: until)

        let active = ModelBudgetSignal(input: input, now: Self.now)
        let atExpiry = ModelBudgetSignal(input: input, now: until)
        let expired = ModelBudgetSignal(input: input, now: until.addingTimeInterval(1))

        #expect(active.state == .relaxed(until: until))
        #expect(!active.isAlarming)
        #expect(atExpiry.state == .alarm)
        #expect(atExpiry.isAlarming)
        #expect(expired.state == .alarm)
        #expect(expired.isAlarming)
    }

    @Test("most-urgent selection puts a blocked cap ahead of a high fractional alarm")
    func mostUrgentPrioritizesBlockedCap() {
        let selected = ModelBudgetSignal.mostUrgent(
            from: [
                Self.input(model: "aihub/z-blocked", spentUSD: 0, limitUSD: 0),
                Self.input(model: "aihub/a-alarm", spentUSD: 99, limitUSD: 100),
            ],
            now: Self.now
        )

        #expect(selected?.model == "aihub/z-blocked")
        #expect(selected?.state == .blocked)
    }

    @Test("most-urgent selection orders lower enforced bands by fraction then model id")
    func mostUrgentUsesFractionAndModelIDTieBreak() {
        let highest = ModelBudgetSignal.mostUrgent(
            from: [
                Self.input(model: "aihub/a-lower", spentUSD: 74, limitUSD: 100),
                Self.input(model: "aihub/z-higher", spentUSD: 80, limitUSD: 100),
            ],
            now: Self.now
        )
        let tied = ModelBudgetSignal.mostUrgent(
            from: [
                Self.input(model: "aihub/z-tied", spentUSD: 80, limitUSD: 100),
                Self.input(model: "aihub/a-tied", spentUSD: 80, limitUSD: 100),
            ],
            now: Self.now
        )

        #expect(highest?.model == "aihub/z-higher")
        #expect(tied?.model == "aihub/a-tied")
    }

    @Test("most-urgent selection orders alarm caps by fraction before model id")
    func mostUrgentOrdersAlarmCapsByFraction() {
        let selected = ModelBudgetSignal.mostUrgent(
            from: [
                Self.input(model: "aihub/a-lower-alarm", spentUSD: 91, limitUSD: 100),
                Self.input(model: "aihub/z-higher-alarm", spentUSD: 99, limitUSD: 100),
            ],
            now: Self.now
        )

        #expect(selected?.model == "aihub/z-higher-alarm")
    }

    @Test("most-urgent selection excludes active cooldowns while an enforced cap exists")
    func mostUrgentExcludesActiveCooldown() {
        let selected = ModelBudgetSignal.mostUrgent(
            from: [
                Self.input(
                    model: "aihub/a-relaxed",
                    spentUSD: 150,
                    limitUSD: 100,
                    relaxedUntil: Self.now.addingTimeInterval(60)
                ),
                Self.input(model: "aihub/z-enforced", spentUSD: 1, limitUSD: 100),
            ],
            now: Self.now
        )

        #expect(selected?.model == "aihub/z-enforced")
        #expect(selected?.state == .trace)
    }

    @Test("most-urgent selection returns nil for no caps")
    func mostUrgentEmptyArray() {
        #expect(ModelBudgetSignal.mostUrgent(from: [], now: Self.now) == nil)
    }

    @Test("display names remove the Claude route prefix and make route segments human-readable")
    func displayNames() {
        let cases = [
            "aihub/claude-opus-5": "Opus 5",
            "claude-opus-5": "Opus 5",
            "gpt-5.6-luna-pro": "GPT 5.6 Luna Pro",
            "acme-vision-2": "Acme Vision 2",
            "vendor/strange-model-2": "Strange Model 2",
            "  aihub/claude-opus--5  ": "Opus 5",
            "": "Unknown Model",
            "   ": "Unknown Model",
            "aihub/": "Unknown Model",
            "///": "Unknown Model",
            "--": "Unknown Model",
        ]

        for (routeID, expectedName) in cases {
            #expect(ModelBudgetSignal.displayName(for: routeID) == expectedName)
        }
    }

    @Test("a global exhausted sentence wins over an active model cooldown")
    func narrativePrioritizesGlobalExhaustion() {
        let signal = ModelBudgetSignal(
            input: Self.input(
                spentUSD: 90,
                limitUSD: 100,
                relaxedUntil: Self.now.addingTimeInterval(60)
            ),
            now: Self.now
        )
        let globalSentence = "Reached at 3:12 pm · resets at midnight"

        let sentence = ModelBudgetSignal.narrative(
            globalSentence: globalSentence,
            globalExhausted: true,
            selectedModel: signal,
            timeZone: Self.utc,
            calendar: Self.utcCalendar
        )

        #expect(sentence == globalSentence)
    }

    @Test("an active cooldown uses local injected time formatting")
    func narrativeDescribesActiveCooldown() {
        let now = Self.date(year: 2026, month: 1, day: 2, hour: 1)
        let until = Self.date(year: 2026, month: 1, day: 2, hour: 3)
        let signal = ModelBudgetSignal(
            input: Self.input(spentUSD: 90, limitUSD: 100, relaxedUntil: until),
            now: now
        )

        let sentence = ModelBudgetSignal.narrative(
            globalSentence: "On pace to stay under budget today.",
            globalExhausted: false,
            selectedModel: signal,
            timeZone: Self.utc,
            calendar: Self.utcCalendar
        )

        #expect(sentence == "Opus 5 limit relaxed until 3:00 am")
    }

    @Test("an active cooldown respects a non-UTC injected local timezone")
    func narrativeUsesInjectedNonUTCTimeZone() {
        let now = Self.date(year: 2026, month: 1, day: 2, hour: 1)
        let until = Self.date(year: 2026, month: 1, day: 2, hour: 3)
        let signal = ModelBudgetSignal(
            input: Self.input(spentUSD: 90, limitUSD: 100, relaxedUntil: until),
            now: now
        )
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!

        let sentence = ModelBudgetSignal.narrative(
            globalSentence: "On pace to stay under budget today.",
            globalExhausted: false,
            selectedModel: signal,
            timeZone: kolkata,
            calendar: Self.utcCalendar
        )

        #expect(sentence == "Opus 5 limit relaxed until 8:30 am")
    }

    @Test("a blocked or exhausted model yields to the reached sentence")
    func narrativeDescribesReachedModelCap() {
        let blocked = ModelBudgetSignal(
            input: Self.input(spentUSD: 0, limitUSD: 0),
            now: Self.now
        )
        let exhausted = ModelBudgetSignal(
            input: Self.input(spentUSD: 100, limitUSD: 100),
            now: Self.now
        )

        for signal in [blocked, exhausted] {
            let sentence = ModelBudgetSignal.narrative(
                globalSentence: "On pace to stay under budget today.",
                globalExhausted: false,
                selectedModel: signal,
                timeZone: Self.utc,
                calendar: Self.utcCalendar
            )
            #expect(sentence == "Opus 5 limit reached · other models available")
        }
    }

    @Test("no selected model preserves the existing global sentence verbatim")
    func narrativePreservesGlobalSentenceWithoutModelCap() {
        let globalSentence = "Typical day: $42 — you're at $17."

        let sentence = ModelBudgetSignal.narrative(
            globalSentence: globalSentence,
            globalExhausted: false,
            selectedModel: nil,
            timeZone: Self.utc,
            calendar: Self.utcCalendar
        )

        #expect(sentence == globalSentence)
    }

    @Test("global exhaustion wins over a blocked model in composed narrative")
    func composedNarrativePrioritizesGlobalExhaustion() {
        let blocked = ModelBudgetSignal(
            input: Self.input(spentUSD: 0, limitUSD: 0),
            now: Self.now
        )
        let globalSentence = "Reached at 3:12 pm · resets at midnight"

        let sentence = ModelBudgetSignal.narrative(
            globalSentence: globalSentence,
            globalVerdict: .exhausted(reachedAt: Self.now),
            modelSignals: [blocked],
            timeZone: Self.utc,
            calendar: Self.utcCalendar
        )

        #expect(sentence == globalSentence)
    }

    @Test("composed narrative shows an active model cooldown")
    func composedNarrativeShowsModelCooldown() {
        let now = Self.date(year: 2026, month: 1, day: 2, hour: 1)
        let until = Self.date(year: 2026, month: 1, day: 2, hour: 3)
        let relaxed = ModelBudgetSignal(
            input: Self.input(spentUSD: 90, limitUSD: 100, relaxedUntil: until),
            now: now
        )

        let sentence = ModelBudgetSignal.narrative(
            globalSentence: "On pace to stay under budget today.",
            globalVerdict: .pace(eta: until),
            modelSignals: [relaxed],
            timeZone: Self.utc,
            calendar: Self.utcCalendar
        )

        #expect(sentence == "Opus 5 limit relaxed until 3:00 am")
    }

    @Test("active cooldown wins over a blocked cap regardless of input order")
    func composedNarrativeCooldownWinsRegardlessOfOrder() {
        let now = Self.date(year: 2026, month: 1, day: 2, hour: 1)
        let until = Self.date(year: 2026, month: 1, day: 2, hour: 3)
        let relaxed = ModelBudgetSignal(
            input: Self.input(
                model: "aihub/claude-opus-5",
                spentUSD: 90,
                limitUSD: 100,
                relaxedUntil: until
            ),
            now: now
        )
        let blocked = ModelBudgetSignal(
            input: Self.input(model: "aihub/z-blocked", spentUSD: 0, limitUSD: 0),
            now: now
        )
        let expected = "Opus 5 limit relaxed until 3:00 am"
        let sentences = [
            [relaxed, blocked],
            [blocked, relaxed],
        ].map { signals in
            ModelBudgetSignal.narrative(
                globalSentence: "On pace to stay under budget today.",
                globalVerdict: .pace(eta: until),
                modelSignals: signals,
                timeZone: Self.utc,
                calendar: Self.utcCalendar
            )
        }

        #expect(sentences == [expected, expected])
    }

    @Test("composed narrative shows a blocked or exhausted model cap")
    func composedNarrativeShowsModelCap() {
        let signals = [
            ModelBudgetSignal(input: Self.input(spentUSD: 0, limitUSD: 0), now: Self.now),
            ModelBudgetSignal(input: Self.input(spentUSD: 100, limitUSD: 100), now: Self.now)
        ]

        for signal in signals {
            let sentence = ModelBudgetSignal.narrative(
                globalSentence: "On pace to stay under budget today.",
                globalVerdict: .pace(eta: Self.now),
                modelSignals: [signal],
                timeZone: Self.utc,
                calendar: Self.utcCalendar
            )

            #expect(sentence == "Opus 5 limit reached · other models available")
        }
    }

    @Test("composed narrative preserves the ordinary global sentence")
    func composedNarrativePreservesGlobalSentence() {
        let globalSentence = "Typical day: $42 — you're at $17."
        let quiet = ModelBudgetSignal(input: Self.input(spentUSD: 20, limitUSD: 100), now: Self.now)

        let sentence = ModelBudgetSignal.narrative(
            globalSentence: globalSentence,
            globalVerdict: .pace(eta: Self.now),
            modelSignals: [quiet],
            timeZone: Self.utc,
            calendar: Self.utcCalendar
        )

        #expect(sentence == globalSentence)
    }

    @Test("accessibility values include state words without duplicating the row label")
    func accessibilityValuesExposeState() {
        let testNow = Self.date(year: 2026, month: 1, day: 2, hour: 1)
        let until = Self.date(year: 2026, month: 1, day: 2, hour: 3)
        let blocked = ModelBudgetSignal(input: Self.input(spentUSD: 18.42, limitUSD: 0), now: testNow)
        let exhausted = ModelBudgetSignal(input: Self.input(spentUSD: 20, limitUSD: 20), now: testNow)
        let relaxed = ModelBudgetSignal(
            input: Self.input(spentUSD: 18.42, limitUSD: 20, relaxedUntil: until),
            now: testNow
        )
        let quiet = ModelBudgetSignal(input: Self.input(spentUSD: 2, limitUSD: 20), now: testNow)

        #expect(blocked.accessibilityValue(amountText: "$18.42 of $0", timeZone: Self.utc, calendar: Self.utcCalendar)
            == "$18.42 of $0, limit reached")
        #expect(exhausted.accessibilityValue(amountText: "$20 of $20", timeZone: Self.utc, calendar: Self.utcCalendar)
            == "$20 of $20, limit reached")
        #expect(relaxed.accessibilityValue(amountText: "$18.42 of $20", timeZone: Self.utc, calendar: Self.utcCalendar)
            == "$18.42 of $20, relaxed until 3:00 am")
        #expect(quiet.accessibilityValue(amountText: "$2 of $20", timeZone: Self.utc, calendar: Self.utcCalendar)
            == "$2 of $20")
    }
}

@Test("mostUrgent returns nil when every candidate is invalid")
func mostUrgentAllInvalidReturnsNil() {
    let bad = [
        ModelBudgetInput(model: "a", spentUSD: Double.nan, limitUSD: 20),
        ModelBudgetInput(model: "b", spentUSD: -1, limitUSD: 20),
        ModelBudgetInput(model: "c", spentUSD: 5, limitUSD: -2),
    ]
    for candidate in [bad, bad.reversed()] {
        #expect(ModelBudgetSignal.mostUrgent(from: Array(candidate), now: Date()) == nil,
                "all invalid should yield nil")
    }
}

@Test("mostUrgent returns nil when the only input is invalid")
func mostUrgentSingleInvalidReturnsNil() {
    let bad = ModelBudgetInput(model: "x", spentUSD: Double.nan, limitUSD: 0)
    #expect(ModelBudgetSignal.mostUrgent(from: [bad], now: Date()) == nil)
}

@Test("mostUrgent never selects invalid even when mixed with renderable caps")
func mostUrgentNeverSelectsInvalidAmongRenderable() {
    let bad = ModelBudgetInput(model: "a", spentUSD: Double.nan, limitUSD: 20)
    let good = ModelBudgetInput(model: "b", spentUSD: 5, limitUSD: 20)
    let selected = ModelBudgetSignal.mostUrgent(from: [bad, good], now: Date())
    #expect(selected?.state != nil && selected!.state != .invalid, "selected must be renderable")
    #expect(selected?.model == "b")
}
