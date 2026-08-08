// Tests/VelaCoreTests/ReleaseCheckerTests.swift
// Pins the two pure rules around the update check (v0.5.2): WHEN we may ask
// GitHub again (a 6h throttle so the app never hammers the API on every
// popover open) and WHETHER the bell may light (only for a release that is
// both newer than the running build and not one the user already skipped).
// Why here: the fetch itself is untestable, but these two decisions are what
// keep the bell honest — a throttle bug spams GitHub, a decision bug cries
// wolf — so they live in VelaCore under test.
// RELEVANT FILES: Sources/VelaCore/ReleaseChecker.swift, Sources/VelaCore/VersionCheck.swift

import Testing
import Foundation
@testable import VelaCore

@Suite("ReleaseChecker")
struct ReleaseCheckerTests {

    // MARK: Throttle — when may we fetch again

    @Test("never checked before → fetch is due")
    func neverCheckedIsDue() {
        #expect(ReleaseChecker.isCheckDue(lastCheck: nil, now: Date()))
    }

    @Test("checked recently → not due yet")
    func recentCheckIsNotDue() {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        #expect(!ReleaseChecker.isCheckDue(lastCheck: oneHourAgo, now: now))
    }

    @Test("checked more than the throttle ago → due again")
    func staleCheckIsDue() {
        let now = Date()
        let sevenHoursAgo = now.addingTimeInterval(-7 * 3600)
        #expect(ReleaseChecker.isCheckDue(lastCheck: sevenHoursAgo, now: now))
    }

    @Test("exactly at the throttle boundary → due")
    func boundaryIsDue() {
        let now = Date()
        let exactlyThrottle = now.addingTimeInterval(-ReleaseChecker.throttleInterval)
        #expect(ReleaseChecker.isCheckDue(lastCheck: exactlyThrottle, now: now))
    }

    // MARK: Bell decision — newer AND not skipped

    @Test("a newer, unskipped release lights the bell")
    func newerUnskippedLights() {
        let release = VersionCheck.Release(tag: "0.5.2", url: "https://x")
        #expect(ReleaseChecker.shouldShowBell(latest: release, running: "0.5.1", skipped: nil))
    }

    @Test("the running version itself never lights the bell")
    func sameVersionStaysDark() {
        let release = VersionCheck.Release(tag: "0.5.1", url: "https://x")
        #expect(!ReleaseChecker.shouldShowBell(latest: release, running: "0.5.1", skipped: nil))
    }

    @Test("an older release never lights the bell")
    func olderStaysDark() {
        let release = VersionCheck.Release(tag: "0.5.0", url: "https://x")
        #expect(!ReleaseChecker.shouldShowBell(latest: release, running: "0.5.1", skipped: nil))
    }

    @Test("a skipped version stays dark even though it is newer")
    func skippedStaysDark() {
        let release = VersionCheck.Release(tag: "0.5.2", url: "https://x")
        #expect(!ReleaseChecker.shouldShowBell(latest: release, running: "0.5.1", skipped: "0.5.2"))
    }

    @Test("skipping one version does not hide the NEXT one")
    func skipIsPerVersion() {
        let release = VersionCheck.Release(tag: "0.5.3", url: "https://x")
        #expect(ReleaseChecker.shouldShowBell(latest: release, running: "0.5.1", skipped: "0.5.2"))
    }
}
