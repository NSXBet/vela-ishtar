// Sources/VelaCore/BudgetOverview.swift
// The complete, presentation-ready budget picture (WP-08, F01 — plan §4.2).
// Why: a global budget can have plenty left while one small model cap is
// exhausted, and v1 only ever showed the single most urgent cap. This module
// derives the FULL nested picture — global policy, every returned model cap
// with its own headroom, the reset context, and freshness — as one pure
// value, so the detail surface renders policy truth instead of re-deriving
// it in AppKit.
// Headroom rule (plan F01): where both the global limit and a model cap are
// enabled and currently enforced, model headroom is
// `max(0, min(globalRemaining, modelRemaining))`. During an active model
// cooldown the MODEL cap is not enforced, so headroom is the global room and
// the signal is explicitly marked relaxed. A zero model cap is a BLOCK
// (zero room, not unlimited). A disabled global limit contributes no bound.
// Nothing here promises request availability: headroom is budget room,
// and "other limits may apply".
// RELEVANT FILES: Sources/VelaCore/UsageContracts.swift, Sources/VelaCore/ModelBudgetSignal.swift,
// Sources/VelaCore/Freshness.swift, Sources/App/BudgetDetailView.swift

import Foundation

// MARK: - BudgetOverview

/// The complete, presentation-ready budget picture.
///
/// §7.2: "Global policy, deterministically sorted model signals,
/// per-model budget headroom, reset description, freshness; no unsupported
/// availability promise" — anything not known is stated as unavailable,
/// never defaulted.
///
/// Moved here verbatim from UsageContracts.swift (WP-08 owns the
/// fleshing-out); names, cases, and semantics are identical to the frozen
/// declaration, with computed state derivations added below. No stored
/// field changed — consumers of the frozen shape are unaffected.
public struct BudgetOverview: Equatable, Sendable {
    /// One model's cap position at the overview's instant.
    public struct ModelSignal: Equatable, Sendable {
        public let model: String
        public let spentUSD: Double
        public let limitUSD: Double?
        /// Spend headroom under the model's own cap, nil when uncapped.
        public let headroomUSD: Double?
        /// Active cooldown bypass of the MODEL cap only, if any.
        public let relaxedUntil: Date?

        public init(model: String, spentUSD: Double, limitUSD: Double?, headroomUSD: Double?, relaxedUntil: Date?) {
            self.model = model
            self.spentUSD = spentUSD
            self.limitUSD = limitUSD
            self.headroomUSD = headroomUSD
            self.relaxedUntil = relaxedUntil
        }
    }

    /// Global daily budget: enabled state and value. A disabled global
    /// limit is UNLIMITED; a model cap of zero is BLOCKED — these are
    /// different semantics and both survive here untouched.
    public let globalLimitEnabled: Bool
    public let globalLimitUSD: Double
    public let globalSpentUSD: Double
    /// Model signals, deterministically sorted (spend descending, then
    /// model name ascending) so equal inputs always render identically.
    public let modelSignals: [ModelSignal]
    /// Human-readable description of when the current window resets
    /// ("resets at UTC midnight" / "no daily limit"), never an invented date.
    public let resetDescription: String
    /// Freshness of the numbers this overview was derived from.
    public let freshness: Freshness

    public init(
        globalLimitEnabled: Bool,
        globalLimitUSD: Double,
        globalSpentUSD: Double,
        modelSignals: [ModelSignal],
        resetDescription: String,
        freshness: Freshness
    ) {
        self.globalLimitEnabled = globalLimitEnabled
        self.globalLimitUSD = globalLimitUSD
        self.globalSpentUSD = globalSpentUSD
        self.modelSignals = modelSignals
        self.resetDescription = resetDescription
        self.freshness = freshness
    }

    // MARK: derived policy state (computed — the frozen field set is intact)

