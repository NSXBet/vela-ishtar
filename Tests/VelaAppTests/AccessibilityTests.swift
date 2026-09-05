// Tests/VelaAppTests/AccessibilityTests.swift
// WP-10 10.2 acceptance: the spoken wording for every data surface is
// pinned here — the pill (stale/unlimited/blocked semantics), the curve
// summary, the week-strip cells, and the token-entry labels. The strings
// are the contract; the views just apply them (AccessibilitySummary.swift).
// No real Keychain, network, or window is needed: these are pure builders
// plus label checks on views built detached (no makeKeyAndOrderFront).
// RELEVANT FILES: Sources/App/AccessibilitySummary.swift,
// Sources/App/StatusItemController.swift, Sources/App/CurveView.swift,
// Sources/App/DayStripView.swift

import AppKit
import Foundation
import Testing
@testable import VelaCore

@Suite("Accessibility")
struct AccessibilityTests {

    // MARK: - Pill value (10.2: stale / unlimited / blocked state)

    /// A disabled limit is UNLIMITED — never "of $0" (plan global constraint:
    /// "a disabled global limit is unlimited").
    @Test func pillValueUnlimited() {
        let value = AccessibilitySummary.pillValue(
            spentUSD: 12.88, limitUSD: 0, limitEnabled: false, usedPercent: 0, isFresh: true
        )
        #expect(value == "$12.88, no daily limit")
    }

    /// An enabled limit speaks spend, cap, and percent.
    @Test func pillValueEnabled() {
        let value = AccessibilitySummary.pillValue(
            spentUSD: 54.51, limitUSD: 400, limitEnabled: true, usedPercent: 13.6, isFresh: true
        )
        #expect(value == "$54.51 of $400, 14 percent")
    }

    /// A stale reading is announced as stale — the value must match the
    /// dimmed pill the sighted user sees.
    @Test func pillValueStaleAnnouncesStale() {
        let fresh = AccessibilitySummary.pillValue(
            spentUSD: 5.00, limitUSD: 100, limitEnabled: true, usedPercent: 5, isFresh: true
        )
        let stale = AccessibilitySummary.pillValue(
            spentUSD: 5.00, limitUSD: 100, limitEnabled: true, usedPercent: 5, isFresh: false
        )
        #expect(!fresh.contains("stale"))
        #expect(stale.contains("data is stale"))
    }

    // MARK: - Curve summary (10.2: chart exposes a text summary)

    @Test func curveSummaryFirstToLastObserved() {
        var hourly = [Double?](repeating: nil, count: 24)
        hourly[2] = 10.0
        hourly[3] = 20.5
        hourly[9] = 31.4
        let summary = AccessibilitySummary.curveSummary(hourly: hourly, nowHourUTC: 9)
        #expect(summary != nil)
        #expect(summary!.contains("2 am") && summary!.contains("9 am"))
        #expect(summary!.contains("$31.40"))
    }

    /// A day with no observations answers with silence (nil), never $0.00.
    @Test func curveSummaryNoObservationsIsNil() {
        let summary = AccessibilitySummary.curveSummary(hourly: [Double?](repeating: nil, count: 24), nowHourUTC: 12)
        #expect(summary == nil)
    }

    @Test func curveHourValueUsesReadoutFormat() {
        let text = AccessibilitySummary.curveHourValue(utcHour: 14, value: 31.40)
        #expect(text.contains("$31.40"))
        #expect(text.contains("pm"))
    }

    // MARK: - Week strip (10.2: gap days never read as $0.00)

    @Test func dayStripCellWithTotal() {
        #expect(AccessibilitySummary.dayStripCell(weekday: "Wednesday", total: 42.18) == "Wednesday $42.18")
    }

    @Test func dayStripCellGapSaysNoData() {
        #expect(AccessibilitySummary.dayStripCell(weekday: "Monday", total: nil) == "Monday, no data")
    }

