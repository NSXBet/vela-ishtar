// Sources/App/SettingsView.swift
// The settings surface, hosted through SecondaryPanelCoordinator (.settings).
// Consolidates: pill size, start-at-login (ServiceManagement with every
// honest outcome), credential recovery status (read-only observation of
// CredentialController — its logic is never modified), data controls
// (open history folder, export entry), and app version/update state.
// Visual language: §5 design tokens only (VelaDesign) — small-caps section
// headers, 32pt-ish row rhythm, accent-chip pill selector, hairlines between
// groups, caption state lines. Why the honesty rules matter: a login toggle
// that failed must SAY it failed with the actual system error, and a
// blocked Keychain must say so — errors never collapse into inert success.
// RELEVANT FILES: Sources/App/PopoverView.swift, Sources/App/DesignTokens.swift,
// Sources/App/BudgetDetailView.swift, docs/v2/DESIGN.md

import Cocoa
import ServiceManagement

/// The honest outcome of a ServiceManagement registration check/attempt.
/// Mirrors SMAppService.Status but carries the error text so failures are
/// explainable, not swallowed (10.3: "do not swallow errors into an inert
/// checkmark").
public enum LoginServiceState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable(String)

    /// Maps SMAppService's status; an unknown raw value degrades to
    /// unavailable with the raw code rather than guessing.
    public static func from(_ status: SMAppService.Status, error: String? = nil) -> LoginServiceState {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable(error ?? "The login service is not registered on this system.")
        @unknown default: return .unavailable(error ?? "Unknown login-service status.")
        }
    }

    public var userLine: String {
        switch self {
        case .enabled: return "On — Vela Ishtar opens at login."
        case .disabled: return "Off."
        case .requiresApproval: return "Waiting for approval — enable it in System Settings → General → Login Items."
        case .unavailable(let why): return "Unavailable — \(why)"
        }
    }
}
@MainActor
public final class SettingsView: NSView {

    /// Fired when the user picks a pill size. The app layer applies it to
    /// StatusItemController (its CalmLevel API stays the owner).
    public var onSelectPillSize: ((Int) -> Void)?

    /// Fired on "Open history folder".
    public var onOpenHistory: (() -> Void)?

    /// Fired on "Open export…" — WP-09's export entry if landed; the
    /// placeholder note otherwise.
    public var onOpenExport: (() -> Void)?

    // MARK: inputs

    private struct Inputs {
        var pillSize: Int
        var pillSizeEnabled: Bool
        var login: LoginServiceState
        var credentialLine: String
        var exportAvailable: Bool
        var version: String
        var updateLine: String
    }
    private var inputs: Inputs

    // MARK: views

    private var stack: NSStackView!
    private var pillButtons: [NSButton] = []
    private var loginStatusLabel: NSTextField!
    private var credentialStatusLabel: NSTextField!
    private var exportButton: NSButton?
    private var exportNote: NSTextField?
    /// Hairlines drawn between section groups (not between rows).
    private var separators: [NSView] = []

    private static let pillTitles = ["Automatic", "Full", "Compact", "Minimal"]

    /// Panel content width: the summary column minus the panel's own
    /// breathing room, so the settings card reads as the popover's sibling.
    private static let panelWidth = VelaDesign.Layout.summaryWidth - 32

