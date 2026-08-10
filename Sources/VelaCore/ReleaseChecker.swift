// Sources/VelaCore/ReleaseChecker.swift
// Asks GitHub whether a newer Vela Ishtar release exists, and owns the two
// rules that keep the update bell honest: WHEN we may ask again (a 6h
// throttle, so a popover opened fifty times a day still costs at most four
// API calls) and WHETHER the bell may light (only for a release that is both
// newer than the running build and not one the user already skipped). Why
// this lives in VelaCore: the rules are pure and tested here; the fetch is a
// thin async wrapper the App side drives. Everything fails closed — offline,
// a rate limit, or a weird payload all mean "no bell", never a false alarm.
// RELEVANT FILES: Tests/VelaCoreTests/ReleaseCheckerTests.swift, Sources/VelaCore/VersionCheck.swift, Sources/App/UpdateBellView.swift

import Foundation

public enum ReleaseChecker {

    /// Minimum time between checks against the GitHub API.
    public static let throttleInterval: TimeInterval = 6 * 3600

    /// May we fetch again? Due when we've never checked, or the last check is
    /// at least `throttleInterval` old.
    public static func isCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= throttleInterval
    }

    /// May we fetch again right now? The `now: Date()` default is what the App
    /// side drives on every popover open — the throttle is the only guard, so
    /// calling it fifty times a day still costs at most four API calls.
    public static func isCheckDue(now: Date = Date(), lastCheck: Date?) -> Bool {
        isCheckDue(lastCheck: lastCheck, now: now)
    }

    /// May the bell light? Only for a release that is strictly newer than the
    /// running build AND is not the exact version the user chose to skip.
    /// Skipping is per-version: skipping 0.5.2 must not hide 0.5.3 later.
    public static func shouldShowBell(latest: VersionCheck.Release, running: String, skipped: String?) -> Bool {
        guard VersionCheck.isNewer(latest.tag, than: running) else { return false }
        return latest.tag != skipped
    }

    /// Fetch the latest finished release from GitHub. Returns nil on any
    /// failure — offline, non-200, rate-limited, or a payload that isn't a
    /// final release — so the caller's only job is "bell or no bell".
    public static func fetchLatestRelease() async -> VersionCheck.Release? {
        guard let url = URL(string: "https://api.github.com/repos/NSXBet/vela-ishtar/releases/latest")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        // GitHub asks API clients to identify themselves; anonymous requests
        // without a UA get the tightest rate limits.
        request.setValue("VelaIshtar-UpdateCheck", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return VersionCheck.parseRelease(data)
    }
}
