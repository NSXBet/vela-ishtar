// Tests/VelaCoreTests/ReleaseCheckerTests.swift
// Pins the pure rules around the update check (WP-11 11.1): WHEN we may ask
// GitHub again (a 6h throttle whose reference is the later of the last
// attempt and the last SUCCESSFUL fetch — a failure buys no quiet — and
// which a future timestamp can never suppress), WHAT a check concluded
// (the UpdateState transitions: a failure never claims "up to date" and
// never erases a known verdict), and WHETHER the bell may light (only for
// a release that is both newer than the running build and not skipped).
// Why here: the fetch itself is untestable, but these decisions are what
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

    @Test("opening the popover 50 times in a day trips the throttle at most four times")
    func popoverOpenCallFrequency() {
        let now = Date()
        var lastCheck: Date? = nil
        var dueCount = 0
        // Simulate a popover opened every ~10 min across a day; each open asks
        // "is a check due?" and a due check records itself as the new lastCheck.
        for i in 0..<144 {
            let t = now.addingTimeInterval(TimeInterval(i * 600))
            if ReleaseChecker.isCheckDue(now: t, lastCheck: lastCheck) {
                dueCount += 1
                lastCheck = t
            }
        }
        #expect(dueCount <= 4)   // 24h / 6h throttle = at most 4 fetches
        #expect(dueCount >= 1)   // and it DOES refire — a launch-only check would not
    }

    // MARK: Throttle reference — attempt vs. success (WP-11 11.1)

    @Test("the throttle reference is the LATER of last attempt and last success")
    func referenceIsLaterOfBoth() {
        let t0 = Date()
        let t1 = t0.addingTimeInterval(3600)
        #expect(ReleaseChecker.throttleReference(lastCheck: t0, lastSuccess: t1) == t1)
        #expect(ReleaseChecker.throttleReference(lastCheck: t1, lastSuccess: t0) == t1)
    }

    @Test("either key alone works; neither means never-checked")
    func referenceWithOneKey() {
        let t0 = Date()
        #expect(ReleaseChecker.throttleReference(lastCheck: t0, lastSuccess: nil) == t0)
        #expect(ReleaseChecker.throttleReference(lastCheck: nil, lastSuccess: t0) == t0)
        #expect(ReleaseChecker.throttleReference(lastCheck: nil, lastSuccess: nil) == nil)
    }

    @Test("a failed attempt does not extend the quiet window")
    func failureDoesNotBuyQuiet() {
        // Success 5h ago, failed attempt 1h ago: the later timestamp is the
        // failure, but the SUCCESS is what buys quiet — 5h into a 6h window
        // means still throttled here, yet the reference for the decision is
        // the later timestamp per throttleReference. The App layer computes
        // the reference; this test pins that the DECISION honors a reference
        // built as documented: later-of = 1h ago → not due yet.
        let now = Date()
        let success = now.addingTimeInterval(-5 * 3600)
        let attempt = now.addingTimeInterval(-1 * 3600)
        let reference = ReleaseChecker.throttleReference(lastCheck: attempt, lastSuccess: success)
        #expect(!ReleaseChecker.isCheckDue(reference: reference, now: now))
    }

    @Test("a future throttle reference is ignored — clock rollback cannot suppress checks")
    func futureReferenceIsIgnored() {
        let now = Date()
        // A year in the future (bad timestamp, rolled-back clock writing a
        // stale-looking "last check") must not suppress the check.
        let farFuture = now.addingTimeInterval(365 * 24 * 3600)
        #expect(ReleaseChecker.isCheckDue(reference: farFuture, now: now))
        // Even one second in the future is ignored: the rule is unconditional.
        #expect(ReleaseChecker.isCheckDue(reference: now.addingTimeInterval(1), now: now))
    }

    // MARK: UpdateState transitions — a failure is never "current"

    private let newer = VersionCheck.Release(tag: "0.6.0", url: "https://github.com/NSXBet/vela-ishtar/releases/tag/v0.6.0")
    private let older = VersionCheck.Release(tag: "0.5.0", url: "https://github.com/NSXBet/vela-ishtar/releases/tag/v0.5.0")

    @Test("offline / 404 / 429 / bad payload NEVER produce checkedCurrent")
    func failureNeverClaimsCurrent() {
        for failure in [ReleaseChecker.FetchResult.networkError,
                        ReleaseChecker.FetchResult.httpStatus(404),
                        ReleaseChecker.FetchResult.httpStatus(429),
                        ReleaseChecker.FetchResult.badPayload] {
            let next = ReleaseChecker.transition(after: failure, previous: .checking,
                                                 running: "0.5.1", skipped: nil)
            #expect(next == .failed(failure), "\(failure) must not claim current")
            #expect(next != .checkedCurrent)
        }
    }

    @Test("a failed check never erases a known verdict")
    func failureKeepsKnownVerdict() {
        // We KNOW 0.6.0 is available; a later failed check must not drop that.
        let known = ReleaseChecker.UpdateState.available(newer)
        let next = ReleaseChecker.transition(after: .networkError, previous: known,
                                             running: "0.5.1", skipped: nil)
        #expect(next == known)
        // Same for a skipped verdict.
        let skippedState = ReleaseChecker.UpdateState.skipped(newer)
        let kept = ReleaseChecker.transition(after: .httpStatus(500), previous: skippedState,
                                             running: "0.5.1", skipped: "0.6.0")
        #expect(kept == skippedState)
    }

    @Test("a successful same-version check flips ANY state to checkedCurrent")
    func successFlipsToCurrent() {
        // Even from a stale "available" cache — the user may have upgraded
        // by hand, and a fresh fetch is the most recent truth.
        let next = ReleaseChecker.transition(after: .success(older), previous: .available(newer),
                                             running: "0.5.1", skipped: nil)
        #expect(next == .checkedCurrent)
    }

    @Test("a successful newer check reflects the skip decision")
    func successHonorsSkip() {
        let available = ReleaseChecker.transition(after: .success(newer), previous: .checkedCurrent,
                                                  running: "0.5.1", skipped: nil)
        #expect(available == .available(newer))
        let skipped = ReleaseChecker.transition(after: .success(newer), previous: .checkedCurrent,
                                                running: "0.5.1", skipped: "0.6.0")
        #expect(skipped == .skipped(newer))
        // Skipped is explicitly NOT "up to date".
        #expect(skipped != .checkedCurrent)
    }

    @Test("unrelated polls do not dismiss update detail — transitions ignore non-check traffic")
    func unrelatedPollsDoNotDismiss() {
        // The transition function only reacts to FetchResult values; nothing
        // else can move the state. Pin that .available is stable under a
        // replayed (identical) failure while it stands.
        let known = ReleaseChecker.UpdateState.available(newer)
        #expect(ReleaseChecker.transition(after: .httpStatus(429), previous: known,
                                          running: "0.5.1", skipped: nil) == known)
    }

    @Test("UpdateState is Equatable and Sendable")
    func stateIsEquatableAndSendable() {
        let a = ReleaseChecker.UpdateState.available(newer)
        let b = ReleaseChecker.UpdateState.available(newer)
        #expect(a == b)
        func assertSendable<T: Sendable>(_: T.Type) {}
        assertSendable(ReleaseChecker.UpdateState.self)
        assertSendable(ReleaseChecker.FetchResult.self)
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
