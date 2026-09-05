// Sources/App/HistoryDayView.swift
// WP-09 09.2: the explorer's content view — day/scope navigation list,
// selected day's observations with honest coverage, marker section, and
// export/clear controls.
// Why: display-only. A partial day SAYS partial (coverage line under the
// total); totals never imply completeness. The legacy unassigned archive
// (HistoryMigration.legacyScopeID) is a separate scope entry and is
// labeled as archive data so it can never blend with live comparisons.
// RELEVANT FILES: Sources/App/HistoryWindowController.swift,
// Sources/App/MarkerView.swift, Sources/VelaCore/HistoryRepository.swift,
// Tests/VelaAppTests/HistoryWindowTests.swift

import AppKit

/// The explorer's whole content view. State flows in through `update`
/// (from the controller's repository reads); intents flow out through
/// callbacks.
@MainActor
final class HistoryDayView: NSView {

    var onSelectionChanged: ((HistoryWindowController.Selection) -> Void)?
    var onExportRequested: ((UsageScope, GatewayDay) -> Void)?
    var onClearHistoryRequested: ((UsageScope) -> Void)?
    var onMarkerAction: ((MarkerAction) -> Void)?

    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let coverageLabel = NSTextField(labelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")
    private let totalCaption = NSTextField(labelWithString: "")
    private let observationsTable = NSScrollView()
    private let observationsText = NSTextView()
    private let exportButton = NSButton(title: "Export day as CSV…", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear history…", target: nil, action: nil)
    private let markerSection = MarkerSectionView(frame: .zero)

    private var listings: [HistoryRepository.DayListing] = []
    private var liveScopes: [UsageScope] = []
    private var legacyScope: UsageScope?
    /// Popups index (scope ordinal × day list) → selection.
    private var scopeChoices: [(scope: UsageScope, days: [HistoryRepository.DayListing])] = []
    private var selectedScope: UsageScope?
    private var selectedDay: GatewayDay?
    private var pendingMarkers: [PendingMarker] = []
    private var receipts: [MarkerReceipt] = []
    private let repository: HistoryRepository

    init(frame frameRect: NSRect, repository: HistoryRepository) {
        self.repository = repository
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        scopePopup.font = VelaDesign.Typography.body
        dayPopup.font = VelaDesign.Typography.body
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)
        dayPopup.target = self
        dayPopup.action = #selector(dayChanged)

        totalLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        totalCaption.font = VelaDesign.Typography.secondary
        totalCaption.textColor = VelaDesign.Color.caption(contrast: false)
        coverageLabel.font = VelaDesign.Typography.secondary
        coverageLabel.textColor = VelaDesign.Color.caption(contrast: false)

        observationsText.isEditable = false
        observationsText.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        observationsText.autoresizingMask = [.width]
        observationsText.textContainer?.widthTracksTextView = true
        observationsTable.documentView = observationsText
        observationsTable.hasVerticalScroller = true
        observationsTable.borderType = .noBorder

        for button in [exportButton, clearButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = VelaDesign.Typography.secondaryInteractive
            button.target = self
            button.action = #selector(controlTapped(_:))
        }

        markerSection.onAction = { [weak self] action in
            self?.onMarkerAction?(action)
        }

        let topRow = NSStackView(views: [scopePopup, dayPopup])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        let actionRow = NSStackView(views: [exportButton, clearButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        for subview in [topRow, totalLabel, totalCaption, coverageLabel, markerSection, observationsTable, actionRow] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            topRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            totalLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            totalLabel.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),

            totalCaption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            totalCaption.topAnchor.constraint(equalTo: totalLabel.bottomAnchor, constant: 2),

            coverageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            coverageLabel.topAnchor.constraint(equalTo: totalCaption.bottomAnchor, constant: 2),

            markerSection.leadingAnchor.constraint(equalTo: leadingAnchor),
            markerSection.trailingAnchor.constraint(equalTo: trailingAnchor),
            markerSection.topAnchor.constraint(equalTo: coverageLabel.bottomAnchor, constant: 10),

            observationsTable.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            observationsTable.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            observationsTable.topAnchor.constraint(equalTo: markerSection.bottomAnchor, constant: 10),

            actionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            actionRow.topAnchor.constraint(equalTo: observationsTable.bottomAnchor, constant: 10),
            actionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - State in

    func update(
        listings: [HistoryRepository.DayListing],
        liveScopes: [UsageScope],
        legacyScope: UsageScope?,
        pendingMarkers: [PendingMarker],
        receipts: [MarkerReceipt]
    ) async {
        self.listings = listings
        self.liveScopes = liveScopes
        self.legacyScope = legacyScope
        self.pendingMarkers = pendingMarkers
        self.receipts = receipts

        // Rebuild the scope choices: live scopes first (sorted by scope
        // identity), the legacy archive LAST and labeled — never blended.
        var byScope: [UsageScope: [HistoryRepository.DayListing]] = [:]
        for listing in listings { byScope[listing.scope, default: []].append(listing) }
        scopeChoices = liveScopes.map { ($0, byScope[$0]?.sorted { $0.day.key < $1.day.key } ?? []) }
        if let legacyScope, let legacyDays = byScope[legacyScope] {
            scopeChoices.append((legacyScope, legacyDays.sorted { $0.day.key < $1.day.key }))
        }

        rebuildScopePopup(keepSelected: true)
        rebuildDayPopup(keepSelected: false)
        await renderSelection()
    }

    /// Restores a previous selection (same-scope reopen guarantee).
    func select(selection: HistoryWindowController.Selection) async {
        guard let index = scopeChoices.firstIndex(where: { $0.scope == selection.scope }) else { return }
        scopePopup.selectItem(at: index)
        selectedScope = selection.scope
        rebuildDayPopup(keepSelected: true, preferredDay: selection.day)
        await renderSelection()
        notifySelection()
    }

    func stopDisplayWork() {
        // Display-only: nothing ticks. Clearing selections is enough to
        // prove no retained work; no timers exist to cancel by design.
        observationsText.string = ""
    }

    /// Test/verification seam: how many observation lines are rendered.
    /// 0 when the buffer is cleared (closed window) or nothing was loaded.
    var renderedObservationCount: Int {
        guard observationsText.string.isEmpty == false,
              observationsText.string.hasPrefix("No observations retained") == false else { return 0 }
        return observationsText.string.split(separator: "\n").count
    }

    // MARK: - Rendering

    private func rebuildScopePopup(keepSelected: Bool) {
        scopePopup.removeAllItems()
        for (index, choice) in scopeChoices.enumerated() {
            let isLegacy = choice.scope.opaqueID.uuidString == HistoryMigration.legacyScopeID
            let title = isLegacy
                ? "Legacy archive (unassigned)"
                : "\(choice.scope.kind == .account ? "Account" : "Credential") \(index + 1)"
            scopePopup.addItem(withTitle: title)
            scopePopup.lastItem?.representedObject = index
        }
        if keepSelected, let selectedScope,
           let index = scopeChoices.firstIndex(where: { $0.scope == selectedScope }) {
            scopePopup.selectItem(at: index)
        } else if scopePopup.indexOfSelectedItem < 0, !scopeChoices.isEmpty {
            // First render (or cleared popup): default to the first scope.
            scopePopup.selectItem(at: 0)
        }
        selectedScope = scopePopup.selectedItem.flatMap {
            $0.representedObject as? Int
        }.flatMap { $0 < scopeChoices.count ? scopeChoices[$0].scope : nil }
    }

    private func rebuildDayPopup(keepSelected: Bool, preferredDay: GatewayDay? = nil) {
        dayPopup.removeAllItems()
        guard let scope = selectedScope,
              let choice = scopeChoices.first(where: { $0.scope == scope }) else {
            selectedDay = nil
            return
        }
        for listing in choice.days {
            dayPopup.addItem(withTitle: listing.day.key)
        }
        var target: GatewayDay?
        if keepSelected {
            if let preferredDay, choice.days.contains(where: { $0.day == preferredDay }) {
                target = preferredDay
            } else {
                target = selectedDay
            }
        }
        if let target, let index = choice.days.firstIndex(where: { $0.day == target }) {
            dayPopup.selectItem(at: index)
            selectedDay = target
        } else {
            // Default: newest retained day.
            if let last = choice.days.last {
                dayPopup.selectItem(at: choice.days.count - 1)
                selectedDay = last.day
            } else {
                selectedDay = nil
            }
        }
    }

    private func renderSelection() async {
        let isLegacy = selectedScope?.opaqueID.uuidString == HistoryMigration.legacyScopeID
        clearButton.isEnabled = selectedScope != nil

        guard let scope = selectedScope, let day = selectedDay,
              let listing = listings.first(where: { $0.scope == scope && $0.day == day }) else {
            totalLabel.stringValue = "—"
            totalCaption.stringValue = isLegacy
                ? "Legacy archive: unassigned pre-migration data, shown separately."
                : "No day selected."
            coverageLabel.stringValue = ""
            observationsText.string = ""
            markerSection.render(
                scope: selectedScope, day: selectedDay,
                pending: pendingMarkerForSelection(), receipts: receiptsForSelection()
            )
            return
        }

        let repository = self.repository
        let observations = await repository.observations(scope: scope, day: day)
        await MainActor.run {
            let lastAmount = observations.last?.cumulativeAmount
                self.totalLabel.stringValue = lastAmount.map { MoneyFormat.dollars($0) } ?? "$0.00"
                self.totalCaption.stringValue = isLegacy
                    ? "Legacy archive day — unassigned pre-migration readings; never compared with live data."
                    : "Latest cumulative observed spend for \(day.key)"
                if listing.coverage.isComplete {
                    self.coverageLabel.stringValue = "Coverage: complete for this billing day"
                } else {
                    let first = listing.coverage.firstObservationAt.map { Self.coverageTime($0) } ?? "—"
                    let last = listing.coverage.lastObservationAt.map { Self.coverageTime($0) } ?? "—"
                    self.coverageLabel.stringValue =
                        "Coverage: PARTIAL day (\(listing.observationCount) readings, \(first)–\(last) UTC)"
                }
            self.observationsText.string = self.observationLines(observations)
        }
        markerSection.render(
            scope: scope, day: day,
            pending: pendingMarkerForSelection(), receipts: receiptsForSelection()
        )
    }


    private func pendingMarkerForSelection() -> PendingMarker? {
        guard let scope = selectedScope else { return nil }
        return pendingMarkers.first { $0.scope == scope }
    }

    private func receiptsForSelection() -> [MarkerReceipt] {
        guard let scope = selectedScope else { return [] }
        return receipts.filter { $0.scope == scope }.suffix(20).reversed()
    }

    private static func coverageTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func observationLines(_ observations: [Observation]) -> String {
        guard !observations.isEmpty else { return "No observations retained for this day." }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return observations.map { observation in
            let time = formatter.string(from: observation.receivedAt)
            let amount = MoneyFormat.dollars(observation.cumulativeAmount)
            let precision = observation.precision == .exactReceipt ? "exact" : "hour"
            return "\(time) UTC  \(amount)  (\(precision))"
        }.joined(separator: "\n")
    }

    // MARK: - Intents out

    @objc private func scopeChanged() {
        selectedScope = scopePopup.selectedItem.flatMap {
            $0.representedObject as? Int
        }.map { scopeChoices[$0].scope }
        rebuildDayPopup(keepSelected: false)
        Task { await selectionChangeTask() }
    }

    @objc private func dayChanged() {
        guard let scope = selectedScope,
              let choice = scopeChoices.first(where: { $0.scope == scope }) else { return }
        let index = dayPopup.indexOfSelectedItem
        guard index >= 0, index < choice.days.count else { return }
        selectedDay = choice.days[index].day
        Task { await selectionChangeTask() }
    }

    /// The awaitable body of both popup-change handlers.
    private func selectionChangeTask() async {
        await renderSelection()
        notifySelection()
    }


    @objc private func controlTapped(_ sender: NSButton) {
        guard let scope = selectedScope else { return }
        if sender === exportButton, let day = selectedDay {
            onExportRequested?(scope, day)
        } else if sender === clearButton {
            onClearHistoryRequested?(scope)
        }
    }

    private func notifySelection() {
        guard let scope = selectedScope else { return }
        onSelectionChanged?(HistoryWindowController.Selection(scope: scope, day: selectedDay))
    }
}
