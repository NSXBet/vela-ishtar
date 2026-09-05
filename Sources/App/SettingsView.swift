// Sources/App/SettingsView.swift
// WP-10 10.3: the settings surface, hosted through
// SecondaryPanelCoordinator (.settings) in place of WP-07's placeholder
// card. Consolidates: pill size, start-at-login (ServiceManagement with
// every honest outcome), credential recovery status (read-only observation
// of CredentialController — its logic is never modified), data controls
// (open history folder, export entry), and app version/update state.
// Why a real view, not a checkmark: a login toggle that failed must SAY it
// failed with the actual system error, and a blocked Keychain must say so —
// errors never collapse into inert success states.
// RELEVANT FILES: Sources/App/PopoverView.swift, Sources/App/CredentialController.swift,
// Sources/App/StatusItemController.swift, V2_IMPLEMENTATION_PLAN.md §9 WP-10

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

    private static let pillTitles = ["Automatic", "Full", "Compact", "Minimal"]

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
        super.init(frame: NSRect(x: 0, y: 0, width: VelaDesign.Layout.contentWidth + 40, height: 10))
        build()
        render()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("SettingsView does not support NSCoder-based initialization")
    }

    // MARK: building

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = VelaDesign.Layout.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        self.stack = stack

        addTitle("Settings")

        // Pill size — four mutually exclusive choices, checkmark on active.
        addSectionLabel("Pill size")
        for (index, title) in Self.pillTitles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(pillPicked(_:)))
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = VelaDesign.Typography.body
            button.tag = index
            if !inputs.pillSizeEnabled { button.isEnabled = false }
            stack.addArrangedSubview(button)
            pillButtons.append(button)
        }

        addSectionLabel("Start at login")
        let openLogin = NSButton(title: "Open Login Items settings", target: self, action: #selector(openLoginSettings))
        openLogin.isBordered = false
        openLogin.bezelStyle = .inline
        openLogin.font = VelaDesign.Typography.secondaryInteractive
        stack.addArrangedSubview(openLogin)
        let loginStatus = NSTextField(labelWithString: "")
        loginStatus.font = VelaDesign.Typography.secondary
        loginStatus.textColor = VelaDesign.Color.caption(contrast: false)
        loginStatus.setAccessibilityLabel("Start at login status")
        stack.addArrangedSubview(loginStatus)
        loginStatusLabel = loginStatus

        addSectionLabel("Credential")
        let credStatus = NSTextField(labelWithString: "")
        credStatus.font = VelaDesign.Typography.secondary
        credStatus.textColor = VelaDesign.Color.caption(contrast: false)
        credStatus.setAccessibilityLabel("Credential status")
        stack.addArrangedSubview(credStatus)
        credentialStatusLabel = credStatus

        addSectionLabel("Data")
        let history = NSButton(title: "Open history folder", target: self, action: #selector(historyTapped))
        history.isBordered = false
        history.bezelStyle = .inline
        history.font = VelaDesign.Typography.secondaryInteractive
        stack.addArrangedSubview(history)
        if inputs.exportAvailable {
            let export = NSButton(title: "Open export…", target: self, action: #selector(exportTapped))
            export.isBordered = false
            export.bezelStyle = .inline
            export.font = VelaDesign.Typography.secondaryInteractive
            stack.addArrangedSubview(export)
            exportButton = export
        } else {
            let note = NSTextField(labelWithString: "Export arrives with the local history explorer.")
            note.font = VelaDesign.Typography.secondary
            note.textColor = VelaDesign.Color.caption(contrast: false)
            stack.addArrangedSubview(note)
            exportNote = note
        }

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
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
        ])
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

    private func addSectionLabel(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = VelaDesign.Typography.sectionLabel
        label.textColor = VelaDesign.Color.sectionLabel
        stack.addArrangedSubview(label)
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
        for (index, button) in pillButtons.enumerated() {
            button.state = index == inputs.pillSize ? .on : .off
            button.setAccessibilityValue(index == inputs.pillSize ? "selected" : "")
        }
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
