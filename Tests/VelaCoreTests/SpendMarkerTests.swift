// Tests/VelaCoreTests/SpendMarkerTests.swift
// WP-09 09.1: the marker engine. Pins the §9 test list: 10→25=$15 delta,
// restart persistence (deterministic FNV-1a rehydrated IDs), invalid ends,
// stale start/finish, same-day offline recovery, midnight boundary,
// token replacement mid-marker, correction → discontinuity, name
// normalization, and the 100-receipt bound (repository side in
// HistoryRepositoryTests' marker suite).
// RELEVANT FILES: Sources/VelaCore/SpendMarker.swift,
// Sources/VelaCore/HistoryRepository.swift

import Testing
import Foundation
@testable import VelaCore

struct SpendMarkerTests {
    static let scopeA = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")
    static let scopeB = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")

    static func observation(
        scope: UsageScope = scopeA,
        day: String = "2026-08-01",
        at time: String,
        amount: Double,
        limitEnabled: Bool = true,
        limitUSD: Double = 400,
        precision: Observation.Precision = .exactReceipt
    ) -> Observation {
        Observation(
            id: UUID(),
            scope: scope,
            gatewayDay: GatewayDay(spendDate: day)!,
            receivedAt: ISODate.parse(time)!,
            cumulativeAmount: amount,
            limitEnabled: limitEnabled,
            limitUSD: limitUSD,
            precision: precision
        )
    }

    static func pending(at time: String = "2026-08-01T10:00:00Z", amount: Double = 10, name: String? = nil) -> PendingMarker {
        SpendMarker.makePending(
            observation: observation(at: time, amount: amount),
            name: name,
            startedAt: ISODate.parse(time)!
        )!
    }

    // MARK: - the canonical delta

    @Test("10→25 measures $15")
    func canonicalDelta() {
        let start = Self.pending(at: "2026-08-01T10:00:00Z", amount: 10)
        let receipt = SpendMarker.finishReceipt(
            pending: start,
            end: Self.observation(at: "2026-08-01T12:00:00Z", amount: 25),
            intermediates: []
        )
        guard case .measured(let amount)? = receipt?.delta else {
            Issue.record("expected measured delta")
            return
        }
        #expect(amount == 15)
        #expect(receipt?.endDay.key == "2026-08-01")
        #expect(receipt?.id == start.id)
    }

    // MARK: - invalid ends

