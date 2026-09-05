// Sources/VelaCore/ReleaseChecker.swift
// Asks GitHub whether a newer Vela Ishtar release exists, and owns the rules
// that keep the update bell honest: WHEN we may ask again (a 6h throttle on
// the last SUCCESSFUL check, so a popover opened fifty times a day still
// costs at most four API calls; a failed attempt doesn't buy quiet), WHETHER
// the bell may light (only for a release that is both newer than the running
// build and not one the user already skipped), and WHAT the check concluded
// (FetchResult: success / network error / HTTP refusal / bad payload, so the
// UI never reports "up to date" when the check itself failed). A throttle
// reference in the future is ignored, so a clock rollback cannot suppress
// checks indefinitely. Why this lives in VelaCore: the rules are pure and
// tested here; the fetch is a thin async wrapper the App side drives.
// Everything fails closed — a failure means "no bell", never a false alarm.
// RELEVANT FILES: Tests/VelaCoreTests/ReleaseCheckerTests.swift, Sources/VelaCore/VersionCheck.swift, Sources/App/UpdateBellView.swift

import Foundation

public enum ReleaseChecker {

    /// Minimum time between checks against the GitHub API.
    public static let throttleInterval: TimeInterval = 6 * 3600

    /// May we fetch again? Due when we've never checked, or the last check is
    /// at least `throttleInterval` old. Two hardening rules (WP-11 11.1):
    ///   - The comparison uses the LATER of `lastCheck` and `lastSuccess`
    ///     as the reference. A successful fetch is what buys the next 6h of
    ///     quiet — an attempt that failed costs nothing, so the next
    ///     popover open retries immediately instead of waiting a full
    ///     window after a failure.
    ///   - A reference date in the FUTURE (clock rolled back, or a bad
    ///     timestamp written by another build) is ignored: the check is due
    ///     anyway. A future `lastCheck` would otherwise suppress checks
    ///     indefinitely — for as long as "now" stays before it, potentially
    ///     forever after a DST-scale clock change.
    public static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        isCheckDue(reference: lastCheck, now: now)
    }

    /// May we fetch again right now? The `now: Date()` default is what the App
    /// side drives on every popover open — the throttle is the only guard, so
    /// calling it fifty times a day still costs at most four API calls.
    public static func isCheckDue(now: Date = Date(), lastCheck: Date?) -> Bool {
        isCheckDue(reference: lastCheck, now: now)
    }

    /// The throttle decision given the effective reference date. `reference`
    /// is the later of the last attempt and the last success (see above).
    /// A nil reference means "never checked" → due. A reference in the
    /// future relative to `now` means the clock moved backwards since it
    /// was written → due anyway.
    public static func isCheckDue(reference: Date?, now: Date) -> Bool {
        guard let reference else { return true }
        if reference > now { return true }
        return now.timeIntervalSince(reference) >= throttleInterval
    }

    /// The effective throttle reference: the LATER of the last attempt and
    /// the last successful fetch. A success pins the quiet window; a failed
    /// attempt after a success does not extend it.
    public static func throttleReference(lastCheck: Date?, lastSuccess: Date?) -> Date? {
        switch (lastCheck, lastSuccess) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// May the bell light? Only for a release that is strictly newer than the
    /// running build AND is not the exact version the user chose to skip.
    /// Skipping is per-version: skipping 0.5.2 must not hide 0.5.3 later.
    public static func shouldShowBell(latest: VersionCheck.Release, running: String, skipped: String?) -> Bool {
        guard VersionCheck.isNewer(latest.tag, than: running) else { return false }
        return latest.tag != skipped
    }

    /// The bell's EXPLICIT state (WP-11 11.1, feeding §7.2's truthful-update
    /// requirement): nil pendingRelease used to collapse five different
    /// realities into "up to date". Now every state is named, Equatable and
    /// Sendable, so the UI renders exactly the truth it was handed and tests
    /// can pin the transitions.
    public enum UpdateState: Equatable, Sendable {
        /// No check has ever completed — the bell can't know yet.
        case neverChecked
        /// A check is in flight right now.
        case checking
        /// The check completed and the running version is the latest. Only
        /// THIS state may say "up to date".
        case checkedCurrent
        /// A newer release is available and not skipped.
        case available(VersionCheck.Release)
        /// The user skipped the (newer) latest release — NOT "up to date".
        case skipped(VersionCheck.Release)
        /// The last attempt failed; the previous verdict (if any) still
        /// stands until a successful check replaces it.
        case failed(FetchResult)
    }

    /// The pure state machine. Given the state before a check attempt and
    /// what the attempt concluded, what is the state now? Rules:
    ///   - A failed attempt NEVER produces checkedCurrent — a failure does
    ///     not promote the running version to "the latest".
    ///   - A failed attempt never erases a known verdict either: if we
    ///     already know a release is available (or was skipped), that fact
    ///     survives the failure; only `checking` collapses to `failed`.
    ///   - A success overwrites everything: even a same/older tag flips the
    ///     state to checkedCurrent so a stale "newer" cache can't outlive
    ///     reality (the user may have upgraded by hand).
    public static func transition(after result: FetchResult,
                                  previous: UpdateState,
                                  running: String,
                                  skipped: String?) -> UpdateState {
        switch result {
        case .success(let release):
            if !VersionCheck.isNewer(release.tag, than: running) { return .checkedCurrent }
            if release.tag == skipped { return .skipped(release) }
            return .available(release)
        case .networkError, .httpStatus, .badPayload:
            if case .checking = previous { return .failed(result) }
            return previous
        }
    }

    /// The outcome of one update check, in enough detail for the UI to be
    /// truthful about it (WP-11 11.1): a failure is a failure, not "current",
    /// and a fetch that lands carries the release.
    public enum FetchResult: Equatable, Sendable {
        case success(VersionCheck.Release)
        /// Offline, timeout, DNS — no verdict about versions either way.
        case networkError
        /// A specific HTTP refusal (404, 429, 5xx…). Distinct from
        /// networkError so the state can say "the check was refused",
        /// which reads differently from "no route to the internet".
        case httpStatus(Int)
        /// A 200 that isn't a finished, trusted release (draft, prerelease,
        /// unparseable, or an html_url outside the intended destination).
        case badPayload
    }

    /// Fetch the latest finished release from GitHub. Never throws and never
    /// returns a "maybe": one of the explicit outcomes above, so the caller
    /// can distinguish "current" from "the check itself failed". No secret is
    /// attached — the metadata URL is public (verified unauthenticated,
    /// HTTP 200 on the configured endpoint), and a PAT or the gateway token
    /// must never ride on a release-metadata request.
    public static func fetchLatestReleaseDetailed() async -> FetchResult {
        guard let url = URL(string: "https://api.github.com/repos/NSXBet/vela-ishtar/releases/latest")
        else { return .badPayload }
        var request = URLRequest(url: url, timeoutInterval: 10)
        // GitHub asks API clients to identify themselves; anonymous requests
        // without a UA get the tightest rate limits.
        request.setValue("VelaIshtar-UpdateCheck", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .networkError
        }
        guard let http = response as? HTTPURLResponse else { return .networkError }
        guard http.statusCode == 200 else { return .httpStatus(http.statusCode) }
        return VersionCheck.parseRelease(data).map { .success($0) } ?? .badPayload
    }

    /// Convenience for callers that only care "bell or no bell" — the old
    /// contract, now a thin map over the detailed result.
    public static func fetchLatestRelease() async -> VersionCheck.Release? {
        if case .success(let release) = await fetchLatestReleaseDetailed() { return release }
        return nil
    }
}