    /// The global limit's policy state, derived from the frozen fields.
    /// Invalid (negative or non-finite figures) surfaces explicitly — it is
    /// never silently laundered into "disabled" or "enabled".
    public enum GlobalPolicyState: Equatable, Sendable {
        case enabled
        case disabled
        case invalid
    }

    public var globalState: GlobalPolicyState {
        guard globalLimitEnabled else { return .disabled }
        guard globalLimitUSD.isFinite, globalLimitUSD >= 0,
              globalSpentUSD.isFinite, globalSpentUSD >= 0 else { return .invalid }
        return .enabled
    }

    /// Remaining room under the global limit: nil when the limit is
    /// disabled (no bound) or its figures are invalid (no trustworthy
    /// number). Clamped at zero — overspend is real but the ROOM is not
    /// negative.
    public var globalRemainingUSD: Double? {
        guard globalState == .enabled else { return nil }
        return max(0, globalLimitUSD - globalSpentUSD)
    }

    public enum ModelSignalState: Equatable, Sendable {
        /// A valid, currently enforced cap (any fill band, including
        /// exhausted — an exhausted cap is still enforcing).
        case enabled
        /// A zero cap: the gateway's explicit block.
        case blocked
        /// An active cooldown bypass of this MODEL cap only.
        case relaxed(until: Date)
        /// Negative or non-finite figures; no trustworthy number exists.
        case invalid
    }

    // MARK: derivation (08.1)

    /// Derives the complete budget picture from a validated snapshot.
    ///
    /// - `snapshot`: the accepted reading; its `dailyBudget` carries the
    ///   global figures and the nested model caps, its `gatewayDay` anchors
    ///   the reset description.
    /// - `freshness`: the trust state of those numbers (WP-04's derivation);
    ///   carried through untouched so the UI can say "last observed" for
    ///   stale data instead of implying liveness.
    /// - `now`: the derivation instant — cooldown activity is judged
    ///   against it, so a cooldown that has since EXPIRED is not marked
    ///   relaxed.
    /// - `calendar`: supplies the time zone for the reset's local-time
    ///   wording (plan §3.4: "resets at midnight" alone is ambiguous
    ///   outside UTC — UTC stays explicit and local time rides along).
    public static func derive(
        from snapshot: UsageSnapshot,
        freshness: Freshness,
        now: Date,
        calendar: Calendar
    ) -> BudgetOverview {
        let budget = snapshot.response.dailyBudget

        let signals = modelSignals(from: budget, globalRemaining: globalRoom(budget), now: now)

        return BudgetOverview(
            globalLimitEnabled: budget.limitEnabled,
            globalLimitUSD: budget.limitUSD,
            globalSpentUSD: budget.spentUSD,
            modelSignals: sorted(signals),
            resetDescription: resetDescription(budget: budget, snapshot: snapshot, calendar: calendar),
            freshness: freshness
        )
    }

    /// The global bound models are nested under: nil when the limit is
    /// disabled or its figures are invalid — either way it contributes no
    /// trustworthy cap.
    private static func globalRoom(_ budget: DailyBudget) -> Double? {
        guard budget.limitEnabled,
              budget.limitUSD.isFinite, budget.limitUSD >= 0,
              budget.spentUSD.isFinite, budget.spentUSD >= 0 else { return nil }
        return max(0, budget.limitUSD - budget.spentUSD)
    }