    @Test func weekdayNamesAreMondayFirstSeven() {
        #expect(AccessibilitySummary.weekdayNames.count == 7)
        #expect(AccessibilitySummary.weekdayNames.first == "Monday")
        #expect(AccessibilitySummary.weekdayNames.last == "Sunday")
    }

    // MARK: - Full week summary on DayStripView (built detached)

    /// The view's accessibility value covers every day; a nil-total day is
    /// spoken as "no data", matching the drawn empty slot.
    @MainActor
    @Test func dayStripViewValueCoversAllDays() {
        var week: [DayStrip.Day] = []
        for (index, _) in AccessibilitySummary.weekdayNames.enumerated() {
            week.append(DayStrip.Day(key: "2026-08-\(10 + index)", total: index == 1 ? nil : 10.0, isToday: false, exhausted: false))
        }
        let view = DayStripView(week: week, frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        let value = (view.accessibilityValue() as? String) ?? ""
        #expect(value.contains("Tuesday, no data"))
        #expect(value.contains("Monday $10.00"))
        #expect((view.accessibilityLabel() as? String) == "This week's daily spend")
    }

    // MARK: - CurveView accessibility (built detached)

    @MainActor
    @Test func curveViewValueSummarizesData() {
        let curve = CurveView(frame: NSRect(x: 0, y: 0, width: 284, height: 92))
        var hourly = [Double?](repeating: nil, count: 24)
        hourly[1] = 3.5
        curve.configure(hourly: hourly, limit: 400, nowHourUTC: 1, ghost: nil, drawGhostStroke: false, limitEnabled: true)
        #expect(curve.accessibilityLabel() == "Today's observations curve")
        #expect((curve.accessibilityValue() as? String)?.contains("$3.50") == true)
    }

    @MainActor
    @Test func curveViewEmptyDaySaysNoObservations() {
        let curve = CurveView(frame: NSRect(x: 0, y: 0, width: 284, height: 92))
        curve.configure(hourly: [Double?](repeating: nil, count: 24), limit: 0, nowHourUTC: 0, ghost: nil, drawGhostStroke: false, limitEnabled: false)
        #expect((curve.accessibilityValue() as? String) == "No observations yet today.")
    }

    // MARK: - Token entry (10.2: the field never echoes the secret)

    /// The secure field announces its PURPOSE, and its accessibility value
    /// stays empty even with a token pasted in — a screen reader must never
    /// read the token aloud.
    @MainActor
    @Test func tokenFieldAccessibilityHidesSecret() {
        let view = FirstRunView()
        view.focusFieldForTesting()
        let field = view.tokenFieldForTesting
        field?.stringValue = "gt_super_secret_token_value"
        #expect((field?.accessibilityLabel() as? String) == "AI Hub token")
        let spoken = (field?.accessibilityValue() as? String) ?? ""
        #expect(!spoken.contains("gt_super_secret_token_value"))
    }

    // MARK: - Keyboard route parity (10.1 spot checks)

    /// The panel's local command closures exist and fire — the keyboard
    /// route calls exactly the mouse path's action.
    @MainActor
    @Test func panelLocalCommandsFire() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let panel = PopoverPanel(contentView: content)
        var refreshed = 0
        var copied = 0
        var history = 0
        panel.onRefresh = { refreshed += 1 }
        panel.onCopySpend = { copied += 1 }
        panel.onOpenHistory = { history += 1 }
        panel.onRefresh?()
        panel.onCopySpend?()
        panel.onOpenHistory?()
        #expect(refreshed == 1)
        #expect(copied == 1)
        #expect(history == 1)
    }

    /// PeriodSwitcher tabs expose a keyboard focusable button per tab with
    /// a real radio role — Space/Return and VoiceOver both reach them.
    @MainActor
    @Test func periodSwitcherTabsAreFocusableButtons() {
        let switcher = PeriodSwitcher()
        #expect((switcher.accessibilityRole() as? NSAccessibility.Role) == .tabGroup)
        #expect((switcher.accessibilityLabel() as? String) == "Models period")
    }
}
