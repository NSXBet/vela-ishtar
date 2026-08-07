// Sources/VelaCore/WhatsNew.swift
// Parses the version bullet's what's-new list from a build-generated file
// (Contents/Resources/whatsnew.txt) instead of a hand-maintained array.
// Why: the hand-kept list in PopoverView drifted from the shipped binary more
// than once; build.sh now awk-extracts the top CHANGELOG sections at build
// time, so the bullet can never drift ahead of (or behind) the release.
// The format is one `version<TAB>one-liner` per line. Parsing is defensive —
// a malformed line is skipped, empty input yields an empty list, and a missing
// file falls back to whatever the caller supplies. The popover must never
// crash or render garbage because a build artifact was hand-edited.
// RELEVANT FILES: Sources/App/PopoverView.swift, build.sh, Tests/VelaCoreTests/WhatsNewTests.swift

import Foundation

public enum WhatsNew {
    /// Parses `version<TAB>note` lines into ordered (version, note) pairs.
    /// Lines without a tab, with an empty version, or with an empty note are
    /// skipped. Interior tabs are preserved (split on the FIRST tab only).
    public static func parse(_ text: String) -> [(version: String, note: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let tabIndex = line.firstIndex(of: "\t") else { return nil }
            let version = line[..<tabIndex].trimmingCharacters(in: .whitespaces)
            let note = line[line.index(after: tabIndex)...].trimmingCharacters(in: .whitespaces)
            guard !version.isEmpty, !note.isEmpty else { return nil }
            return (version: version, note: note)
        }
    }

    /// Loads and parses the bundled whatsnew.txt, returning `fallback` when
    /// the resource is absent or parses to nothing (dev runs without the
    /// build artifact, or a corrupted file).
    public static func bundled(fallback: [(version: String, note: String)] = []) -> [(version: String, note: String)] {
        guard let url = Bundle.main.url(forResource: "whatsnew", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return fallback
        }
        let parsed = parse(text)
        return parsed.isEmpty ? fallback : parsed
    }

    /// The notes to actually show for a running version (v0.5.0). The tip now
    /// carries a "You're running vX.Y.Z" subtitle, so the running version's own
    /// note line would repeat it — it's dropped. Unless that filter would empty
    /// the list (a fresh install whose whatsnew.txt leads with only the current
    /// version): an empty changelog card is worse than a redundant line, so the
    /// full list is kept.
    public static func visibleNotes(running: String, notes: [(version: String, note: String)]) -> [(version: String, note: String)] {
        let filtered = notes.filter { $0.version != running }
        return filtered.isEmpty ? notes : filtered
    }
}
