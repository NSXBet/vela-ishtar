// Sources/VelaCore/ModelBudgetSignal.swift
// Classifies one gateway model-budget record, selects the most urgent cap,
// derives a human-readable model name, and composes model-cap narrative copy.
// Why: nested model caps have zero-limit and cooldown semantics that differ
// from the global budget, so this pure module keeps those rules out of AppKit.
// Display-name rule: use the final route segment, drop only a leading
// `claude-` token, split remaining hyphen/underscore/whitespace tokens, title-
// case words, and keep known acronyms (such as GPT) uppercase; empty results
// become "Unknown Model" rather than exposing a raw route slug.
// RELEVANT FILES: Tests/VelaCoreTests/ModelBudgetSignalTests.swift, Sources/VelaCore/BorderDash.swift, Sources/VelaCore/PaceEngine.swift

import Foundation

/// The minimum gateway model-budget fields this pure module needs. It stays
/// independent of the app DTO so Stage 2 can be tested before response wiring.
public struct ModelBudgetInput: Equatable, Sendable {
    public let model: String
    public let spentUSD: Double
    public let limitUSD: Double
    public let relaxedUntil: Date?

    public init(model: String, spentUSD: Double, limitUSD: Double, relaxedUntil: Date? = nil) {
        self.model = model
        self.spentUSD = spentUSD
        self.limitUSD = limitUSD
        self.relaxedUntil = relaxedUntil
    }
}

