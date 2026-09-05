// Tests/VelaCoreTests/VersionCheckTests.swift
// Pins the update-bell logic (WP-11): the bell only appears when GitHub has
// a NEWER release than the one running, and never because a tag is malformed
// or a draft/prerelease leaked in — and the release's html_url must point at
// the intended destination (this project's GitHub releases over HTTPS) or
// the payload is rejected outright, since that URL opens in the user's
// browser. Why here: comparing versions and deciding "should the bell show"
// are pure rules — the bell view renders, but the decision to show it must
// be testable so it never cries wolf.
// RELEVANT FILES: Sources/VelaCore/VersionCheck.swift, Sources/App/UpdateBellView.swift

import Testing
import Foundation
@testable import VelaCore

@Suite("VersionCheck")
struct VersionCheckTests {

    // MARK: isNewer — the semver compare

    @Test("a higher patch/minor/major is newer")
    func higherIsNewer() {
        #expect(VersionCheck.isNewer("0.5.2", than: "0.5.1"))
        #expect(VersionCheck.isNewer("0.6.0", than: "0.5.9"))
        #expect(VersionCheck.isNewer("1.0.0", than: "0.9.9"))
    }

    @Test("the same version is NOT newer — the bell must never cry wolf")
    func sameIsNotNewer() {
        #expect(!VersionCheck.isNewer("0.5.1", than: "0.5.1"))
    }

    @Test("an older version is NOT newer — a stale tag must not light the bell")
    func olderIsNotNewer() {
        #expect(!VersionCheck.isNewer("0.5.0", than: "0.5.1"))
        #expect(!VersionCheck.isNewer("0.4.9", than: "0.5.0"))
    }

    @Test("leading 'v' is stripped on both sides")
    func stripsLeadingV() {
        #expect(VersionCheck.isNewer("v0.5.2", than: "0.5.1"))
        #expect(VersionCheck.isNewer("0.5.2", than: "v0.5.1"))
        #expect(!VersionCheck.isNewer("v0.5.1", than: "v0.5.1"))
    }

    @Test("two-part versions read as .0 — 0.5 == 0.5.0")
    func twoPartReadsAsZero() {
        #expect(!VersionCheck.isNewer("0.5", than: "0.5.0"))
        #expect(VersionCheck.isNewer("0.5.1", than: "0.5"))
    }

    @Test("a malformed candidate is never newer — fail closed, not loud")
    func malformedFailsClosed() {
        #expect(!VersionCheck.isNewer("not-a-version", than: "0.5.1"))
        #expect(!VersionCheck.isNewer("", than: "0.5.1"))
        #expect(!VersionCheck.isNewer("0.5.x", than: "0.5.1"))
    }

    @Test("prerelease suffixes are ignored at the component level")
    func prereleaseSuffixIgnored() {
        // 0.5.2-beta.1 is still 0.5.2 for our purposes; we only ship finals.
        #expect(VersionCheck.isNewer("0.5.2-beta.1", than: "0.5.1"))
        #expect(!VersionCheck.isNewer("0.5.1-rc.1", than: "0.5.1"))
    }

    // MARK: GitHubRelease — parsing the /releases/latest payload

    @Test("parses a well-formed latest-release payload")
    func parsesWellFormed() {
        let json = """
        { "tag_name": "v0.5.2", "name": "Vela Ishtar v0.5.2",
          "html_url": "https://github.com/NSXBet/vela-ishtar/releases/tag/v0.5.2",
          "draft": false, "prerelease": false }
        """.data(using: .utf8)!
        let release = VersionCheck.parseRelease(json)
        #expect(release?.tag == "0.5.2")
        #expect(release?.url == "https://github.com/NSXBet/vela-ishtar/releases/tag/v0.5.2")
    }

    @Test("a draft or prerelease parses to nil — never offer an unfinished build")
    func draftAndPrereleaseAreNil() {
        let draft = """
        { "tag_name": "v0.5.2", "html_url": "https://x", "draft": true, "prerelease": false }
        """.data(using: .utf8)!
        let pre = """
        { "tag_name": "v0.5.2", "html_url": "https://x", "draft": false, "prerelease": true }
        """.data(using: .utf8)!
        #expect(VersionCheck.parseRelease(draft) == nil)
        #expect(VersionCheck.parseRelease(pre) == nil)
    }

    @Test("garbage input parses to nil, never a crash")
    func garbageIsNil() {
        #expect(VersionCheck.parseRelease(Data("not json".utf8)) == nil)
        #expect(VersionCheck.parseRelease(Data()) == nil)
        // Valid JSON but missing the tag:
        #expect(VersionCheck.parseRelease(Data(#"{"name":"x"}"#.utf8)) == nil)
    }

    // MARK: Trusted release URL (WP-11 11.3)

    @Test("the intended GitHub release URL is trusted")
    func intendedURLIsTrusted() {
        #expect(VersionCheck.isTrustedReleaseURL("https://github.com/NSXBet/vela-ishtar/releases/tag/v1.0.4"))
        #expect(VersionCheck.isTrustedReleaseURL("https://github.com/NSXBet/vela-ishtar/releases/latest"))
        #expect(VersionCheck.isTrustedReleaseURL("https://GitHub.com/NSXBet/vela-ishtar/releases/tag/v1.0.4"))
    }

    @Test("any other destination is untrusted — fail closed")
    func foreignURLsUntrusted() {
        #expect(!VersionCheck.isTrustedReleaseURL("https://evil.example.com/vela-ishtar/releases"))
        #expect(!VersionCheck.isTrustedReleaseURL("http://github.com/NSXBet/vela-ishtar/releases")) // not HTTPS
        #expect(!VersionCheck.isTrustedReleaseURL("https://github.com/Other/vela-ishtar/releases/tag/v1"))
        #expect(!VersionCheck.isTrustedReleaseURL("https://github.com/NSXBet/other-repo/releases/tag/v1"))
        #expect(!VersionCheck.isTrustedReleaseURL("https://github.com/NSXBet/vela-ishtar/releases.evil.com/x"))
        #expect(!VersionCheck.isTrustedReleaseURL(""))
        #expect(!VersionCheck.isTrustedReleaseURL("not a url"))
    }

    @Test("a payload whose html_url points outside the intended destination parses to nil")
    func foreignReleaseURLIsRejected() {
        let json = """
        { "tag_name": "v9.9.9", "html_url": "https://evil.example.com/grab", "draft": false, "prerelease": false }
        """.data(using: .utf8)!
        #expect(VersionCheck.parseRelease(json) == nil)
    }
}
