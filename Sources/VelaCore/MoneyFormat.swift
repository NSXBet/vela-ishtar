// Sources/VelaCore/MoneyFormat.swift
// Pure, shared money and rate formatting — the single place dollar figures,
// percentages, and blended $/M rates become display strings. Extracted from
// PopoverView's inline blended-rate formatting so tests can pin the rules
// and every surface (hero, model rows, pill) shows identical numbers.
// Why: formatting scattered across call sites drifts (B11's "of $400 today"
// survived because no shared formatter existed to ask), and the $/M path
// had no non-finite/zero guard — a single garbage row could trap the popover.
// RELEVANT FILES: Sources/VelaCore/UsageValidation.swift, Sources/App/PopoverView.swift,
// Tests/VelaCoreTests/MoneyFormatTests.swift

import Foundation

public enum MoneyFormat {
    // MARK: - Dollars

    /// "$109.42" — the standard cost format. Non-finite and negative inputs
    /// are impossible past validation, but the formatter stays total: an
    /// unsafe value renders as "—" rather than a trap or a lie.
    public static func dollars(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return String(format: "$%.2f", value)
    }

    /// "$400" — whole-dollar hero suffix ("of $400 today"). B11's surface:
    /// callers must pass nil for unlimited so no-limit never renders a limit.
    public static func dollarsRounded(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return String(format: "$%.0f", value)
    }

    /// The hero suffix for a daily limit. `limitEnabled == false` (B11: no
    /// limit configured) returns nil — the hero renders spend alone, never
    /// "of $X today" for a limit that doesn't exist. A zero limit that IS
    /// enabled is a real $0 limit (blocked state) and renders "of $0 today".
    public static func heroSuffix(limit: Double, limitEnabled: Bool) -> String? {
        guard limitEnabled else { return nil }
        return " of \(dollarsRounded(limit)) today"
    }

    // MARK: - Percent

    /// Whole-number percentage of a total, rounded to nearest, clamped to
    /// 0...100 on the Double BEFORE the Int conversion (B03 — no Int trap).
    public static func percent(cost: Double, total: Double) -> Int {
        // Infinite total with a finite nonzero cost = a real (tiny) share,
        // not the infinity trap. Everything else unsafe → 0.
        guard total > 0 || total == .infinity else { return 0 }
        guard cost > 0, cost.isFinite else { return 0 }
        let raw = (cost / total) * 100
        guard raw.isFinite else { return 0 }
        let clamped = min(100.0, max(0.0, raw))
        return max(0, Int(clamped.rounded()))
    }

    // MARK: - Blended $/M rate

    /// Observed blended rate: cost per million tokens. "Observed" is the
    /// truthful label — this is spend divided by tokens, not a per-token
    /// price. Tokens <= 0 (no usage) renders as an em-dash; past $999/M the
    /// label switches to compact "$1.2k/M" so expensive models don't clip
    /// the column. Non-finite results render as "—".
    public static func blendedRate(cost: Double, tokens: Int) -> String {
        guard tokens > 0, cost.isFinite, cost >= 0 else { return "—" }
        let perMillion = cost / (Double(tokens) / 1_000_000)
        // Finite but absurd (1e300 spent on one token): still refuse to
        // render — the compact form can't carry it truthfully.
        guard perMillion.isFinite, perMillion < 1e6 else { return "—" }
        if perMillion >= 1000 {
            return String(format: "$%.1fk/M", perMillion / 1000)
        }
        return String(format: "$%.2f/M", perMillion)
    }
}
