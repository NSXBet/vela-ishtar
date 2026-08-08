// Tests/VelaCoreTests/WhatsNewTests.swift
// Verifies the whatsNew parser that turns build.sh's CHANGELOG extraction
// (Contents/Resources/whatsnew.txt) into the version bullet's notes.
// Why: the file is generated at build time by an awk one-liner, so a malformed
// line (missing tab, empty note) must degrade gracefully — a bad parse must
// never crash the popover or show a garbage line, just fall back to fewer
// entries.
// RELEVANT FILES: Sources/VelaCore/WhatsNew.swift, build.sh

import Testing
import Foundation
@testable import VelaCore

struct WhatsNewTests {
    @Test("well-formed lines parse into version/note pairs")
    func wellFormedParses() {
        let text = "0.3.4\tcold-open fix\n0.3.3\tversion bullet tooltip\n0.3.2\tday strip reads as a week\n"
        let notes = WhatsNew.parse(text)
        #expect(notes.count == 3)
        #expect(notes[0].version == "0.3.4")
        #expect(notes[0].note == "cold-open fix")
        #expect(notes[2].version == "0.3.2")
        #expect(notes[2].note == "day strip reads as a week")
    }

    @Test("a line missing its tab is skipped, not crashed on")
    func missingTabIsSkipped() {
        let text = "0.3.4\tcold-open fix\nMALFORMED LINE WITHOUT TAB\n0.3.3\tversion bullet\n"
        let notes = WhatsNew.parse(text)
        #expect(notes.count == 2)
        #expect(notes[0].version == "0.3.4")
        #expect(notes[1].version == "0.3.3")
    }

    @Test("empty input yields an empty list, never a crash")
    func emptyInputYieldsEmpty() {
        #expect(WhatsNew.parse("").isEmpty)
        #expect(WhatsNew.parse("\n\n\n").isEmpty)
    }

    @Test("a note containing a tab keeps everything after the first tab")
    func noteKeepsInteriorTabs() {
        let text = "0.3.4\tfirst part\tsecond part\n"
        let notes = WhatsNew.parse(text)
        #expect(notes.count == 1)
        #expect(notes[0].note == "first part\tsecond part")
    }

    // visibleNotes (v0.5.1): the changelog card leads with what the running
    // version JUST got, then everything older. v0.5.0 dropped the running
    // version's own line (the "You're running vX" subtitle seemed to make it
    // redundant), but that reads as "I can't see what changed in the latest
    // version" — the single most important line on the card.

    @Test("the running version's own line leads the list")
    func runningVersionLeads() {
        let notes: [(version: String, note: String)] = [
            ("0.4.3", "fixed-height card"),
            ("0.4.2", "bitmap morph"),
        ]
        let visible = WhatsNew.visibleNotes(running: "0.4.3", notes: notes)
        #expect(visible.count == 2)
        #expect(visible[0].version == "0.4.3")
        #expect(visible[1].version == "0.4.2")
    }

    @Test("a mid-list running version is pulled to the front, order otherwise kept")
    func midListRunningVersionPullsForward() {
        let notes: [(version: String, note: String)] = [
            ("0.4.3", "fixed-height card"),
            ("0.4.2", "bitmap morph"),
            ("0.4.1", "single transition"),
        ]
        let visible = WhatsNew.visibleNotes(running: "0.4.2", notes: notes)
        #expect(visible.map(\.version) == ["0.4.2", "0.4.3", "0.4.1"])
    }

    @Test("a running version that isn't in the list leaves it untouched")
    func unknownRunningVersionLeavesList() {
        let notes: [(version: String, note: String)] = [
            ("0.4.3", "fixed-height card"),
            ("0.4.2", "bitmap morph"),
        ]
        let visible = WhatsNew.visibleNotes(running: "9.9.9", notes: notes)
        #expect(visible.map(\.version) == ["0.4.3", "0.4.2"])
    }

    @Test("a single-entry list survives intact")
    func singleEntryListSurvives() {
        let notes: [(version: String, note: String)] = [("0.4.3", "fixed-height card")]
        let visible = WhatsNew.visibleNotes(running: "0.4.3", notes: notes)
        #expect(visible.count == 1)
        #expect(visible[0].version == "0.4.3")
    }

    @Test("five entries with a mid-list running version: running leads, the other four keep their exact relative order")
    func fiveEntriesStableOrder() {
        // This pins the CONTRACT (running version first, the rest in their
        // original relative order), not the regression: the old comparator
        // `sorted { lhs, _ in lhs.version == running }` violated strict weak
        // ordering, but no realistic fixture reliably fails under it on this
        // runtime — the stdlib's sort happens to tolerate it at these sizes.
        // That unspecified behavior is exactly WHY the fix is a structural
        // partition instead of a patched comparator: there was no red test
        // to be had, so the guarantee now comes from construction, and this
        // test keeps the contract executable.
        let notes: [(version: String, note: String)] = [
            ("0.4.5", "a"),
            ("0.4.4", "b"),
            ("0.4.3", "c"),
            ("0.4.2", "d"),
            ("0.4.1", "e"),
        ]
        let visible = WhatsNew.visibleNotes(running: "0.4.3", notes: notes)
        #expect(visible.map(\.version) == ["0.4.3", "0.4.5", "0.4.4", "0.4.2", "0.4.1"])
    }
}