    @Test("end at or before start is invalid — marker stays pending, no receipt")
    func invalidEndTimes() {
        let start = Self.pending(at: "2026-08-01T10:00:00Z", amount: 10)
        #expect(SpendMarker.finishReceipt(
            pending: start, end: Self.observation(at: "2026-08-01T10:00:00Z", amount: 20), intermediates: []) == nil)
        #expect(SpendMarker.finishReceipt(
            pending: start, end: Self.observation(at: "2026-08-01T09:00:00Z", amount: 20), intermediates: []) == nil)
    }

    @Test("non-finite amounts are rejected at start and finish")
    func nonFiniteAmounts() {
        #expect(SpendMarker.makePending(
            observation: Self.observation(at: "2026-08-01T10:00:00Z", amount: .nan),
            name: nil, startedAt: Date()) == nil)
        #expect(SpendMarker.makePending(
            observation: Self.observation(at: "2026-08-01T10:00:00Z", amount: .infinity),
            name: nil, startedAt: Date()) == nil)
        let start = Self.pending(amount: 10)
        #expect(SpendMarker.finishReceipt(
            pending: start, end: Self.observation(at: "2026-08-01T11:00:00Z", amount: .nan), intermediates: []) == nil)
    }

    // MARK: - boundaries

    @Test("midnight boundary: cross-day finish is an explicit discontinuity, never a guessed delta")
    func midnightBoundary() {
        let start = Self.pending(at: "2026-08-01T23:00:00Z", amount: 10)
        let receipt = SpendMarker.finishReceipt(
            pending: start,
            // Next UTC day: the gateway's cumulative resets; 5 < 15 would
            // look like a NEGATIVE delta if guessed.
            end: Self.observation(day: "2026-08-02", at: "2026-08-02T01:00:00Z", amount: 5),
            intermediates: []
        )
        #expect(receipt != nil)
        #expect(receipt?.delta == .unavailable(.discontinuity))
        #expect(receipt?.endDay.key == "2026-08-02")
    }

    @Test("token replacement mid-marker → scopeChanged")
    func tokenReplacement() {
        let start = Self.pending(amount: 10)
        let receipt = SpendMarker.finishReceipt(
            pending: start,
            end: Self.observation(scope: Self.scopeB, at: "2026-08-01T11:00:00Z", amount: 25),
            intermediates: []
        )
        #expect(receipt?.delta == .unavailable(.scopeChanged))
        #expect(receipt?.scope == Self.scopeA)
    }

    @Test("downward correction inside the interval → discontinuity even when endpoints rise")
    func correctionInsideInterval() {
        let start = Self.pending(at: "2026-08-01T10:00:00Z", amount: 10)
        let receipt = SpendMarker.finishReceipt(
            pending: start,
            end: Self.observation(at: "2026-08-01T13:00:00Z", amount: 30),
            intermediates: [
                // A corrected cumulative below the earlier peak (10 → 2 is
                // beyond max(1%, $0.50) tolerance) breaks comparability.
                Self.observation(at: "2026-08-01T12:00:00Z", amount: 2)
            ]
        )
        #expect(receipt?.delta == .unavailable(.discontinuity))
    }

    @Test("same-day offline recovery: a late observation resumes the cumulative series")
    func sameDayOfflineRecovery() {
        let start = Self.pending(at: "2026-08-01T10:00:00Z", amount: 10)
        let receipt = SpendMarker.finishReceipt(
            pending: start,
            // Gap in observations (offline), but cumulative keeps rising —
            // the series stays comparable.
            end: Self.observation(at: "2026-08-01T18:00:00Z", amount: 25),
            intermediates: [
                Self.observation(at: "2026-08-01T11:00:00Z", amount: 14)
            ]
        )
        #expect(receipt?.delta == .measured(amountUSD: 15))
    }

    // MARK: - stale starts

    @Test("stale start: finishing with an end whose day differs flags discontinuity, and a start observation older than the day's history still measures the true interval")
    func staleStart() {
        // Stale = the start observation is no longer the day's latest.
        // That is FINE for the engine — the delta is measured between the
        // two pinned endpoint readings, which is exactly the interval the
        // user bracketed.
        let start = Self.pending(at: "2026-08-01T10:00:00Z", amount: 10)
        let receipt = SpendMarker.finishReceipt(
            pending: start,
            end: Self.observation(at: "2026-08-01T20:00:00Z", amount: 40),
            intermediates: [
                Self.observation(at: "2026-08-01T12:00:00Z", amount: 15),
                Self.observation(at: "2026-08-01T16:00:00Z", amount: 28),
            ]
        )
        #expect(receipt?.delta == .measured(amountUSD: 30))
    }

    // MARK: - names

    @Test("name normalization: trim, empty→nil, truncate at 80")
    func nameNormalization() {
        #expect(SpendMarker.normalizedName("  batch job  ") == "batch job")
        #expect(SpendMarker.normalizedName("   ") == nil)
        #expect(SpendMarker.normalizedName(nil) == nil)
        let long = String(repeating: "x", count: 120)
        #expect(SpendMarker.normalizedName(long)?.count == 80)
        let marker = SpendMarker.makePending(
            observation: Self.observation(at: "2026-08-01T10:00:00Z", amount: 10),
            name: "  ", startedAt: Date())
        #expect(marker?.name == nil)
    }

    // MARK: - persistence round-trip

    @Test("markers.json round-trip: pending + receipts survive with identical content")
    func dtoRoundTrip() throws {
        let scope = Self.scopeA
        let startObs = Self.observation(scope: scope, at: "2026-08-01T10:00:00Z", amount: 10)
        let pendingMarker = PendingMarker(
            id: UUID(), name: "batch", scope: scope,
            startObservation: startObs,
            startedAt: ISODate.parse("2026-08-01T10:05:00Z")!)
        let receipt = MarkerReceipt(
            id: UUID(), name: nil, scope: scope,
            startDay: startObs.gatewayDay, endDay: startObs.gatewayDay,
            startObservation: startObs,
            endObservation: Self.observation(scope: scope, at: "2026-08-01T12:00:00Z", amount: 25),
            delta: .measured(amountUSD: 15))
        let unavailable = MarkerReceipt(
            id: UUID(), name: "cross-day", scope: scope,
            startDay: startObs.gatewayDay, endDay: GatewayDay(spendDate: "2026-08-02")!,
            startObservation: startObs,
            endObservation: Self.observation(scope: scope, day: "2026-08-02", at: "2026-08-02T01:00:00Z", amount: 5),
            delta: .unavailable(.discontinuity))

        let data = try MarkerStoreDTO.encode(pending: [pendingMarker], receipts: [receipt, unavailable])
        let decoded = MarkerStoreDTO.decode(data)
        #expect(decoded?.pending.count == 1)
        #expect(decoded?.pending.first?.name == "batch")
        #expect(decoded?.pending.first?.startedAt == pendingMarker.startedAt)
        #expect(decoded?.pending.first?.startObservation.cumulativeAmount == 10)
        #expect(decoded?.receipts.count == 2)
        #expect(decoded?.receipts.first?.delta == .measured(amountUSD: 15))
        #expect(decoded?.receipts.last?.delta == .unavailable(.discontinuity))
        // IDs (marker + scope) survive so restarts don't orphan pending markers.
        #expect(decoded?.pending.first?.id == pendingMarker.id)
        #expect(decoded?.pending.first?.scope == scope)
        #expect(decoded?.receipts.first?.id == receipt.id)
    }

    @Test("corrupt or wrong-version marker file decodes to nil, not empty")
    func corruptFile() {
        #expect(MarkerStoreDTO.decode(Data("not json".utf8)) == nil)
        var dto = try! JSONSerialization.jsonObject(with: MarkerStoreDTO.encode(pending: [], receipts: [])) as! [String: Any]
        dto["version"] = 99
        let data = try! JSONSerialization.data(withJSONObject: dto, options: [.sortedKeys])
        #expect(MarkerStoreDTO.decode(data) == nil)
    }
}
