// Tests/VelaCoreTests/FooterLayoutTests.swift
// Pins pure popover horizontal arithmetic: the footer that produced two bug
// reports ("✓ Start at login overlaps the green dot", then "the
// fix REMOVED a space instead of adding one").
// Why these exist: the old code placed the login link at a hardcoded x while
// the dot right-anchored behind a variable-width label, so the space between
// them was whatever happened to be left over. These tests state the invariants
// the row must hold instead — nothing overlaps, and the login→dot gap is the
// same in every state — so a future nudge can't quietly close the gap again.
// Widths are the real measured values from the shipping fonts (12pt system for
// the links, 11pt monospaced-digit for the status), noted per constant.
// RELEVANT FILES: Sources/VelaCore/FooterLayout.swift, Sources/App/PopoverView.swift

import Testing
import Foundation
@testable import VelaCore

struct FooterLayoutTests {

    // Measured on the shipping fonts (see the probe in the v0.5.2 work):
    //   "Dashboard ↗"      12pt system            = 75
    //   "API key"          12pt system            = 42
    //   "Start at login"   12pt system            = 73
    //   "✓ Start at login" 12pt system            = 87
    //   "AI Hub · 14:32:07" 11pt monospaced digit = 94
    //   "AI Hub"            11pt monospaced digit = 36
    private func metrics(login: Double) -> FooterLayout.Metrics {
        FooterLayout.Metrics(dashboard: 75, apiKey: 42, login: login, widestLogin: 87,
                             statusWithTimestamp: 94, statusShort: 36)
    }
    private let checkedTitle: Double = 87   // "✓ Start at login"
    private let plainTitle: Double = 73     // "Start at login"

    @Test("the login link never overlaps the health dot — the original report")
    func loginClearsTheDot() {
        // The shipped bug: login frame ended at 259 with the dot at 254, a 5pt
        // OVERLAP, so the ✓ sat on top of the green dot.
        for title in [checkedTitle, plainTitle] {
            let layout = FooterLayout.layout(metrics: metrics(login: title))
            #expect(layout.login.end < layout.dotX)
        }
    }

    @Test("the login→dot gap is EXACTLY the configured gap, in both ✓ states")
    func gapIsTheStatedConstant() {
        // This is the test that fails against the old hardcoded-x layout: there
        // the gap changed by 14pt when the ✓ appeared (13pt of clearance became
        // -1pt). Hanging the link off the dot makes the gap invariant.
        let spacing = FooterLayout.Spacing()
        let checked = FooterLayout.layout(metrics: metrics(login: checkedTitle), spacing: spacing)
        let plain = FooterLayout.layout(metrics: metrics(login: plainTitle), spacing: spacing)
        #expect(checked.dotX - checked.login.end == spacing.loginToDotGap)
        #expect(plain.dotX - plain.login.end == spacing.loginToDotGap)
        // ...and therefore identical to each other, whichever title is up.
        #expect(checked.dotX - checked.login.end == plain.dotX - plain.login.end)
    }

    @Test("raising loginToDotGap ADDS space — it must never move the link closer")
    func biggerGapMovesTheLinkLeft() {
        // The second report: the previous fix nudged the login link RIGHT
        // (146→150) to "add a space", but the dot is right-anchored and fixed,
        // so the link moved TOWARD it and the gap shrank. Pin the direction:
        // a larger gap must place the link further left and open real space.
        let tight = FooterLayout.layout(metrics: metrics(login: checkedTitle),
                                        spacing: FooterLayout.Spacing(loginToDotGap: 8))
        let loose = FooterLayout.layout(metrics: metrics(login: checkedTitle),
                                        spacing: FooterLayout.Spacing(loginToDotGap: 16))
        #expect(loose.login.x < tight.login.x)
        #expect(loose.dotX - loose.login.end > tight.dotX - tight.login.end)
    }

    @Test("the left links never collide with each other or with the login link")
    func leftGroupHasClearSpace() {
        // Clearance is asserted on the INK, not the frames: each link frame
        // carries linkGutter/2 of dead padding a side, so touching frames can
        // still look correctly spaced. The row is genuinely tight in the ✓
        // state (~20pt of slack for three gaps at 320pt), so the honest
        // invariant is "the glyphs never crowd", not "the frames never touch".
        let spacing = FooterLayout.Spacing()
        let inkInset = spacing.linkGutter / 2
        for title in [checkedTitle, plainTitle] {
            let layout = FooterLayout.layout(metrics: metrics(login: title), spacing: spacing)
            #expect(layout.dashboard.end + spacing.linkSpacing <= layout.apiKey.x)
            // Ink gap between "API key" and the login title, worst case (✓ on).
            let inkGap = (layout.login.x + inkInset) - (layout.apiKey.end - inkInset)
            #expect(inkGap >= 6)
            // And the frames must never actually cross.
            #expect(layout.apiKey.end <= layout.login.x)
        }
    }

