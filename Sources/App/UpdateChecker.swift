// Sources/App/UpdateChecker.swift
// The app-side shell around ReleaseChecker (WP-11 11.1): owns WHEN checks
// happen and REMEMBERS their outcomes across launches as an EXPLICIT state —
// never-checked / checking / checked-current / available / skipped / failed —
// instead of the old implicit rule "pendingRelease == nil means up to date",
// which lied in five different ways (never checked, check failed, skipped,
// in-flight, and genuinely current all looked identical).
// Why a separate class: the rules (throttle, state transitions, bell
// decision) are pure and tested in VelaCore; this is the persistence layer
// that keeps last-attempt / last-success / skipped-version / cached-release
// in UserDefaults and refetches in the background while the popover is
// closed, so the bell's state is already known the instant the popover opens
// — no network wait on the UI path.
// Throttle vs. success: the attempt time and the last SUCCESSFUL fetch are
// stored under separate keys. A success buys the next 6h of quiet; a failed
// attempt does not. The throttle reference is the LATER of the two, and a
// reference in the future is ignored (ReleaseChecker.isCheckDue) so a clock
// rollback cannot suppress checks indefinitely.
// RELEVANT FILES: Sources/VelaCore/ReleaseChecker.swift, Sources/App/UpdateBellView.swift, Sources/App/main.swift

import Cocoa

@MainActor
public final class UpdateChecker {

    /// Fired when the known update state CHANGES (a fetch landed, a check
    /// failed, or the user skipped a version). main.swift re-renders an open
    /// popover so the bell reflects the new state without waiting for the
    /// next poll.
    public var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let runningVersion: String

    // The attempt time (throttle) and the last success (metadata) are
    // SEPARATE keys, per 11.1: a failure must never be mistaken for a
    // successful check, and only a success refreshes the cached release.
    private static let lastCheckKey = "updateCheck.lastCheck"
    private static let lastSuccessKey = "updateCheck.lastSuccess"
    private static let skippedKey = "updateCheck.skippedVersion"
    private static let cachedTagKey = "updateCheck.cachedTag"
    private static let cachedURLKey = "updateCheck.cachedURL"

    /// The current explicit update state. Always meaningful — including
    /// before the first check completes.
    public private(set) var state: ReleaseChecker.UpdateState = .neverChecked

    /// Convenience: the release the bell should announce, or nil. Derived
    /// from the state so it can never disagree with it.
    public var pendingRelease: VersionCheck.Release? {
        switch state {
        case .available(let release): return release
        default: return nil
        }
    }

    public init(defaults: UserDefaults = .standard, runningVersion: String) {
        self.defaults = defaults
        self.runningVersion = runningVersion
        // Rehydrate: a successful fetch from a previous launch is still the
        // best knowledge we have. A skipped release is announced as SKIPPED
        // (visible, honest) rather than silently dark.
        if let tag = defaults.string(forKey: Self.cachedTagKey),
           let url = defaults.string(forKey: Self.cachedURLKey) {
            let release = VersionCheck.Release(tag: tag, url: url)
            let skipped = defaults.string(forKey: Self.skippedKey)
            if VersionCheck.isNewer(release.tag, than: runningVersion) {
                state = (release.tag == skipped) ? .skipped(release) : .available(release)
            } else {
                state = .checkedCurrent
            }
        }
    }

    /// Fetch if the throttle allows. Safe to call as often as desired — at
    /// most one network request per `ReleaseChecker.throttleInterval` ever
    /// leaves the app (measured from the later of last attempt and last
    /// success, and immune to clock rollback — see isCheckDue).
    public func checkIfDue() {
        let reference = ReleaseChecker.throttleReference(
            lastCheck: defaults.object(forKey: Self.lastCheckKey) as? Date,
            lastSuccess: defaults.object(forKey: Self.lastSuccessKey) as? Date)
        guard ReleaseChecker.isCheckDue(reference: reference, now: Date()) else { return }
        // Record the ATTEMPT separately from any success; a failure costs
        // nothing (the next popover open retries immediately), but an
        // attempt still bounds the request rate when checks keep failing
        // fast (e.g. offline with an immediate error).
        defaults.set(Date(), forKey: Self.lastCheckKey)
        if case .checking = state {} else {
            // Don't clobber a known verdict while we re-check in the
            // background — the old truth stays on the bell until replaced.
            state = state == .neverChecked ? .checking : state
        }
        onChange?()
        Task { [weak self] in
            let result = await ReleaseChecker.fetchLatestReleaseDetailed()
            self?.ingest(result)
        }
    }

    /// Record the user's "Skip this version" choice. The state becomes
    /// `skipped` — explicitly NOT "up to date": the card keeps saying a
    /// newer release exists, just without the rocking bell.
    public func skipCurrent() {
        guard let release = pendingRelease else { return }
        defaults.set(release.tag, forKey: Self.skippedKey)
        state = .skipped(release)
        onChange?()
    }

    private func ingest(_ result: ReleaseChecker.FetchResult) {
        if case .success(let release) = result {
            // Cache every successful fetch — even a same/older one refreshes
            // the cache so a stale "newer" entry can't outlive reality (the
            // user may have upgraded by hand). The SUCCESS time, not the
            // attempt time, buys the throttle window.
            defaults.set(release.tag, forKey: Self.cachedTagKey)
            defaults.set(release.url, forKey: Self.cachedURLKey)
            defaults.set(Date(), forKey: Self.lastSuccessKey)
        }
        let skipped = defaults.string(forKey: Self.skippedKey)
        let newState = ReleaseChecker.transition(after: result, previous: state,
                                                 running: runningVersion, skipped: skipped)
        let changed = (newState != state)
        state = newState
        if changed { onChange?() }
    }
}