    public init(
        pillSize: Int,
        pillSizeEnabled: Bool = true,
        login: LoginServiceState,
        credentialLine: String,
        exportAvailable: Bool,
        version: String,
        updateLine: String
    ) {
        self.inputs = Inputs(
            pillSize: pillSize, pillSizeEnabled: pillSizeEnabled,
            login: login, credentialLine: credentialLine,
            exportAvailable: exportAvailable, version: version, updateLine: updateLine
        )
        super.init(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 10))
        build()
        render()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("SettingsView does not support NSCoder-based initialization")
    }

    // MARK: building

    private func build() {
        let inset = VelaDesign.Layout.contentInset
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = VelaDesign.Layout.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        self.stack = stack

        // Title: same 13pt body voice as the popover's section headers, but
        // full-strength ink — it is the card's one headline.
        addTitle("Settings")

        // Pill size — one horizontal row of four mutually exclusive choices,
        // the active one carried by the accent focus band + checkmark
        // (§5 language: selection is color + state, never plain text alone).
        addSectionLabel("Pill size")
        let pillRow = NSStackView()
        pillRow.orientation = .horizontal
        pillRow.spacing = VelaDesign.Layout.space1
        pillRow.alignment = .centerY
        for (index, title) in Self.pillTitles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(pillPicked(_:)))
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = VelaDesign.Typography.budgetName
            button.tag = index
            button.setAccessibilityLabel("Pill size \(title)")
            if !inputs.pillSizeEnabled { button.isEnabled = false }
            // Focus-band chip: padded hit target ≥ Rows.controlMinHeight.
            button.setAccessibilityElement(true)
            pillRow.addArrangedSubview(button)
            pillButtons.append(button)
        }
        stylePillRow(pillRow)
        stack.addArrangedSubview(pillRow)

        addSectionLabel("Start at login")
        let openLogin = NSButton(title: "Open Login Items settings", target: self, action: #selector(openLoginSettings))
        openLogin.isBordered = false
        openLogin.bezelStyle = .inline
        openLogin.font = VelaDesign.Typography.secondaryInteractive
        openLogin.contentTintColor = .linkColor
        stack.addArrangedSubview(openLogin)
        let loginStatus = NSTextField(labelWithString: "")
        loginStatus.font = VelaDesign.Typography.secondary
        loginStatus.textColor = VelaDesign.Color.caption(contrast: false)
        loginStatus.setAccessibilityLabel("Start at login status")
        stack.addArrangedSubview(loginStatus)
        loginStatusLabel = loginStatus

        stack.addArrangedSubview(makeSeparator())

        addSectionLabel("Credential")
        let credStatus = NSTextField(labelWithString: "")
        credStatus.font = VelaDesign.Typography.secondary
        credStatus.textColor = VelaDesign.Color.caption(contrast: false)
        credStatus.setAccessibilityLabel("Credential status")
        stack.addArrangedSubview(credStatus)
        credentialStatusLabel = credStatus

        stack.addArrangedSubview(makeSeparator())

        addSectionLabel("Data")
        let history = NSButton(title: "Open history folder", target: self, action: #selector(historyTapped))
        history.isBordered = false
        history.bezelStyle = .inline
        history.font = VelaDesign.Typography.secondaryInteractive
        history.contentTintColor = .linkColor
        stack.addArrangedSubview(history)
        if inputs.exportAvailable {
            let export = NSButton(title: "Open export…", target: self, action: #selector(exportTapped))
            export.isBordered = false
            export.bezelStyle = .inline
            export.font = VelaDesign.Typography.secondaryInteractive
            export.contentTintColor = .linkColor
            stack.addArrangedSubview(export)
            exportButton = export
        } else {
            let note = NSTextField(labelWithString: "Export arrives with the local history explorer.")
            note.font = VelaDesign.Typography.secondary
            note.textColor = VelaDesign.Color.caption(contrast: false)
            stack.addArrangedSubview(note)
            exportNote = note
        }

        stack.addArrangedSubview(makeSeparator())

        addSectionLabel("About")
        let version = NSTextField(labelWithString: "Vela Ishtar v\(inputs.version)")
        version.font = VelaDesign.Typography.secondary
        version.textColor = VelaDesign.Color.caption(contrast: false)
        stack.addArrangedSubview(version)
        let update = NSTextField(labelWithString: inputs.updateLine)
        update.font = VelaDesign.Typography.secondary
        update.textColor = VelaDesign.Color.caption(contrast: false)
        stack.addArrangedSubview(update)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset - 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(inset - 4)),
        ])

        applyPillSelection()
    }

    /// Gives each pill chip a padded 28pt-tall hit target and round-rect
    /// background; the SELECTED chip additionally gets the accent focus
    /// band + full ink so one glance picks the active size.
    private func stylePillRow(_ row: NSStackView) {
        for button in pillButtons {
            button.heightAnchor.constraint(
                greaterThanOrEqualToConstant: VelaDesign.Rows.controlMinHeight
            ).isActive = true
            button.widthAnchor.constraint(
                greaterThanOrEqualToConstant: button.intrinsicContentSize.width + 12
            ).isActive = true
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.masksToBounds = true
        }
    }

    private func makeSeparator() -> NSView {
        let line = NSView()
        line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        line.wantsLayer = true
        separators.append(line)
        return line
    }

    /// Re-tints the dynamic surfaces: pill chips (selection band) and the
    /// hairline separators. Dynamic NSColors resolve to CGColor against the
    /// CURRENT appearance at call time (§5.1: never cache one resolution);
    /// viewDidChangeEffectiveAppearance re-runs this on light/dark flips.
    private func applyPillSelection() {
        let accent = NSColor.controlAccentColor
        for (index, button) in pillButtons.enumerated() {
            let selected = index == inputs.pillSize
            if selected {
                button.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
            } else {
                button.layer?.backgroundColor = NSColor.labelColor
                    .withAlphaComponent(0.05).cgColor
            }
            button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
            button.setAccessibilityValue(selected ? "selected" : "not selected")
        }
        for line in separators {
            line.layer?.backgroundColor = VelaDesign.Color.hairline(contrast: false).cgColor
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPillSelection()
    }

    private func addTitle(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = VelaDesign.Typography.body
        label.textColor = .labelColor
        stack.addArrangedSubview(label)
        // breathing room under the title
        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: VelaDesign.Layout.space1).isActive = true
        stack.addArrangedSubview(spacer)
    }

    /// Small-caps caption section header — the SAME treatment BudgetDetail
    /// and ModelsSection use for TODAY / MODELS (§5's one section voice).
    private func addSectionLabel(_ text: String) {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = VelaDesign.Typography.sectionLabel
        label.textColor = VelaDesign.Color.sectionLabel
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(VelaDesign.Layout.sectionSpacing, after: label)
    }

    // MARK: state application

    /// Re-applies state in place (the view persists in the coordinator's
    /// panel across polls; nothing here rebuilds the hierarchy).
    public func apply(
        pillSize: Int? = nil,
        login: LoginServiceState? = nil,
        credentialLine: String? = nil,
        updateLine: String? = nil
    ) {
        if let pillSize { inputs.pillSize = pillSize }
        if let login { inputs.login = login }
        if let credentialLine { inputs.credentialLine = credentialLine }
        if let updateLine { inputs.updateLine = updateLine }
        render()
    }

    private func render() {
        applyPillSelection()
        loginStatusLabel.stringValue = inputs.login.userLine
        credentialStatusLabel.stringValue = inputs.credentialLine
        exportButton?.isHidden = !inputs.exportAvailable
        exportNote?.isHidden = inputs.exportAvailable
    }

    // MARK: actions

    @objc private func pillPicked(_ sender: NSButton) {
        onSelectPillSize?(sender.tag)
        inputs.pillSize = sender.tag
        render()
    }

    @objc private func openLoginSettings() {
        // The system-settings route for every non-enabled state: SMAppService
        // provides the canonical deep link on macOS 13+.
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func historyTapped() { onOpenHistory?() }
    @objc private func exportTapped() { onOpenExport?() }

    // MARK: - Pure copy builders (test-pinned)

    /// The credential status line for each observed CredentialStatus. Read
    /// only — the controller's logic is never modified here; each state
    /// explains itself instead of vanishing into a green dot.
    public static func credentialLine(for status: CredentialStatus) -> String {
        switch status {
        case .missing:
            return "No token saved yet."
        case .available:
            return "Token saved in Keychain — healthy."
        case .denied(let code):
            return "Keychain denied the read (code \(code)) — unlock or re-grant access in Keychain Access."
        case .locked:
            return "Keychain is locked or unavailable — unlock your Mac to restore readings."
        case .validationInProgress:
            return "Validating a new token with AI Hub…"
        case .invalid:
            return "The pasted token was rejected — your saved token is untouched."
        }
    }
}
