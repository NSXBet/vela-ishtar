// Tests/VelaCoreTests/FreshnessTests.swift
// Verifies the WP-04 Freshness derivation (04.1): receipt-age freshness with
// the 90-second contract ceiling, exact-receipt vs legacy-hour precision,
// immediate invalidation on auth errors, conservative clock-rollback
// handling, and the exact 90-second boundary.
// Why: B05 — freshness used to track failure counts instead of elapsed age,
// letting a hung request keep hours-old numbers "fresh".
// RELEVANT FILES: Sources/VelaCore/Freshness.swift, Sources/VelaCore/Observation.swift

import Testing
import Foundation
@testable import VelaCore

struct FreshnessTests {
    private let now = ISODate.parse("2026-08-01T12:00:00Z")!

    // MARK: basic derivation

    @Test("a reading received just now is fresh")
    func justReceivedIsFresh() {
        let f = Freshness.derive(receivedAt: now.addingTimeInterval(-10), now: now)
        #expect(f.isFresh)
        guard case .fresh(let receivedAt, let maxAge) = f else {
            Issue.record("expected .fresh, got \(f)")
            return
        }
        #expect(receivedAt == now.addingTimeInterval(-10))
        #expect(maxAge == Freshness.maxAgeSeconds)
    }

    @Test("a reading 89 seconds old is fresh; exactly 90 seconds is the boundary and still fresh")
    func exactNinetySecondBoundary() {
        #expect(Freshness.derive(receivedAt: now.addingTimeInterval(-89), now: now).isFresh)
        #expect(Freshness.derive(receivedAt: now.addingTimeInterval(-90), now: now).isFresh)
    }

    @Test("a reading 91 seconds old is stale — beyond the 90s contract window")
    func pastNinetySecondsIsStale() {
        let f = Freshness.derive(receivedAt: now.addingTimeInterval(-91), now: now)
        guard case .stale(let lastReceivedAt) = f else {
            Issue.record("expected .stale, got \(f)")
            return
        }
        #expect(lastReceivedAt == now.addingTimeInterval(-91))
        #expect(!f.isFresh)
    }

    @Test("nothing ever received is stale with nil lastReceivedAt")
    func neverReceived() {
        #expect(Freshness.derive(receivedAt: nil, now: now) == .stale(lastReceivedAt: nil))
    }

    // MARK: explicit invalidation

    @Test("an auth error invalidates trust IMMEDIATELY regardless of age")
    func authErrorInvalidatesImmediately() {
        // Even a receipt from one second ago is revoked.
        let f = Freshness.derive(
            receivedAt: now.addingTimeInterval(-1),
            now: now,
            invalidatedBy: "authentication failed"
        )
        guard case .invalidated(let reason) = f else {
            Issue.record("expected .invalidated, got \(f)")
            return
        }
        #expect(reason == "authentication failed")
        #expect(!f.isFresh)
    }

    @Test("invalidation wins even over a brand-new receipt")
    func invalidationBeatsFreshReceipt() {
        let f = Freshness.derive(
            receivedAt: now,
            now: now,
            invalidatedBy: "credential changed"
        )
        #expect(!f.isFresh)
    }

    // MARK: clock rollback (conservative)

    @Test("a receipt a few seconds ahead of the clock is tolerated jitter and stays fresh")
    func smallClockSkewTolerated() {
        #expect(Freshness.derive(receivedAt: now.addingTimeInterval(3), now: now).isFresh)
        #expect(Freshness.derive(receivedAt: now.addingTimeInterval(5), now: now).isFresh)
    }

    @Test("a receipt far ahead of the (rolled-back) clock is stale, never infinitely fresh")
    func bigClockRollbackIsStale() {
        let f = Freshness.derive(receivedAt: now.addingTimeInterval(600), now: now)
        guard case .stale = f else {
            Issue.record("expected .stale, got \(f)")
            return
        }
        #expect(!f.isFresh)
    }

    // MARK: precision (B15)

    @Test("a legacy-hour reading ages from its SLOT START, not its stamped instant")
    func legacyHourAgesFromSlotStart() {
        // Received stamp 12:29:00 (legacy hour value); the honest age bound
        // is 12:00 (slot start) → at 12:01:30 it is already 90s old → stale.
        let stamp = ISODate.parse("2026-08-01T12:29:00Z")!
        let evalAt = ISODate.parse("2026-08-01T12:01:00Z")!
        let f = Freshness.derive(receivedAt: stamp, precision: .legacyHour, now: evalAt)
        guard case .stale = f else {
            Issue.record("expected .stale, got \(f)")
            return
        }
        // The same stamp measured as an exact receipt at 12:01 is IN THE
        // FUTURE — conservative stale, not fresh.
        #expect(!Freshness.derive(receivedAt: stamp, precision: .exactReceipt, now: evalAt).isFresh)
    }

    @Test("an exact receipt uses its true time, not a slot bound")
    func exactReceiptUsesRealTime() {
        let stamp = now.addingTimeInterval(-45)
        #expect(Freshness.derive(receivedAt: stamp, precision: .exactReceipt, now: now).isFresh)
    }

    // MARK: process wake / older spend day

    @Test("after a process wake past the window, the old reading is stale (age is real, not reset)")
    func wakeAfterWindowIsStale() {
        let beforeSleep = now.addingTimeInterval(-3600)
        let f = Freshness.derive(receivedAt: beforeSleep, now: now)
        guard case .stale = f else {
            Issue.record("expected .stale, got \(f)")
            return
        }
    }

    @Test("an older spend day's reading is stale by age alone — no special-casing")
    func olderDayReadingIsStale() {
        let yesterday = now.addingTimeInterval(-86400)
        guard case .stale = Freshness.derive(receivedAt: yesterday, now: now) else {
            Issue.record("expected .stale")
            return
        }
    }
}