/// A derived, rendering-safe view of one model cap at a fixed instant.
public struct ModelBudgetSignal: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Input has a negative or non-finite monetary value and cannot draw.
        case invalid
        /// A zero limit is an enforced gateway block, not an unlimited cap.
        case blocked
        /// The model cap is temporarily unenforced through this instant.
        case relaxed(until: Date)
        /// A valid enabled cap with no spending yet.
        case empty
        /// Below the shared notice threshold.
        case trace
        /// At or above the shared notice threshold.
        case notice
        /// At or above the shared amber threshold.
        case amber
        /// At or above the shared alarm threshold but below exhaustion.
        case alarm
        /// At or above the factual 100% limit.
        case exhausted
    }

    /// Gateway route identifier, retained for deterministic tie-breaking.
    public let model: String

    /// Factual gateway values, never clamped so display copy stays honest.
    public let spentUSD: Double
    public let limitUSD: Double

    /// Rendering-only fill fraction. Invalid and blocked caps have no fraction.
    public let fraction: Double?
    public let state: State

    /// Classifies a model budget without reading the wall clock.
    public init(input: ModelBudgetInput, now: Date) {
        model = input.model
        spentUSD = input.spentUSD
        limitUSD = input.limitUSD

        // Validate before touching division: an invalid value must not turn a
        // gauge backwards or trigger an Int/Infinity conversion in the view.
        guard input.spentUSD.isFinite,
              input.limitUSD.isFinite,
              input.spentUSD >= 0,
              input.limitUSD >= 0 else {
            fraction = nil
            state = .invalid
            return
        }

        // The gateway reserves zero for an explicit block, never "no limit".
        guard input.limitUSD > 0 else {
            fraction = nil
            state = .blocked
            return
        }

        // Cooldown semantics take precedence over ordinary banding. The fill
        // is still useful context, but the cap is not enforced while relaxed.
        if let relaxedUntil = input.relaxedUntil, now < relaxedUntil {
            fraction = Self.clampedFraction(spent: input.spentUSD, limit: input.limitUSD)
            state = .relaxed(until: relaxedUntil)
            return
        }

        let fraction = Self.clampedFraction(spent: input.spentUSD, limit: input.limitUSD)
        self.fraction = fraction
        if BorderDash.isFull(input.spentUSD / input.limitUSD) {
            state = .exhausted
            return
        }

        switch BorderDash.level(forFraction: input.spentUSD / input.limitUSD) {
        case .empty:
            state = .empty
        case .trace:
            state = .trace
        case .notice:
            state = .notice
        case .amber:
            state = .amber
        case .alarm:
            state = .alarm
        }
    }

    /// The model-limit pill dot: enforceable blocks and 90%+ enabled caps.
    public var isAlarming: Bool {
        switch state {
        case .blocked:
            return true
        case .relaxed, .invalid:
            return false
        default:
            return (fraction ?? 0) >= BorderDash.alarmThreshold
        }
    }

    /// Picks a reproducible single cap for v1 rendering. Enforced caps always
    /// outrank active cooldowns; stable route-ID ordering settles equal cases.
    public static func mostUrgent(
        from inputs: [ModelBudgetInput],
        now: Date
    ) -> ModelBudgetSignal? {
        mostUrgent(from: inputs.map { ModelBudgetSignal(input: $0, now: now) })
    }

    /// Selects the most urgent already-derived signal. Keeping this separate
    /// lets narrative composition use the complete signal set without
    /// rebuilding state or moving priority rules into AppKit.
    public static func mostUrgent(from signals: [ModelBudgetSignal]) -> ModelBudgetSignal? {
        // `.invalid` marks unrenderable input; it must never be selected, or a
        // negative/non-finite amount could reach the row. Filter before
        // sorting so the comparator never has to guard mixed ranks itself.
        signals
            .filter { $0.state != .invalid }
            .sorted(by: isMoreUrgent)
            .first
    }

    /// Human copy for gateway route identifiers, never a kebab-cased slug.
    public static func displayName(for routeID: String) -> String {
        guard let finalSegment = routeID
            .split(separator: "/", omittingEmptySubsequences: false)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !finalSegment.isEmpty else {
            return "Unknown Model"
        }

        var tokens = finalSegment.split(whereSeparator: {
            $0 == "-" || $0 == "_" || $0.isWhitespace
        })
        if tokens.first?.lowercased() == "claude" {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { return "Unknown Model" }

        let words = tokens.map { token -> String in
            let lowercaseToken = token.lowercased()
            switch lowercaseToken {
            case "gpt", "llm", "api":
                return lowercaseToken.uppercased()
            default:
                return lowercaseToken.prefix(1).uppercased() + lowercaseToken.dropFirst()
            }
        }
        return words.joined(separator: " ")
    }

    /// Composes the global and model narratives in the approved priority
    /// order. The view passes every derived signal; it does not decide which
    /// model state gets the sentence slot.
    public static func narrative(
        globalSentence: String,
        globalVerdict: PaceVerdict,
        modelSignals: [ModelBudgetSignal],
        timeZone: TimeZone,
        calendar: Calendar
    ) -> String {
        if case .exhausted = globalVerdict {
            return globalSentence
        }

        let activeCooldown = modelSignals
            .filter {
                if case .relaxed = $0.state { return true }
                return false
            }
            .sorted { $0.model < $1.model }
            .first
        if let activeCooldown, case .relaxed(let until) = activeCooldown.state {
            let modelName = displayName(for: activeCooldown.model)
            return "\(modelName) limit relaxed until \(localTime(until, timeZone: timeZone, calendar: calendar))"
        }

        if let reached = mostUrgent(from: modelSignals.filter {
            switch $0.state {
            case .blocked, .exhausted:
                return true
            default:
                return false
            }
        }) {
            let modelName = displayName(for: reached.model)
            return "\(modelName) limit reached · other models available"
        }

        return globalSentence
    }

    /// Compatibility overload for callers that already selected one signal.
    /// New composition should use the full-signal overload above.
    public static func narrative(
        globalSentence: String?,
        globalExhausted: Bool,
        selectedModel: ModelBudgetSignal?,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> String? {
        guard let globalSentence else { return nil }
        guard !globalExhausted else { return globalSentence }
        guard let selectedModel else { return globalSentence }
        return narrative(
            globalSentence: globalSentence,
            globalVerdict: .pace(eta: Date.distantFuture),
            modelSignals: [selectedModel],
            timeZone: timeZone,
            calendar: calendar
        )
    }

    /// VoiceOver copy for the model-budget row. State words are included even
    /// when the narrative slot is occupied by a higher-priority global state.
    public func accessibilityValue(
        amountText: String,
        timeZone: TimeZone,
        calendar: Calendar
    ) -> String {
        let stateText: String?
        switch state {
        case .blocked, .exhausted:
            stateText = "limit reached"
        case .relaxed(let until):
            stateText = "relaxed until \(Self.localTime(until, timeZone: timeZone, calendar: calendar))"
        case .alarm:
            stateText = "limit nearly reached"
        default:
            stateText = nil
        }
        return [amountText, stateText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private static func clampedFraction(spent: Double, limit: Double) -> Double {
        min(max(spent / limit, 0), 1)
    }

    private static func isMoreUrgent(_ lhs: ModelBudgetSignal, _ rhs: ModelBudgetSignal) -> Bool {
        let lhsRank = urgencyRank(for: lhs.state)
        let rhsRank = urgencyRank(for: rhs.state)
        if lhsRank != rhsRank { return lhsRank > rhsRank }

        // Within a single rank the fraction order is the semantic tie-break:
        // among same-band caps (notice/amber/alarm) a higher fraction IS more
        // binding, and the spec's stable route-ID tie-break only applies when
        // the fractions are equal. Blocked/exhausted and cooldown fall straight
        // to route-ID because their caps are not comparable in dollars.
        let comparator = lhsRank == 1 || lhsRank == 2
        if comparator, lhs.fraction != rhs.fraction {
            return (lhs.fraction ?? 0) > (rhs.fraction ?? 0)
        }
        return lhs.model < rhs.model
    }

    private static func urgencyRank(for state: State) -> Int {
        switch state {
        case .blocked, .exhausted:
            return 3
        case .alarm:
            return 2
        case .empty, .trace, .notice, .amber:
            return 1
        case .relaxed:
            return 0
        case .invalid:
            return -1
        }
    }

    private static func localTime(_ date: Date, timeZone: TimeZone, calendar: Calendar) -> String {
        var displayCalendar = calendar
        displayCalendar.timeZone = timeZone

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = displayCalendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date).lowercased()
    }
}
