// Sources/VelaCore/WhatsNew.swift
// Parses the version bullet's what's-new list from a build-generated file
// (Contents/Resources/whatsnew.txt) instead of a hand-maintained array.
// Why: the hand-kept list in PopoverView drifted from the shipped binary more
// than once; build.sh now awk-extracts the top CHANGELOG sections at build
// time, so the bullet can never drift ahead of (or behind) the release.
// The format is one `version<TAB>one-liner` per line. Parsing is defensive —
// a malformed line is skipped, empty input yields an empty list, and a missing
// file falls back to whatever the caller supplies. The popover must never
// crash or render garbage because a build artifact was hand-edited. WP-11
// (B17): the extracted one-liner is sanitized — a Markdown bullet from the
// changelog never ships to the UI with its markup showing.
// RELEVANT FILES: Sources/App/PopoverView.swift, build.sh, Tests/VelaCoreTests/WhatsNewTests.swift

import Foundation

public enum WhatsNew {
    /// Parses `version<TAB>note` lines into ordered (version, note) pairs.
    /// Lines without a tab, with an empty version, or with an empty note are
    /// skipped. Interior tabs are preserved (split on the FIRST tab only).
    /// The note is run through `cleanSummary` (WP-11 / B17): the build-time
    /// extractor grabs whatever line follows a `## [x.y.z]` header, which is
    /// sometimes a Markdown bullet ("- **Something.** …") rather than a
    /// clean sentence — the bullet never ships to the UI as markup.
    public static func parse(_ text: String) -> [(version: String, note: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let tabIndex = line.firstIndex(of: "\t") else { return nil }
            let version = line[..<tabIndex].trimmingCharacters(in: .whitespaces)
            let note = cleanSummary(String(line[line.index(after: tabIndex)...]))
            guard !version.isEmpty, !note.isEmpty else { return nil }
            return (version: version, note: note)
        }
    }

    /// Strips Markdown dressing from a one-line summary so the bullet shows
    /// clean human text: leading "- " / "* " bullet markers, "**bold**" and
    /// "*italic*" emphasis, and surrounding backticks are unwrapped. A line
    /// that becomes empty (e.g. it was ONLY a heading fragment) parses as
    /// absent, so the fallback path kicks in downstream.
    public static func cleanSummary(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // Leading bullet markers ("- ", "* ", "– ").
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("– ") {
            s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        // Emphasis and inline code: drop the markers, keep the words.
        s = s
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        // Single asterisks used as italics: only strip when they pair up,
        // so an arithmetic "3 * 4" never loses its asterisk mid-sentence.
        while let start = s.firstIndex(of: "*"),
              let end = s[s.index(after: start)...].firstIndex(of: "*") {
            s.remove(at: end)
            s.remove(at: start)
        }
        return s.trimmingCharacters(in: .whitespaces)
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

    /// The notes to actually show for a running version (v0.5.0), always
    /// newest-first. If the running version IS in the list its note leads
    /// ("here's what you just got"), followed by everything older. If it
    /// isn't (a dev build mid-cycle, or a fallback list cut from a different
    /// CHANGELOG head), show the whole list anyway — anything is better than
    /// a changelog card that looks like nothing ever shipped.
    public static func visibleNotes(running: String, notes: [(version: String, note: String)]) -> [(version: String, note: String)] {
        // A STABLE PARTITION, not a comparator: `sorted { lhs, _ in ... }` is
        // not a strict weak ordering (the running version compares "before"
        // everything, including itself), so the relative order of the other
        // entries was whatever the stdlib's sort happened to produce — right
        // today, unspecified forever. Two filters give the contract directly:
        // the running version first, everyone else in their original order.
        notes.filter { $0.version == running } + notes.filter { $0.version != running }
    }
}