    /// Derives one signal per returned cap. Concurrent conditions all
    /// surface: every cap gets a signal — a relaxed cap never hides a
    /// blocked one, and an invalid cap is stated, not dropped.
    private static func modelSignals(
        from budget: DailyBudget,
        globalRemaining: Double?,
        now: Date
    ) -> [ModelSignal] {
        budget.modelBudgets.map { cap in
            let input = ModelBudgetSignal.input(from: cap)
            let signal = ModelBudgetSignal(input: input, now: now)

            // Cooldown activity was judged by the classifier against `now`.
            if case .relaxed(let until) = signal.state {
                // The model cap is NOT enforced: global room is the binding
                // bound (F01), marked explicitly relaxed.
                return ModelSignal(
                    model: cap.model, spentUSD: cap.spentUSD, limitUSD: cap.limitUSD,
                    headroomUSD: globalRemaining, relaxedUntil: until
                )
            }

            guard signal.state != .invalid else {
                // No trustworthy number — state it, never guess a room.
                return ModelSignal(
                    model: cap.model, spentUSD: cap.spentUSD, limitUSD: cap.limitUSD,
                    headroomUSD: nil, relaxedUntil: nil
                )
            }

            guard cap.limitUSD > 0 else {
                // Zero cap: an enforced block with zero room.
                return ModelSignal(
                    model: cap.model, spentUSD: cap.spentUSD, limitUSD: cap.limitUSD,
                    headroomUSD: 0, relaxedUntil: nil
                )
            }

            let modelRoom = max(0, cap.limitUSD - cap.spentUSD)
            let room: Double?
            if let globalRemaining {
                room = max(0, min(globalRemaining, modelRoom))
            } else {
                // No global bound (disabled or invalid): the model cap alone.
                room = modelRoom
            }
            return ModelSignal(
                model: cap.model, spentUSD: cap.spentUSD, limitUSD: cap.limitUSD,
                headroomUSD: room, relaxedUntil: nil
            )
        }
    }

    /// The frozen sort: spend descending, then model name ascending.
    /// Non-finite spend sorts last deterministically instead of poisoning
    /// the comparator (NaN comparisons are always false).
    private static func sorted(_ signals: [ModelSignal]) -> [ModelSignal] {
        signals.sorted { lhs, rhs in
            let l = lhs.spentUSD.isFinite ? lhs.spentUSD : -Double.infinity
            let r = rhs.spentUSD.isFinite ? rhs.spentUSD : -Double.infinity
            if l != r { return l > r }
            return lhs.model < rhs.model
        }
    }

    /// The reset line: UTC stays explicit, local time rides along (§3.4).
    /// "no daily limit" for a disabled global limit; "reset unknown" when
    /// there is no trustworthy anchor — never an invented date.
    private static func resetDescription(
        budget: DailyBudget,
        snapshot: UsageSnapshot,
        calendar: Calendar
    ) -> String {
        guard budget.limitEnabled else { return "no daily limit" }
        guard let start = snapshot.gatewayDay.startOfDayUTC else {
            return "reset unknown"
        }
        let nextMidnightUTC = start.addingTimeInterval(24 * 60 * 60)
        return "resets at UTC midnight (\(clockTime(nextMidnightUTC, calendar: calendar)) local)"
    }

    /// "7:00 pm" style clock time — the one formatter reset descriptions,
    /// observation lines, and cooldown expiry wording share.
    public static func clockTime(_ date: Date, calendar: Calendar) -> String {
        var displayCalendar = calendar
        displayCalendar.timeZone = calendar.timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = displayCalendar
        formatter.timeZone = displayCalendar.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date).lowercased()
    }
}

// MARK: - ModelSignal status copy

extension BudgetOverview.ModelSignal {
    /// One model cap's policy state, derived from its stored fields.
    public var state: BudgetOverview.ModelSignalState {
        guard spentUSD.isFinite, spentUSD >= 0,
              let limit = limitUSD, limit.isFinite, limit >= 0 else { return .invalid }
        if limit == 0 { return .blocked }
        if let relaxedUntil { return .relaxed(until: relaxedUntil) }
        return .enabled
    }

    /// The policy status line for this cap. Derived from stored fields only,
    /// so detail rows and accessibility copy always agree.
    public var statusDescription: String {
        switch state {
        case .blocked:
            return "blocked"
        case .relaxed(let until):
            return "relaxed until \(BudgetOverview.clockTime(until, calendar: .current))"
        case .invalid:
            return "unusable data"
        case .enabled:
            if let limit = limitUSD, spentUSD >= limit { return "limit reached" }
            return "cap active"
        }
    }
}
