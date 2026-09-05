// Tests/VelaCoreTests/HistoryRepositoryMarkerTests.swift
// WP-09 09.1/09.3: the marker store ON the HistoryRepository actor —
// restart persistence, the 100-receipt bound, marker-boundary pinning
// against coalescing/cap (WP-02's hand-off note), offline recovery within
// the same scope/day, and the clear-history data control.
// RELEVANT FILES: Sources/VelaCore/HistoryRepository.swift,
// Sources/VelaCore/SpendMarker.swift

import Testing
import Foundation
@testable import VelaCore

@Suite("WP-09 repository marker store", .serialized)
struct HistoryRepositoryMarkerTests {
    static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaMarkerTests-\(UUID().uuidString)")
    }

    static let scopeA = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")
    static let scopeB = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")

    static func observation(
        scope: UsageScope = scopeA,
        day: String = "2026-08-01",
        at time: String,
        amount: Double
    ) -> Observation {
        Observation(
            id: UUID(),
            scope: scope,
            gatewayDay: GatewayDay(spendDate: day)!,
            receivedAt: ISODate.parse(time)!,
            cumulativeAmount: amount,
            limitEnabled: true,
            limitUSD: 400,
            precision: .exactReceipt
        )
    }

    // MARK: - restart persistence

    @Test("marker survives simulated relaunch: load from disk restores pending + receipts")
    func restartPersistence() async throws {
        let directory = Self.freshDirectory()
        let first = HistoryRepository(directory: directory)
        await first.append(Self.observation(at: "2026-08-01T10:00:00Z", amount: 10))
        await first.append(Self.observation(at: "2026-08-01T12:00:00Z", amount: 25))
        let pending = SpendMarker.makePending(
            observation: Self.observation(at: "2026-08-01T10:00:00Z", amount: 10),
            name: "batch", startedAt: ISODate.parse("2026-08-01T10:01:00Z")!)!
        await first.startMarker(pending)
        let receipt = await first.finishMarker(
            id: pending.id, end: Self.observation(at: "2026-08-01T12:00:00Z", amount: 25))
        try await first.saveMarkers()
        #expect(receipt?.delta == .measured(amountUSD: 15))

        // Relaunch: a NEW repository over the same directory.
        let second = HistoryRepository(directory: directory)
        await second.loadMarkers()
        let pendingList = await second.pendingMarkersList
        let receipts = await second.markerReceiptsList
        #expect(pendingList.isEmpty) // finished before "relaunch"
        #expect(receipts.count == 1)
        #expect(receipts.first?.name == "batch")
        #expect(receipts.first?.delta == .measured(amountUSD: 15))
    }

    @Test("pending marker survives relaunch and can be finished there")
    func pendingSurvivesRelaunch() async throws {
        let directory = Self.freshDirectory()
        let first = HistoryRepository(directory: directory)
        let startObs = Self.observation(at: "2026-08-01T10:00:00Z", amount: 10)
        await first.append(startObs)
        let pending = SpendMarker.makePending(
            observation: startObs, name: nil, startedAt: startObs.receivedAt)!
        await first.startMarker(pending)
        try await first.saveMarkers()

        let second = HistoryRepository(directory: directory)
        await second.loadMarkers()
        await second.append(Self.observation(at: "2026-08-01T11:00:00Z", amount: 20))
        let receipts = await second.markerReceiptsList
        #expect(receipts.isEmpty)
        let pendingCount = await second.pendingMarkersList.count
        #expect(pendingCount == 1)
        let finished = await second.finishMarker(
            id: pending.id, end: Self.observation(at: "2026-08-01T11:00:00Z", amount: 20))
        #expect(finished?.delta == .measured(amountUSD: 10))
    }

    @Test("unusable markers.json is retained as .unusable and the store starts empty")
    func corruptMarkersFile() async throws {
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("markers.json"))
        let repository = HistoryRepository(directory: directory)
        await repository.loadMarkers()
        let receipts = await repository.markerReceiptsList
        #expect(receipts.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("markers.json.unusable").path))
    }

    // MARK: - the 100-receipt bound

    @Test("receipt list caps at 100, oldest dropped first")
    func receiptCap() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        let end = Self.observation(at: "2026-08-01T11:00:00Z", amount: 20)
        for i in 0..<105 {
            let pending = SpendMarker.makePending(
                observation: Self.observation(at: "2026-08-01T10:00:00Z", amount: 10),
                name: "m\(i)",
                startedAt: ISODate.parse("2026-08-01T10:00:00Z")!
                    .addingTimeInterval(TimeInterval(i)))!
            await repository.startMarker(pending)
            let receipt = await repository.finishMarker(id: pending.id, end: end)
            #expect(receipt != nil)
            await repository.cancelMarker(id: UUID()) // no-op; keeps actor traffic realistic
        }
        let receipts = await repository.markerReceiptsList
        #expect(receipts.count == 100)
        #expect(receipts.first?.name == "m5") // oldest five dropped
        #expect(receipts.last?.name == "m104")
    }

    // MARK: - boundary pinning (WP-02 hand-off)

    @Test("marker boundary observation survives per-day cap pressure")
    func boundarySurvivesCap() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        // Start a marker on the day's FIRST observation.
        let startObs = Self.observation(at: "2026-08-01T00:30:00Z", amount: 1)
        await repository.append(startObs)
        let pending = SpendMarker.makePending(observation: startObs, name: nil, startedAt: startObs.receivedAt)!
        await repository.startMarker(pending)

        // Flood the day past the 320 cap with interior observations.
        for i in 1...400 {
            let time = ISODate.parse("2026-08-01T00:30:00Z")!.addingTimeInterval(TimeInterval(i * 60))
            let formatter = ISO8601DateFormatter()
            await repository.append(Self.observation(
                at: formatter.string(from: time), amount: Double(1 + i)))
        }
        let day = await repository.observations(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!)
        #expect(day.count <= HistoryRetention.maxObservationsPerDay)
        // The pinned start observation is STILL THERE.
        #expect(day.contains(where: { $0.id == startObs.id }))
    }

    @Test("five-minute coalescing never collapses a marker start observation")
    func coalescingKeepsMarkerBaseline() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        let startObs = Self.observation(at: "2026-08-01T10:00:00Z", amount: 10)
        await repository.append(startObs)
        let pending = SpendMarker.makePending(observation: startObs, name: nil, startedAt: startObs.receivedAt)!
        await repository.startMarker(pending)
        // Same five-minute bucket, higher amount: an unpinned day would
        // replace the 10:00 reading.
        await repository.append(Self.observation(at: "2026-08-01T10:02:00Z", amount: 12))
        let day = await repository.observations(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!)
        #expect(day.contains(where: { $0.id == startObs.id }))
    }

    // MARK: - offline recovery within same scope/day

    @Test("offline recovery: finishing with a late same-day observation measures the full interval")
    func offlineRecovery() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        let startObs = Self.observation(at: "2026-08-01T10:00:00Z", amount: 10)
        await repository.append(startObs)
        let pending = SpendMarker.makePending(observation: startObs, name: nil, startedAt: startObs.receivedAt)!
        await repository.startMarker(pending)
        // App comes back online hours later; the gateway reports the
        // day's cumulative including the offline window.
        let receipt = await repository.finishMarker(
            id: pending.id, end: Self.observation(at: "2026-08-01T18:00:00Z", amount: 25))
        #expect(receipt?.delta == .measured(amountUSD: 15))
    }

    // MARK: - one pending marker per scope

    @Test("new start replaces the scope's previous pending marker")
    func onePendingPerScope() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        let first = SpendMarker.makePending(
            observation: Self.observation(at: "2026-08-01T10:00:00Z", amount: 10),
            name: "old", startedAt: Date())!
        let second = SpendMarker.makePending(
            observation: Self.observation(at: "2026-08-01T10:30:00Z", amount: 12),
            name: "new", startedAt: Date())!
        await repository.startMarker(first)
        await repository.startMarker(second)
        let pendingList = await repository.pendingMarkersList
        #expect(pendingList.count == 1)
        #expect(pendingList.first?.name == "new")
    }

    // MARK: - day listing + latest

    @Test("dayListings enumerates retained scope/day pairs with coverage; latestObservation returns the newest reading")
    func listingsAndLatest() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        await repository.append(Self.observation(day: "2026-08-02", at: "2026-08-02T10:00:00Z", amount: 5))
        await repository.append(Self.observation(day: "2026-08-01", at: "2026-08-01T10:00:00Z", amount: 3))
        await repository.append(Self.observation(
            scope: Self.scopeB, day: "2026-08-01", at: "2026-08-01T12:00:00Z", amount: 7))

        let listings = await repository.dayListings()
        #expect(listings.count == 3)
        // Sorted by scope ID then day key.
        let keys = listings.map { "\($0.scope.opaqueID.uuidString)/\($0.day.key)" }
        #expect(keys == keys.sorted())

        let latest = await repository.latestObservation(scope: Self.scopeA)
        #expect(latest?.cumulativeAmount == 5) // Aug 2's only reading
        let none = await repository.latestObservation(
            scope: UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com"))
        #expect(none == nil)
    }

    // MARK: - clear history (data control)

    @Test("clearHistory removes the scope's days, markers, and leaves other scopes intact")
    func clearHistory() async {
        let repository = HistoryRepository(directory: Self.freshDirectory())
        await repository.append(Self.observation(at: "2026-08-01T10:00:00Z", amount: 10))
        await repository.append(Self.observation(
            scope: Self.scopeB, at: "2026-08-01T10:00:00Z", amount: 10))
        let pending = SpendMarker.makePending(
            observation: Self.observation(at: "2026-08-01T10:00:00Z", amount: 10),
            name: nil, startedAt: Date())!
        await repository.startMarker(pending)

        await repository.clearHistory(scope: Self.scopeA)
        let cleared = await repository.observations(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!)
        #expect(cleared.isEmpty)
        let pendingList = await repository.pendingMarkersList
        #expect(pendingList.isEmpty)
        let scopeBObservations = await repository.observations(
            scope: Self.scopeB, day: GatewayDay(spendDate: "2026-08-01")!)
        #expect(scopeBObservations.count == 1)
    }
}
