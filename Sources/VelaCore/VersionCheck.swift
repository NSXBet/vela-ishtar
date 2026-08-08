// Sources/VelaCore/VersionCheck.swift
// The rules behind the update bell (v0.5.2): is the latest GitHub release
// NEWER than the version running, and should the bell light up. Why this lives
// in VelaCore: comparing versions and deciding "show the bell" are pure rules
// that must never cry wolf — lighting the bell when you're already current is
// the one unforgivable state — so they're specified and tested here, separate
// from the bell view that renders them. Fail closed everywhere: a malformed
// tag, a draft, a prerelease, or a garbage payload all mean "no bell", never
// a false alarm.
// RELEVANT FILES: Tests/VelaCoreTests/VersionCheckTests.swift, Sources/App/UpdateBellView.swift

import Foundation

public enum VersionCheck {

    /// One GitHub release: the bare tag (no leading "v") and its web URL.
    public struct Release: Equatable {
        public let tag: String
        public let url: String
    }

    /// Is `candidate` a strictly newer version than `current`? Both may carry
    /// a leading "v" and a two-part form reads as `.0` (0.5 == 0.5.0). A
    /// prerelease suffix ("-beta.1") is ignored at the component level — we
    /// only ship finals. Anything unparseable is NOT newer: fail closed.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let c = components(candidate), let r = components(current) else { return false }
        for i in 0..<3 where c[i] != r[i] { return c[i] > r[i] }
        return false
    }

    /// Parse the `/releases/latest` JSON into a Release, or nil for anything
    /// that isn't a finished, installable build: drafts, prereleases, missing
    /// fields, or malformed JSON. The leading "v" is stripped from the tag.
    public static func parseRelease(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let url = obj["html_url"] as? String,
              (obj["draft"] as? Bool) == false,
              (obj["prerelease"] as? Bool) == false
        else { return nil }
        return Release(tag: stripV(tag), url: url)
    }

    // Three numeric components, or nil if any part isn't a clean integer.
    // A prerelease suffix is dropped before splitting so "0.5.2-beta.1" reads
    // as 0.5.2. Missing trailing parts pad to 0 (two-part "0.5" -> 0.5.0).
    private static func components(_ version: String) -> [Int]? {
        let core = stripV(version).split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var out: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            out.append(n)
        }
        while out.count < 3 { out.append(0) }
        return out
    }

    private static func stripV(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
    }
}
