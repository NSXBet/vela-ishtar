// Sources/App/MarkerView.swift
// WP-09 09.1: the marker UI — start/finish controls, pending state, and
// the receipt list with measured deltas or explicit unavailable reasons.
// Why: F02's surface. Marker cost is labeled "observed spend in scope"
// — never project attribution. Deltas that could not be measured render
// their reason ("scope changed", "correction in interval") instead of a
// number. Pure NSView assembly; state comes from the day view's bindings.
// RELEVANT FILES: Sources/App/HistoryDayView.swift,
// Sources/VelaCore/SpendMarker.swift, Sources/App/DesignTokens.swift,
// Tests/VelaAppTests/MarkerFlowTests.swift

import AppKit

/// Marker intents surfaced from the view; the window controller owns the
/// repository mutations.
public enum MarkerAction: Equatable {
    case start(scope: UsageScope, day: GatewayDay, name: String?)
    case finish(pendingID: UUID, name: String?)
    case cancel(pendingID: UUID)
}

/// One receipt row: name, interval label, delta or reason.
@MainActor
final class MarkerReceiptRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let intervalLabel = NSTextField(labelWithString: "")
    private let deltaLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        for label in [nameLabel, intervalLabel, deltaLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = VelaDesign.Typography.body
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        intervalLabel.font = VelaDesign.Typography.secondary
        deltaLabel.font = VelaDesign.Typography.money

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            intervalLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            intervalLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            deltaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            deltaLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: deltaLabel.leadingAnchor, constant: -8),
            intervalLabel.trailingAnchor.constraint(lessThanOrEqualTo: deltaLabel.leadingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    // Test seam: the rendered delta string.
    var deltaText: String { deltaLabel.stringValue }

    func render(receipt: MarkerReceipt, now: Date) {
        nameLabel.stringValue = receipt.name ?? "Marker"
        intervalLabel.stringValue = intervalText(receipt: receipt)
        switch receipt.delta {
        case .measured(let amount):
            deltaLabel.stringValue = MoneyFormat.dollars(amount)
            deltaLabel.textColor = .labelColor
        case .unavailable(let reason):
            deltaLabel.stringValue = reasonLabel(reason)
            deltaLabel.textColor = VelaDesign.Color.caption(contrast: false)
        }
    }

    private func intervalText(receipt: MarkerReceipt) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let start = formatter.string(from: receipt.startObservation.receivedAt)
        if let end = receipt.endObservation {
            return "\(start) – \(formatter.string(from: end.receivedAt)) UTC"
        }
        return "\(start) – in progress"
    }

    private func reasonLabel(_ reason: MarkerReceipt.DeltaUnavailable) -> String {
        switch reason {
        case .noBaseline: return "no baseline"
        case .scopeChanged: return "scope changed"
        case .discontinuity: return "correction in interval"
        }
    }
}

/// The marker section: start control (with bounded name field), the
/// pending marker with finish/cancel, and up to the retained receipts.
@MainActor
final class MarkerSectionView: NSView {
    var onAction: ((MarkerAction) -> Void)?

    private let nameField = NSTextField(string: "")
    private let startButton = NSButton(title: "Start marker", target: nil, action: nil)
    private let finishButton = NSButton(title: "Finish marker", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let pendingLabel = NSTextField(labelWithString: "")
    private let receiptsStack = NSStackView()
    private var currentScope: UsageScope?
    private var currentDay: GatewayDay?
    private var pendingMarker: PendingMarker?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        nameField.placeholderString = "Name (optional, ≤80 chars)"
        nameField.font = VelaDesign.Typography.body
        nameField.translatesAutoresizingMaskIntoConstraints = false
        // Enforce the 80-character bound at the field itself.
        nameField.delegate = NameLimitDelegate.shared

        for button in [startButton, finishButton, cancelButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = VelaDesign.Typography.secondaryInteractive
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
            button.action = #selector(buttonTapped(_:))
        }
        finishButton.isHidden = true
        cancelButton.isHidden = true
        cancelButton.bezelStyle = .rounded

        pendingLabel.font = VelaDesign.Typography.secondary
        pendingLabel.textColor = VelaDesign.Color.caption(contrast: false)

        receiptsStack.orientation = .vertical
        receiptsStack.spacing = 4
        receiptsStack.translatesAutoresizingMaskIntoConstraints = false
        receiptsStack.alignment = .leading

        addSubview(nameField)
        addSubview(startButton)
        addSubview(pendingLabel)
        addSubview(finishButton)
        addSubview(cancelButton)
        addSubview(receiptsStack)

        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            nameField.widthAnchor.constraint(equalToConstant: 200),
            startButton.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 8),
            startButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            pendingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pendingLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 8),
            finishButton.leadingAnchor.constraint(equalTo: pendingLabel.trailingAnchor, constant: 8),
            finishButton.centerYAnchor.constraint(equalTo: pendingLabel.centerYAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: finishButton.trailingAnchor, constant: 6),
            cancelButton.centerYAnchor.constraint(equalTo: pendingLabel.centerYAnchor),
            receiptsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            receiptsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            receiptsStack.topAnchor.constraint(equalTo: pendingLabel.bottomAnchor, constant: 8),
            receiptsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Renders the section for a scope/day. The start button only arms
    /// when a live scope's day is selected (legacy archive never gets
    /// markers — unassigned data has no comparable credential scope).
    func render(scope: UsageScope?, day: GatewayDay?, pending: PendingMarker?, receipts: [MarkerReceipt]) {
        currentScope = scope
        currentDay = day
        pendingMarker = pending
        let isLegacy = scope?.opaqueID.uuidString == HistoryMigration.legacyScopeID
        startButton.isEnabled = scope != nil && day != nil && !isLegacy && pending == nil
        nameField.isEnabled = startButton.isEnabled

        if pending != nil {
            pendingLabel.stringValue = "Marker started — finish on a later observation of the same scope/day."
            pendingLabel.isHidden = false
            finishButton.isHidden = false
            cancelButton.isHidden = false
        } else {
            pendingLabel.stringValue = receipts.isEmpty
                ? "No markers yet. Start one to bracket observed spend."
                : ""
            pendingLabel.isHidden = !receipts.isEmpty
            finishButton.isHidden = true
            cancelButton.isHidden = true
        }

        receiptsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for receipt in receipts {
            let row = MarkerReceiptRow(frame: .zero)
            row.render(receipt: receipt, now: Date())
            row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            row.widthAnchor.constraint(equalTo: receiptsStack.widthAnchor).isActive = true
            receiptsStack.addArrangedSubview(row)
        }
    }

    // Test/verification seams.
    var isStartEnabled: Bool { startButton.isEnabled }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard let scope = currentScope, let day = currentDay else { return }
        if sender === startButton {
            onAction?(.start(scope: scope, day: day, name: nameField.stringValue))
            nameField.stringValue = ""
        } else if sender === finishButton, let pending = pendingMarker {
            onAction?(.finish(pendingID: pending.id, name: pending.name))
        } else if sender === cancelButton, let pending = pendingMarker {
            onAction?(.cancel(pendingID: pending.id))
        }
    }
}

/// Caps the marker name field at SpendMarker.maxNameLength characters.
@MainActor
final class NameLimitDelegate: NSObject, NSTextFieldDelegate {
    static let shared = NameLimitDelegate()

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field.stringValue.count > SpendMarker.maxNameLength else { return }
        field.stringValue = String(field.stringValue.prefix(SpendMarker.maxNameLength))
    }
}
