// Sources/VelaCore/FooterLayout.swift
// The popover footer's horizontal arithmetic: where the three quiet links sit,
// where the health dot lands, and whether the full timestamp still fits.
// Why this lives in VelaCore: the footer has bitten twice in the same way —
// "✓ Start at login" ran into the green dot, and the nudge meant to open that
// gap moved the button TOWARD the dot instead. Both were arithmetic mistakes in
// a row whose spacing was emergent rather than stated: the login link sat at a
// hardcoded x while the dot right-anchored behind a variable-width label, so
// nothing in the code said how much space belonged between them. Stating it
// here — a pure function with the gaps as named inputs — pins the invariants
// ("nothing overlaps", "the login→dot gap is identical in every state") with
// tests instead of re-measuring a screenshot.
// RELEVANT FILES: Tests/VelaCoreTests/FooterLayoutTests.swift, Sources/App/PopoverView.swift

import Foundation

public enum FooterLayout {

    /// A laid-out element: its left edge and frame width.
    public struct Slot: Equatable, Sendable {
        public let x: Double
        public let width: Double
        public var end: Double { x + width }
        public init(x: Double, width: Double) {
            self.x = x
            self.width = width
        }
    }

    /// One laid-out footer row.
    public struct Result: Equatable, Sendable {
        public let dashboard: Slot
        public let apiKey: Slot
        public let login: Slot
        /// The health dot's left edge.
        public let dotX: Double
        /// The right-anchored status label's left edge.
        public let statusX: Double
        /// True when the full "AI Hub · HH:mm:ss" fits; false when the row is
        /// tight and the label falls back to a bare "AI Hub".
        public let showsTimestamp: Bool
    }

    /// Measured glyph widths, supplied by the caller — AppKit does the
    /// measuring so this layer stays pure arithmetic.
    public struct Metrics: Sendable {
        public let dashboard: Double
        public let apiKey: Double
        /// The login title actually being rendered.
        public let login: Double
        /// The WIDEST login title ("✓ Start at login"). The fit decision uses
        /// this, never the current one, so toggling the setting mid-session
        /// can't flip the timestamp on and off.
        public let widestLogin: Double
        public let statusWithTimestamp: Double
        public let statusShort: Double

        public init(dashboard: Double, apiKey: Double, login: Double, widestLogin: Double,
                    statusWithTimestamp: Double, statusShort: Double) {
            self.dashboard = dashboard
            self.apiKey = apiKey
            self.login = login
            self.widestLogin = widestLogin
            self.statusWithTimestamp = statusWithTimestamp
            self.statusShort = statusShort
        }
    }

    /// Spacing rules, each named so a change is a one-line reviewable edit.
    public struct Spacing: Sendable {
        public let totalWidth: Double
        public let sidePadding: Double
        /// Clear space between two adjacent links' frames.
        public let linkSpacing: Double
        /// Slack around a measured title so a borderless button can't clip it.
        public let linkGutter: Double
        /// Clear space between the login link's frame and the health dot —
        /// THE constant behind the "✓ overlaps the green dot" reports.
        public let loginToDotGap: Double
        /// Dot's left edge to the status label's left edge.
        public let dotToStatus: Double

        public init(totalWidth: Double = 320, sidePadding: Double = 18,
                    linkSpacing: Double = 5, linkGutter: Double = 4,
                    loginToDotGap: Double = 12, dotToStatus: Double = 12) {
            self.totalWidth = totalWidth
            self.sidePadding = sidePadding
            self.linkSpacing = linkSpacing
            self.linkGutter = linkGutter
            self.loginToDotGap = loginToDotGap
            self.dotToStatus = dotToStatus
        }
    }

    /// Lay the footer out. The left links flow from the leading margin; the
    /// health unit right-anchors; the login link hangs off the DOT (not off a
    /// hardcoded x), which is what makes the gap between them a constant by
    /// construction rather than an emergent leftover.
    public static func layout(metrics: Metrics, spacing: Spacing = Spacing()) -> Result {
        let dashboardWidth = metrics.dashboard + spacing.linkGutter
        let apiKeyWidth = metrics.apiKey + spacing.linkGutter
        let loginWidth = metrics.login + spacing.linkGutter
        let widestLoginWidth = metrics.widestLogin + spacing.linkGutter

        let dashboard = Slot(x: spacing.sidePadding, width: dashboardWidth)
        let apiKey = Slot(x: dashboard.end + spacing.linkSpacing, width: apiKeyWidth)

        // Would the long timestamp squeeze the WIDEST login title into the
        // "API key" link? If so the timestamp yields — it's nice-to-have.
        let longDotX = spacing.totalWidth - spacing.sidePadding
            - metrics.statusWithTimestamp - spacing.dotToStatus
        let showsTimestamp = longDotX - spacing.loginToDotGap - widestLoginWidth
            >= apiKey.end + spacing.linkSpacing

        let statusWidth = showsTimestamp ? metrics.statusWithTimestamp : metrics.statusShort
        let dotX = spacing.totalWidth - spacing.sidePadding - statusWidth - spacing.dotToStatus

        return Result(
            dashboard: dashboard,
            apiKey: apiKey,
            login: Slot(x: dotX - spacing.loginToDotGap - loginWidth, width: loginWidth),
            dotX: dotX,
            statusX: spacing.totalWidth - spacing.sidePadding - statusWidth,
            showsTimestamp: showsTimestamp
        )
    }
}
