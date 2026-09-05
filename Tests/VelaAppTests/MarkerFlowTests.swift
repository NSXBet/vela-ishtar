// Tests/VelaAppTests/MarkerFlowTests.swift
// WP-09 09.1 (UI flow): the marker section view and the controller's
// marker actions end-to-end against a real repository. Pins: start anchors
// on the day's latest accepted observation, finish produces the receipt,
// cancel drops the pending marker, receipt rows render measured deltas and
// unavailable reasons honestly, and the 80-char name bound holds at the
// field level.
// RELEVANT FILES: Sources/App/MarkerView.swift, Sources/App/HistoryWindowController.swift,
// Sources/VelaCore/SpendMarker.swift, Sources/VelaCore/HistoryRepository.swift

import Testing
import AppKit
import Foundation
@testable import VelaCore

@MainActor
@Suite("WP-09 marker flow", .serialized)
struct MarkerFlowTests {
    static let scopeA = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: "https://gw.example.com")

    static func observation(at time: String, amount: Double) -> Observation {
        Observation(
            id: UUID(),
            scope: scopeA,
            gatewayDay: GatewayDay(spendDate: "2026-08-01")!,
            receivedAt: ISODate.parse(time)!,
            cumulativeAmount: amount,
            limitEnabled: true,
            limitUSD: 400,
            precision: .exactReceipt
        )
    }

    @Test("start → finish flow through the controller measures the delta against the latest observation")
    func startFinishFlow() async throws {
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaMarkerFlowTests-\(UUID().uuidString)"))
        await repository.append(Self.observation(at: "2026-08-01T10:00:00Z", amount: 10))
        await repository.append(Self.observation(at: "2026-08-01T12:00:00Z", amount: 25))

        let controller = HistoryWindowController(repository: repository)
        await controller.handleMarkerActionForTesting(.start(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!, name: "batch"))
        var pendingList = await repository.pendingMarkersList
        #expect(pendingList.count == 1)
        // Anchored on the LATEST observation (25 at 12:00), not the first.
        #expect(pendingList.first?.startObservation.cumulativeAmount == 25)

        await repository.append(Self.observation(at: "2026-08-01T14:00:00Z", amount: 40))
        await controller.handleMarkerActionForTesting(.finish(pendingID: pendingList.first!.id, name: nil))
        let receipts = await repository.markerReceiptsList
        #expect(receipts.count == 1)
        #expect(receipts.first?.delta == .measured(amountUSD: 15))
        pendingList = await repository.pendingMarkersList
        #expect(pendingList.isEmpty)
    }

    @Test("cancel flow drops the pending marker without a receipt")
    func cancelFlow() async {
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaMarkerFlowTests-\(UUID().uuidString)"))
        await repository.append(Self.observation(at: "2026-08-01T10:00:00Z", amount: 10))
        let controller = HistoryWindowController(repository: repository)
        await controller.handleMarkerActionForTesting(.start(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!, name: "x"))
        let pending = await repository.pendingMarkersList.first!
        await controller.handleMarkerActionForTesting(.cancel(pendingID: pending.id))
        let pendingList = await repository.pendingMarkersList
        let receipts = await repository.markerReceiptsList
        #expect(pendingList.isEmpty)
        #expect(receipts.isEmpty)
    }

    @Test("start on a scope with no observations is a no-op (no fabricated baseline)")
    func startWithoutBaseline() async {
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaMarkerFlowTests-\(UUID().uuidString)"))
        let controller = HistoryWindowController(repository: repository)
        await controller.handleMarkerActionForTesting(.start(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!, name: nil))
        let pendingList = await repository.pendingMarkersList
        #expect(pendingList.isEmpty) // no baseline → no marker
    }

    @Test("receipt rows render measured delta and unavailable reason distinctly")
    func receiptRowRendering() {
        let start = Self.observation(at: "2026-08-01T10:00:00Z", amount: 10)
        let measured = MarkerReceipt(
            id: UUID(), name: "batch", scope: Self.scopeA,
            startDay: start.gatewayDay, endDay: start.gatewayDay,
            startObservation: start,
            endObservation: Self.observation(at: "2026-08-01T12:00:00Z", amount: 25),
            delta: .measured(amountUSD: 15))
        let unavailable = MarkerReceipt(
            id: UUID(), name: "cross-day", scope: Self.scopeA,
            startDay: start.gatewayDay, endDay: GatewayDay(spendDate: "2026-08-02")!,
            startObservation: start, endObservation: nil,
            delta: .unavailable(.discontinuity))

        let row = MarkerReceiptRow(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        row.render(receipt: measured, now: Date())
        // Measured delta renders as money.
        #expect(row.deltaText == "$15.00")
        row.render(receipt: unavailable, now: Date())
        // Unavailable renders its REASON, not a number.
        #expect(row.deltaText == "correction in interval")
    }

    @Test("marker section disables start for legacy archive scope")
    func legacyArchiveNoMarkers() async {
        let legacyScope = UsageScope(
            kind: .credential,
            opaqueID: UUID(uuidString: HistoryMigration.legacyScopeID)!,
            gatewayOrigin: "https://gw.example.com")
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaMarkerFlowTests-\(UUID().uuidString)"))
        let legacyObservation = Observation(
            id: UUID(), scope: legacyScope,
            gatewayDay: GatewayDay(spendDate: "2026-08-01")!,
            receivedAt: ISODate.parse("2026-08-01T09:00:00Z")!,
            cumulativeAmount: 4, limitEnabled: true, limitUSD: 400,
            precision: .exactReceipt)
        await repository.append(legacyObservation)

        let section = MarkerSectionView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        section.render(
            scope: legacyScope,
            day: GatewayDay(spendDate: "2026-08-01")!,
            pending: nil,
            receipts: []
        )
        #expect(section.isStartEnabled == false)
    }

    @Test("marker section enables start for a live scope with a pending-free state")
    func liveScopeStartEnabled() {
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaMarkerFlowTests-\(UUID().uuidString)"))
        _ = repository
        let section = MarkerSectionView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        section.render(
            scope: Self.scopeA,
            day: GatewayDay(spendDate: "2026-08-01")!,
            pending: nil,
            receipts: []
        )
        #expect(section.isStartEnabled)
    }

    @Test("name field delegate caps input at 80 characters")
    func nameFieldCap() {
        let field = NSTextField(string: "")
        field.delegate = NameLimitDelegate.shared
        field.stringValue = String(repeating: "x", count: 120)
        // Simulate the delegate's text-did-change enforcement.
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        #expect(field.stringValue.count == 80)
    }

    // MARK: - coordinator gate fixes

    @Test("marker start anchors on the SELECTED day, not the scope's newest day")
    func startAnchorsSelectedDay() async throws {
        let repository = HistoryRepository(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaMarkerFlowTests-\(UUID().uuidString)"))
        // Two days: the user selects the OLDER day; the scope's newest
        // observation lives on 08-02 and must NOT become the baseline.
        await repository.append(Self.observation(at: "2026-08-01T10:00:00Z", amount: 10))
        await repository.append(Observation(
            id: UUID(), scope: Self.scopeA,
            gatewayDay: GatewayDay(spendDate: "2026-08-02")!,
            receivedAt: ISODate.parse("2026-08-02T10:00:00Z")!,
            cumulativeAmount: 77, limitEnabled: true, limitUSD: 400,
            precision: .exactReceipt
        ))

        let controller = HistoryWindowController(repository: repository)
        await controller.handleMarkerActionForTesting(.start(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!, name: nil))
        let pendingList = await repository.pendingMarkersList
        #expect(pendingList.count == 1)
        #expect(pendingList.first?.startObservation.cumulativeAmount == 10,
                "baseline must come from the selected day (10), not the newest day (77)")
        #expect(pendingList.first?.startObservation.gatewayDay.key == "2026-08-01")
    }

    @Test("marker start persists immediately — a fresh repository sees the pending marker")
    func startPersistsImmediately() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaMarkerFlowTests-\(UUID().uuidString)")
        let repository = HistoryRepository(directory: directory)
        await repository.append(Self.observation(at: "2026-08-01T10:00:00Z", amount: 10))

        let controller = HistoryWindowController(repository: repository)
        await controller.handleMarkerActionForTesting(.start(
            scope: Self.scopeA, day: GatewayDay(spendDate: "2026-08-01")!, name: "persist"))

        // A brand-new repository over the SAME directory simulates relaunch:
        // the pending marker must be on disk, not only in memory.
        let reloaded = HistoryRepository(directory: directory)
        _ = await reloaded.load()
        let pendingList = await reloaded.pendingMarkersList
        #expect(pendingList.count == 1, "start must persist immediately (crash safety)")
        #expect(pendingList.first?.name == "persist")
    }
}
