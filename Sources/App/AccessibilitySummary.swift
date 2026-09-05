// Sources/App/AccessibilitySummary.swift
// WP-10 10.2: pure builders for the assistive-tech text every surface
// announces. Why a separate file: the wording rules (stale vs fresh,
// unlimited vs blocked, observed hours vs gaps) are specified and pinned by
// tests here, while each view just calls one function — same split as
// CurveScrub (VelaCore) / CurveView (App). No state, no I/O, no views.
// No interruption is ever requested per silent poll: these strings only
// ride label/value changes that AppKit delivers passively.
// RELEVANT FILES: Tests/VelaAppTests/AccessibilityTests.swift,
// Sources/App/StatusItemController.swift, Sources/App/CurveView.swift,
// Sources/App/DayStripView.swift

import Foundation

public enum AccessibilitySummary {

    // MARK: - Pill (StatusItemController)

    /// The pill's full spoken value: spend, limit semantics, freshness.
    /// A disabled limit is UNLIMITED (never "of $0"); a stale reading is
    /// announced as such so the value matches what the dimmed pill shows.
    public static func pillValue(
        spentUSD: Double,
        limitUSD: Double,
        limitEnabled: Bool,
        usedPercent: Double,
        isFresh: Bool
    ) -> String {
        let spent = String(format: "$%.2f", spentUSD)
        var text: String
        if limitEnabled {
            let percent = Int(usedPercent.rounded())
            text = String(format: "%@ of $%.0f, %d percent", spent, limitUSD, percent)
        } else {
            text = "\(spent), no daily limit"
        }
        if !isFresh { text += ", data is stale" }
        return text
    }

    // MARK: - Curve (CurveView)

    /// Text summary of the whole curve: what the chart shows without hover.
    /// States the observed window honestly — hours before the first reading
    /// are not claimed, gaps stay gaps.
    public static func curveSummary(hourly: [Double?], nowHourUTC: Int) -> String? {
        let observed = hourly.enumerated().compactMap { hour, value -> (Int, Double)? in
            value.map { (hour, $0) }
        }
        guard let first = observed.first else { return nil }
        let latestValue = observed.last!.1
        let from = Self.hourWord(first.0)
        let to = Self.hourWord(observed.last!.0)
        return String(format: "Today's observations from %@ to %@, latest $%.2f.", from, to, latestValue)
    }

    /// One observed hour, as the scrub readout words it: "2 pm · $31.40".
    public static func curveHourValue(utcHour: Int, value: Double) -> String {
        CurveScrub.readoutText(utcHour: utcHour, value: value)
    }

    // MARK: - Week strip (DayStripView)

    /// One day cell: "Wednesday $42.18" or "Wednesday, no data" — a gap day
    /// never reads as $0.00.
    public static func dayStripCell(weekday: String, total: Double?) -> String {
        if let total {
            return String(format: "%@ $%.2f", weekday, total)
        }
        return "\(weekday), no data"
    }

    // MARK: - helpers

    private static func hourWord(_ utcHour: Int) -> String {
        let hour12 = utcHour % 12 == 0 ? 12 : utcHour % 12
        let meridiem = utcHour < 12 ? "am" : "pm"
        return "\(hour12) \(meridiem)"
    }

    /// Weekday names Monday-first, fixed so the spoken day always matches
    /// the visible M T W T F S S letters regardless of locale.
    static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
}