    @Test("every element stays inside the popover's side margins")
    func nothingEscapesTheMargins() {
        let spacing = FooterLayout.Spacing()
        for title in [checkedTitle, plainTitle] {
            let layout = FooterLayout.layout(metrics: metrics(login: title), spacing: spacing)
            #expect(layout.dashboard.x >= spacing.sidePadding)
            #expect(layout.statusX >= spacing.sidePadding)
            let statusWidth = layout.showsTimestamp ? 94.0 : 36.0
            #expect(layout.statusX + statusWidth <= spacing.totalWidth - spacing.sidePadding)
        }
    }

    @Test("the timestamp yields when it would squeeze the login link")
    func timestampYieldsWhenTight() {
        // At 320pt the long "AI Hub · 14:32:07" cannot coexist with the widest
        // login title, so the label falls back to the bare "AI Hub".
        let layout = FooterLayout.layout(metrics: metrics(login: checkedTitle))
        #expect(layout.showsTimestamp == false)
        // The fallback is what buys the clearance, so the row still holds.
        #expect(layout.apiKey.end <= layout.login.x)
        #expect(layout.login.end < layout.dotX)
    }

    @Test("the fit decision ignores which ✓ state is showing")
    func fitDecisionIsStateIndependent() {
        // Deciding on the CURRENT title would let the timestamp appear when the
        // ✓ is off and vanish when it's on — the row would twitch every time
        // the user toggled the setting. Both states must agree.
        let checked = FooterLayout.layout(metrics: metrics(login: checkedTitle))
        let plain = FooterLayout.layout(metrics: metrics(login: plainTitle))
        #expect(checked.showsTimestamp == plain.showsTimestamp)
        #expect(checked.dotX == plain.dotX)
    }

    @Test("a wider card lets the timestamp back in, and the row still holds")
    func timestampFitsOnAWiderCard() {
        // Not a shipped size, but it proves the fit rule is real arithmetic and
        // not a constant that happens to say "no": given room, the timestamp
        // shows AND every clearance invariant survives.
        let spacing = FooterLayout.Spacing(totalWidth: 420)
        let layout = FooterLayout.layout(metrics: metrics(login: checkedTitle), spacing: spacing)
        #expect(layout.showsTimestamp == true)
        #expect(layout.apiKey.end < layout.login.x)
        #expect(layout.login.end < layout.dotX)
        #expect(layout.dotX - layout.login.end == spacing.loginToDotGap)
    }

    @Test("the dot sits a fixed distance left of the status label")
    func dotTracksTheStatusLabel() {
        let spacing = FooterLayout.Spacing()
        let layout = FooterLayout.layout(metrics: metrics(login: plainTitle), spacing: spacing)
        #expect(layout.statusX - layout.dotX == spacing.dotToStatus)
    }

    @Test("a long model name yields to the factual value and the track minimum")
    func modelBudgetRowReservesTrackMinimum() {
        let spacing = FooterLayout.ModelBudgetRowSpacing(
            totalWidth: 284,
            nameToTrackGap: 8,
            trackToValueGap: 8,
            minimumTrackWidth: 48
        )
        let measuredNameWidth = 210.0
        let layout = FooterLayout.modelBudgetRow(
            metrics: FooterLayout.ModelBudgetRowMetrics(name: measuredNameWidth + 4, value: 90),
            spacing: spacing
        )

        // The value remains right-aligned and factual. The name receives the
        // remaining truncating region after the 48pt track is protected.
        #expect(layout.value.x == 194)
        #expect(layout.name.width == 130)
        #expect(layout.name.width < measuredNameWidth)
        #expect(layout.track.x == 138)
        #expect(layout.track.width == 48)
        #expect(layout.track.width >= spacing.minimumTrackWidth)
        #expect(layout.track.end + spacing.trackToValueGap == layout.value.x)
    }

    @Test("a short model name reserves four points beyond its measured width")
    func modelBudgetRowAddsLabelAllowance() {
        let spacing = FooterLayout.ModelBudgetRowSpacing(
            totalWidth: 284,
            nameToTrackGap: 8,
            trackToValueGap: 8,
            minimumTrackWidth: 48
        )
        let measuredNameWidth = 41.0 // "Opus 5" in the configured 12pt font.
        let labelAllowance = 4.0
        let layout = FooterLayout.modelBudgetRow(
            metrics: FooterLayout.ModelBudgetRowMetrics(
                name: measuredNameWidth + labelAllowance,
                value: 90
            ),
            spacing: spacing
        )

        #expect(layout.name.width == measuredNameWidth + labelAllowance)
        #expect(layout.track.width >= spacing.minimumTrackWidth)
        #expect(layout.value.x == 194)
    }

    @Test("a short model name leaves the track all remaining width")
    func modelBudgetRowExpandsTrackForShortName() {
        let spacing = FooterLayout.ModelBudgetRowSpacing(
            totalWidth: 284,
            nameToTrackGap: 8,
            trackToValueGap: 8,
            minimumTrackWidth: 48
        )
        let layout = FooterLayout.modelBudgetRow(
            metrics: FooterLayout.ModelBudgetRowMetrics(name: 52, value: 90),
            spacing: spacing
        )

        #expect(layout.name.width == 52)
        #expect(layout.track.width == 126)
        #expect(layout.value.x == 194)
        #expect(layout.track.end + spacing.trackToValueGap == layout.value.x)
    }
}
