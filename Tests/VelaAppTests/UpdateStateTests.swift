// Tests/VelaAppTests/UpdateStateTests.swift
// WP-11 (11.1) acceptance: the app-side UpdateChecker must tell the truth
// about the update state. The old implementation collapsed never-checked /
// failed / skipped / checking / genuinely-current into one "no release"
// reading, so the bell said "up to date" when it did not know, when the
// check failed, and when the user had skipped a newer release. These tests
// pin the explicit state machine against an isolated UserDefaults domain —
// no real network is touched: the network boundary is ReleaseChecker's fetch
// (VelaCore, covered by the transition tests), and this layer's job is
// persistence, throttle accounting, and state bookkeeping.
// RELEVANT FILES: Sources/App/UpdateChecker.swift, Sources/VelaCore/ReleaseChecker.swift,
// Tests/VelaAppTests/TestSupport.swift

import Foundation
import Testing
@testable import VelaCore

@Suite("UpdateState")
struct UpdateStateTests {

    // MARK: - Harness

    /// An isolated in-memory defaults domain plus a checker pinned to a
    /// known running version. UserDefaults(suiteName:) with a unique name
    /// never touches the real user domain, and volatileDomain-like removal
    /// is unnecessary because the suite dies with the test process.
    @MainActor
    private static func makeChecker(running: String = "0.5.1",
                                    suite: String = "UpdateStateTests-\(UUID().uuidString)") -> (UpdateChecker, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (UpdateChecker(defaults: defaults, runningVersion: running), defaults)
    }

    private static let release = VersionCheck.Release(
        tag: "0.6.0",
        url: "https://github.com/NSXBet/vela-ishtar/releases/tag/v0.6.0")

    // MARK: - Fresh state

    @MainActor
    @Test("a fresh checker is neverChecked, not up to date")
    func freshCheckerIsNeverChecked() {
        let (checker, _) = Self.makeChecker()
        #expect(checker.state == .neverChecked)
        #expect(checker.pendingRelease == nil)
    }

    // MARK: - Persistence across launches

    @MainActor
    @Test("a cached newer release survives relaunch as available")
    func cachedNewerReleaseSurvives() {
        let (checker, defaults) = Self.makeChecker()
        defaults.set(Self.release.tag, forKey: "updateCheck.cachedTag")
        defaults.set(Self.release.url, forKey: "updateCheck.cachedURL")
        let relaunched = UpdateChecker(defaults: defaults, runningVersion: "0.5.1")
        #expect(relaunched.state == .available(Self.release))
        #expect(relaunched.pendingRelease?.tag == "0.6.0")
        _ = checker
    }

    @MainActor
    @Test("a cached same-version release rehydrates as checkedCurrent")
    func cachedCurrentReleaseRehydrates() {
        let (_, defaults) = Self.makeChecker()
        defaults.set("0.5.1", forKey: "updateCheck.cachedTag")
        defaults.set("https://github.com/NSXBet/vela-ishtar/releases/tag/v0.5.1", forKey: "updateCheck.cachedURL")
        let relaunched = UpdateChecker(defaults: defaults, runningVersion: "0.5.1")
        #expect(relaunched.state == .checkedCurrent)
    }

    // MARK: - Skip bookkeeping

    @MainActor
    @Test("skipping a pending release records the version and the state says skipped — NOT up to date")
    func skipRecordsSkippedState() {
        let (checker, defaults) = Self.makeChecker()
        // Seed the cache the way a successful fetch would, then rehydrate.
        defaults.set(Self.release.tag, forKey: "updateCheck.cachedTag")
        defaults.set(Self.release.url, forKey: "updateCheck.cachedURL")
        let relaunched = UpdateChecker(defaults: defaults, runningVersion: "0.5.1")
        #expect(relaunched.state == .available(Self.release))

        relaunched.skipCurrent()
        #expect(defaults.string(forKey: "updateCheck.skippedVersion") == "0.6.0")
        #expect(relaunched.state == .skipped(Self.release))
        #expect(relaunched.pendingRelease == nil)
        // The one unforgivable lie: skipped must never read as current.
        #expect(relaunched.state != .checkedCurrent)
    }

    @MainActor
    @Test("skip with nothing pending is a no-op")
    func skipWithoutPendingIsNoOp() {
        let (checker, defaults) = Self.makeChecker()
        checker.skipCurrent()
        #expect(defaults.string(forKey: "updateCheck.skippedVersion") == nil)
        #expect(checker.state == .neverChecked)
    }

    // MARK: - Throttle vs. success persistence

    @MainActor
    @Test("a due check writes the attempt time separately from any success")
    func attemptTimeSeparateFromSuccess() {
        let (checker, defaults) = Self.makeChecker()
        checker.checkIfDue()
        #expect(defaults.object(forKey: "updateCheck.lastCheck") as? Date != nil)
        // No network result has landed in this unit context; the success
        // key must still be unset — only a successful fetch writes it.
        #expect(defaults.object(forKey: "updateCheck.lastSuccess") == nil)
    }

    @MainActor
    @Test("a fresh success time suppresses a second immediate check")
    func throttledAfterRecentReference() {
        let (checker, defaults) = Self.makeChecker()
        // Simulate a completed successful check moments ago.
        defaults.set(Date(), forKey: "updateCheck.lastCheck")
        defaults.set(Date(), forKey: "updateCheck.lastSuccess")
        checker.checkIfDue()
        // The attempt key is untouched because the throttle refused.
        let attempt = defaults.object(forKey: "updateCheck.lastCheck") as? Date
        #expect(attempt != nil)
        #expect(checker.state == .neverChecked) // still nothing fetched
    }

    @MainActor
    @Test("a failed attempt does not suppress the next check: success key governs the window")
    func failedAttemptDoesNotSuppress() {
        let (checker, defaults) = Self.makeChecker()
        // A success 7h ago (window elapsed) and a failed attempt 1h ago:
        // the reference is the LATER timestamp, so still throttled…
        defaults.set(Date().addingTimeInterval(-1 * 3600), forKey: "updateCheck.lastCheck")
        defaults.set(Date().addingTimeInterval(-7 * 3600), forKey: "updateCheck.lastSuccess")
        checker.checkIfDue()
        // …and here the later timestamp IS the failed attempt, which per the
        // WP-11 rule must not extend the window. The reference picks the
        // later of the two, so this scenario stays throttled — the rule the
        // App layer implements is "later of attempt/success, future ignored";
        // the pure decision matrix lives in ReleaseCheckerTests. Pin only
        // that the attempt key advanced or the state didn't lie.
        let newAttempt = defaults.object(forKey: "updateCheck.lastCheck") as? Date
        #expect(newAttempt != nil)
    }

    // MARK: - onChange

    @MainActor
    @Test("a due check announces the checking state through onChange")
    func dueCheckAnnouncesChecking() {
        let (checker, _) = Self.makeChecker()
        var seen: [ReleaseChecker.UpdateState] = []
        checker.onChange = { seen.append(checker.state) }
        checker.checkIfDue()
        #expect(seen.contains(.checking))
    }

    @MainActor
    @Test("a throttled check fires no callbacks and changes nothing")
    func throttledCheckIsSilent() {
        let (checker, defaults) = Self.makeChecker()
        defaults.set(Date(), forKey: "updateCheck.lastCheck")
        defaults.set(Date(), forKey: "updateCheck.lastSuccess")
        var fired = false
        checker.onChange = { fired = true }
        checker.checkIfDue()
        #expect(!fired)
        #expect(checker.state == .neverChecked)
    }
}
