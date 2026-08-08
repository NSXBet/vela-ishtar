// Sources/App/UpdateChecker.swift
// The app-side shell around ReleaseChecker (v0.5.2): owns WHEN checks happen
// and REMEMBERS their outcomes across launches. Why a separate class: the
// rules (throttle, bell decision) are pure and tested in VelaCore; this is
// the untestable-by-design layer that persists last-check / skipped-version /
// cached-release in UserDefaults and refetches in the background while the
// popover is closed, so the bell's state is already known the instant the
// popover opens — no network wait on the UI path.
// RELEVANT FILES: Sources/VelaCore/ReleaseChecker.swift, Sources/App/UpdateBellView.swift, Sources/App/main.swift

import Cocoa

@MainActor
public final class UpdateChecker {

    /// Fired when the known release state CHANGES (a fetch landed, or the
    /// user skipped a version). main.swift re-renders an open popover so the
    /// bell appears/disappears without waiting for the next poll.
    public var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let runningVersion: String

    private static let lastCheckKey = "updateCheck.lastCheck"
    private static let skippedKey = "updateCheck.skippedVersion"
    private static let cachedTagKey = "updateCheck.cachedTag"
    private static let cachedURLKey = "updateCheck.cachedURL"

    /// The release the bell should currently announce, or nil. Computed from
    /// the cached release + the skip list, so it survives relaunch and never
    /// waits on the network.
    public private(set) var pendingRelease: VersionCheck.Release?

    public init(defaults: UserDefaults = .standard, runningVersion: String) {
        self.defaults = defaults
        self.runningVersion = runningVersion
        if let tag = defaults.string(forKey: Self.cachedTagKey),
           let url = defaults.string(forKey: Self.cachedURLKey) {
            let release = VersionCheck.Release(tag: tag, url: url)
            let skipped = defaults.string(forKey: Self.skippedKey)
            if ReleaseChecker.shouldShowBell(latest: release, running: runningVersion, skipped: skipped) {
                self.pendingRelease = release
            }
        }
    }

    /// Fetch if the throttle allows. Safe to call as often as desired — at
    /// most one network request per `ReleaseChecker.throttleInterval` ever
    /// leaves the app.
    public func checkIfDue() {
        let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        guard ReleaseChecker.isCheckDue(lastCheck: lastCheck, now: Date()) else { return }
        defaults.set(Date(), forKey: Self.lastCheckKey)
        Task { [weak self] in
            guard let release = await ReleaseChecker.fetchLatestRelease() else { return }
            self?.ingest(release)
        }
    }

    /// Record the user's "Skip this version" choice and clear the bell.
    public func skipCurrent() {
        guard let pendingRelease else { return }
        defaults.set(pendingRelease.tag, forKey: Self.skippedKey)
        self.pendingRelease = nil
        onChange?()
    }

    private func ingest(_ release: VersionCheck.Release) {
        // Cache every fetched release — even a same/older one refreshes the
        // cache so a stale "newer" entry from a previous launch can't
        // outlive reality (e.g. the user upgraded by hand).
        defaults.set(release.tag, forKey: Self.cachedTagKey)
        defaults.set(release.url, forKey: Self.cachedURLKey)
        let skipped = defaults.string(forKey: Self.skippedKey)
        let shouldShow = ReleaseChecker.shouldShowBell(latest: release, running: runningVersion, skipped: skipped)
        let changed = (pendingRelease?.tag != release.tag) || (shouldShow != (pendingRelease != nil))
        pendingRelease = shouldShow ? release : nil
        if changed { onChange?() }
    }
}
