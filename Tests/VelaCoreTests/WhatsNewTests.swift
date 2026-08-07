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

    // visibleNotes (v0.5.0): the tip's subtitle now says "You're running vX",
    // so re-listing that same version as a note line would read as redundant.
    // The running version's own line is dropped — unless that would leave the
    // card empty, which is worse than a repeat.

    @Test("the running version's own line is dropped when others remain")
    func dropsRunningVersion() {
        let notes: [(version: String, note: String)] = [
            ("0.4.3", "fixed-height card"),
            ("0.4.2", "bitmap morph"),
        ]
        let visible = WhatsNew.visibleNotes(running: "0.4.3", notes: notes)
        #expect(visible.count == 1)
        #expect(visible[0].version == "0.4.2")
    }

    @Test("filtering that would empty the list keeps the full list")
    func keepsListWhenFilteringEmpties() {
        let notes: [(version: String, note: String)] = [("0.4.3", "fixed-height card")]
        let visible = WhatsNew.visibleNotes(running: "0.4.3", notes: notes)
        #expect(visible.count == 1)
        #expect(visible[0].version == "0.4.3")
    }

    @Test("a running version that isn't in the list leaves it untouched")
    func unknownRunningVersionLeavesList() {
        let notes: [(version: String, note: String)] = [
            ("0.4.3", "fixed-height card"),
            ("0.4.2", "bitmap morph"),
        ]
        let visible = WhatsNew.visibleNotes(running: "9.9.9", notes: notes)
        #expect(visible.count == 2)
    }
}
