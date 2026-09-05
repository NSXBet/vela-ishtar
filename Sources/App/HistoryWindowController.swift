// Sources/App/HistoryWindowController.swift
// WP-09 09.2: the local history explorer — one lazily created native
// window over the HistoryRepository's retained days/scopes.
// Why: F03's data-control companion. The window is display-only work: it
// reads the repository on open/selection change, shows observations with
// honest coverage (a partial day says partial), and performs NOTHING while
// closed (no timers, no polling, no observers — §6.2). The legacy
// unassigned archive (HistoryMigration.legacyScopeID) is presented
// separately and never blends into live-scope comparisons. Reopening
// restores the previous selection when that scope is still retained.
// RELEVANT FILES: Sources/VelaCore/HistoryRepository.swift,
// Sources/VelaCore/HistoryMigration.swift, Sources/App/HistoryDayView.swift,
// Sources/App/MarkerView.swift, Tests/VelaAppTests/HistoryWindowTests.swift

import AppKit

@MainActor
public final class HistoryWindowController: NSObject, NSWindowDelegate {

    /// What the explorer shows: one scope's history, or the legacy
    /// unassigned archive in its own section.
    public struct Selection: Equatable {
        public let scope: UsageScope
        public let day: GatewayDay?

        public init(scope: UsageScope, day: GatewayDay?) {
            self.scope = scope
            self.day = day
        }
    }

    private let repository: HistoryRepository
    private var window: NSWindow?
    private var dayView: HistoryDayView?
    /// Saved selection for reopen-restore (within the same scope).
    private var lastSelection: Selection?
    /// Populated while the window is open; drives the day list.
    private var listings: [HistoryRepository.DayListing] = []
    private var liveScopes: [UsageScope] = []
    private var legacyScope: UsageScope?

    public init(repository: HistoryRepository) {
        self.repository = repository
        super.init()
    }

    // MARK: - Open / close

    /// Lazily creates the window on first open; afterwards reuses and
    /// refreshes content. Returns the window so hosts/tests can observe.
    @discardableResult
    public func open() async -> NSWindow {
        if let window {
            await refresh()
            window.makeKeyAndOrderFront(nil)
            return window
        }

        let view = HistoryDayView(frame: NSRect(x: 0, y: 0, width: 560, height: 420), repository: repository)
        view.onSelectionChanged = { [weak self] selection in
            self?.lastSelection = selection
        }
        view.onExportRequested = { [weak self] scope, day in
            self?.runExportDialog(scope: scope, day: day)
        }
        view.onClearHistoryRequested = { [weak self] scope in
            self?.confirmClearHistory(scope: scope)
        }
        view.onMarkerAction = { [weak self] action in
            self?.handleMarkerAction(action)
        }

        let controllerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        controllerWindow.title = "Local History"
        controllerWindow.contentView = view
        controllerWindow.center()
        controllerWindow.setFrameAutosaveName("VelaHistoryWindow")
        controllerWindow.delegate = self
        controllerWindow.isReleasedWhenClosed = false

        window = controllerWindow
        dayView = view
        await refresh()
        await restoreSelectionIfPossible()
        controllerWindow.makeKeyAndOrderFront(nil)
        return controllerWindow
    }

    public func close() {
        window?.close()
    }

    /// NSWindowDelegate: closing STOPS display work. The window object is
    /// retained for reopen; nothing ticks while it is closed.
    public func windowWillClose(_ notification: Notification) {
        dayView?.stopDisplayWork()
    }

    public var isOpen: Bool { window?.isVisible == true }

    // MARK: - Content

    /// Reloads listings from the repository and re-renders. Called on open
    /// and on selection change only — never on a timer. Async: the actor
    /// read must not block the main actor (a semaphore wait here would
    /// deadlock — the Task could never start on a blocked main actor).
    public func refresh() async {
        let repository = self.repository
        listings = await repository.dayListings()
        let fetchedPending = await repository.pendingMarkersList
        let fetchedReceipts = await repository.markerReceiptsList
        var scopes: [UsageScope] = []
        for listing in listings where !scopes.contains(listing.scope) {
            scopes.append(listing.scope)
        }
        liveScopes = scopes.filter { $0.opaqueID.uuidString != HistoryMigration.legacyScopeID }
        legacyScope = scopes.first { $0.opaqueID.uuidString == HistoryMigration.legacyScopeID }
        await dayView?.update(
            listings: listings,
            liveScopes: liveScopes,
            legacyScope: legacyScope,
            pendingMarkers: fetchedPending,
            receipts: fetchedReceipts
        )
    }


    private func restoreSelectionIfPossible() async {
        guard let lastSelection,
              liveScopes.contains(lastSelection.scope) || lastSelection.scope == legacyScope else { return }
        await dayView?.select(selection: lastSelection)
    }

    // MARK: - Actions (09.3 + markers)

    /// User-initiated CSV export through a save panel. The CSV itself is
    /// pure HistoryExport; the dialog is the only I/O here.
    private func runExportDialog(scope: UsageScope, day: GatewayDay) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = HistoryExport.suggestedFileName(scope: scope, day: day)
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let csv = HistoryExport.csv(scope: scope, day: day, observations: await repository.observations(scope: scope, day: day))
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Clear-history requires an explicit confirmation that NAMES the
    /// affected scope before the repository deletes anything.
    private func confirmClearHistory(scope: UsageScope) {
        let alert = NSAlert()
        alert.messageText = "Clear history for this credential?"
        alert.informativeText = """
        This permanently deletes the retained observations and markers for \
        scope \(scope.kind == .account ? "account" : "credential") \
        \(scope.opaqueID.uuidString.prefix(8))… on this Mac. Exported CSVs are unaffected.
        """
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await repository.clearHistory(scope: scope)
            await self.refresh()
        }
    }

    /// Test seam: awaits the repository mutations so tests observe final
    /// state deterministically (handleMarkerAction is fire-and-forget).
    public func handleMarkerActionForTesting(_ action: MarkerAction) async {
        await markerActionBody(action)
        await refresh()
    }

    /// Marker start/finish/cancel from the day view.
    public func handleMarkerAction(_ action: MarkerAction) {
        Task {
            await markerActionBody(action)
            await self.refresh()
        }
    }

    private func markerActionBody(_ action: MarkerAction) async {
        let repository = self.repository
        switch action {
        case .start(let scope, _, let name):
            // The marker anchors on the day's LATEST accepted
            // observation (no extra poll is triggered — §6.2).
            guard let latest = await repository.latestObservation(scope: scope) else { return }
            let marker = SpendMarker.makePending(
                observation: latest,
                name: name,
                startedAt: Date()
            )
            if let marker {
                await repository.startMarker(marker)
            }
        case .finish(let pendingID, _):
            // Finish keeps the start's name.
            guard let pending = await repository.pendingMarkersList.first(where: { $0.id == pendingID }) else { return }
            guard let latest = await repository.latestObservation(scope: pending.scope) else { return }
            _ = await repository.finishMarker(id: pendingID, end: latest)
            try? await repository.saveMarkers()
        case .cancel(let pendingID):
            await repository.cancelMarker(id: pendingID)
            try? await repository.saveMarkers()
        }
    }
}
