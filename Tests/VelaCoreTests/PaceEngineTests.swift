// Tests/VelaCoreTests/PaceEngineTests.swift
// Verifies every PaceEngine.verdict() branch (in the documented rule order)
// and the exact PaceEngine.sentence() strings, including the UTC-midnight
// ETA clamp.
// Why: this is the copy the user sees in the menu bar every poll; a wrong
// branch or a mis-clamped ETA reads as a confident lie about their budget.
// RELEVANT FILES: Sources/VelaCore/PaceEngine.swift, Sources/VelaCore/Models.swift

import Testing
import Foundation
@testable import VelaCore

struct PaceEngineTests {
    // Independent of PaceEngine's own formatting code, so the test actually
    // checks behavior rather than mirroring the implementation.
    static func expectedLocalTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date).lowercased()
    }

    // MARK: - verdict() rule order

    @Test("limitEnabled false always wins, even if spend already exceeds limit")
    func cruisingNoLimitBeatsExhausted() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let verdict = PaceEngine.verdict(spent: 500, limit: 100, limitEnabled: false, now: now)
        #expect(verdict == .cruisingNoLimit)
    }

    @Test("spend at or above limit is exhausted, defaulting reachedAt to now when no exhaustedAt is passed")
    func exhaustedAtLimit() {
        let now = ISODate.parse("2026-08-01T18:40:00Z")!
        #expect(PaceEngine.verdict(spent: 100, limit: 100, limitEnabled: true, now: now) == .exhausted(reachedAt: now))
        #expect(PaceEngine.verdict(spent: 150, limit: 100, limitEnabled: true, now: now) == .exhausted(reachedAt: now))
    }

    @Test("exhausted uses the passed exhaustedAt instead of now, so the reported time is the true first crossing")
    func exhaustedUsesPassedExhaustedAt() {
        let firstCrossing = ISODate.parse("2026-08-01T09:15:00Z")!
        let now = ISODate.parse("2026-08-01T18:40:00Z")!
        let verdict = PaceEngine.verdict(spent: 150, limit: 100, limitEnabled: true, now: now, exhaustedAt: firstCrossing)
        #expect(verdict == .exhausted(reachedAt: firstCrossing))
    }

    @Test("zero or negative spend is idle")
    func idleWhenNoSpend() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        #expect(PaceEngine.verdict(spent: 0, limit: 100, limitEnabled: true, now: now) == .idle)
    }

    @Test("less than 60 seconds since midnight UTC with real spend is a generic pace, not a false idle")
    func paceGenericWhenTooEarlyInTheDayWithSpend() {
        let now = ISODate.parse("2026-08-01T00:00:30Z")!
        let verdict = PaceEngine.verdict(spent: 5, limit: 100, limitEnabled: true, now: now)
        let nextMidnightUTC = ISODate.parse("2026-08-02T00:00:00Z")!
        #expect(verdict == .pace(eta: nextMidnightUTC))
        // Since the eta is exactly next midnight (not before it), sentence()
        // must render the honest generic line, not a fabricated projection.
        #expect(PaceEngine.sentence(for: verdict, now: now) == "On pace to stay under budget today.")
    }

    @Test("pace is projected from the burn rate since midnight UTC")
    func paceProjectsETA() {
        // now = noon UTC -> 43200s elapsed since midnight UTC.
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        // rate = 100 / 43200s. remaining = 50. secondsToLimit = 50 / rate = 21600s (6h).
        let verdict = PaceEngine.verdict(spent: 100, limit: 150, limitEnabled: true, now: now)
        guard case .pace(let eta) = verdict else {
            Issue.record("expected .pace, got \(verdict)")
            return
        }
        let expectedETA = now.addingTimeInterval(21600)
        #expect(abs(eta.timeIntervalSince(expectedETA)) < 0.001)
    }

    @Test("pace still returns an eta even when it lands past midnight UTC")
    func paceETACanCrossMidnight() {
        // now = noon UTC; a very slow burn rate pushes the projected ETA
        // days into the future, well past the next UTC midnight.
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let verdict = PaceEngine.verdict(spent: 1, limit: 1000, limitEnabled: true, now: now)
        guard case .pace(let eta) = verdict else {
            Issue.record("expected .pace, got \(verdict)")
            return
        }
        let nextMidnightUTC = ISODate.parse("2026-08-02T00:00:00Z")!
        #expect(eta > nextMidnightUTC)
    }

    // MARK: - sentence() exact strings

    @Test("idle sentence")
    func idleSentence() {
        #expect(PaceEngine.sentence(for: .idle) == "No spend yet today.")
    }

    @Test("cruising with no limit sentence")
    func cruisingSentence() {
        #expect(PaceEngine.sentence(for: .cruisingNoLimit) == "No daily limit on your account.")
    }

    @Test("exhausted sentence includes the local reached-at time")
    func exhaustedSentence() {
        let reachedAt = ISODate.parse("2026-08-01T18:40:00Z")!
        let expected = "Budget reached at \(Self.expectedLocalTime(reachedAt)). Resets at midnight UTC."
        #expect(PaceEngine.sentence(for: .exhausted(reachedAt: reachedAt)) == expected)
    }

    @Test("pace sentence before next midnight UTC gives the projected time")
    func paceSentenceBeforeMidnight() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let eta = now.addingTimeInterval(21600) // 6h later, still same UTC day.
        let expected = "At this pace you'll reach budget around \(Self.expectedLocalTime(eta))."
        #expect(PaceEngine.sentence(for: .pace(eta: eta), now: now) == expected)
    }

    @Test("pace sentence clamps to a generic message once the eta crosses midnight UTC")
    func paceSentenceClampsAfterMidnight() {
        let now = ISODate.parse("2026-08-01T12:00:00Z")!
        let eta = ISODate.parse("2026-08-03T00:00:00Z")! // days past next midnight UTC.
        #expect(PaceEngine.sentence(for: .pace(eta: eta), now: now) == "On pace to stay under budget today.")
    }
}
