// Sources/App/FirstRunView.swift
// Token entry view shown on first launch (and when the gateway rejects the
// saved token): one secure field, one save button, one honest error line.
// Why: Vela Ishtar needs each colleague's own AI Hub token to fetch their
// usage; the first run is the only moment the app ever asks for anything.
// WP-03: error copy is settable per outcome (Keychain failure vs gateway
// rejection vs network), and the field/error state CLEARS on success and on
// cancel (03.2). Cancel clears secure text before notifying, so a dismissed
// panel never retains the pasted token in its field.
// RELEVANT FILES: Sources/App/CredentialController.swift, Sources/App/KeychainStore.swift,
// Sources/App/PopoverPanel.swift, Sources/App/main.swift

import Cocoa

@MainActor
public final class FirstRunView: NSView {
    /// Called with the trimmed token when the user saves. The caller returns
    /// false when the save path failed (Keychain write or gateway rejection
    /// surfaced via `setErrorMessage`) so the view can show the honest error.
    public var onSave: ((String) -> Bool)?

    /// Called when the user cancels (relevant when a token already exists —
    /// e.g. the "replace token" flow — so they can back out to the normal view).
    public var onCancel: (() -> Void)?

    /// Optional lead-in line ("Paste your AI Hub token to begin." by default;
    /// "Token rejected — paste a fresh one." after a 401).
    public var promptText: String = "Paste your AI Hub token to begin." {
        didSet { promptLabel?.stringValue = promptText }
    }

    /// Whether to show the Cancel button (false on true first run).
    public var showsCancel: Bool = false {
        didSet { cancelButton?.isHidden = !showsCancel }
    }

    private weak var promptLabel: NSTextField?
    private weak var cancelButton: NSButton?
    private weak var field: NSSecureTextField?
    private weak var errorLabel: NSTextField?

    public init() {
        // 156pt: the Keychain note wraps to two lines (see below), so the
        // card grows from 132 to keep the bottom margin under the note.
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 156))
        wantsLayer = true

        let prompt = NSTextField(labelWithString: promptText)
        prompt.font = NSFont.systemFont(ofSize: 13)
        prompt.textColor = .labelColor
        prompt.frame = NSRect(x: 18, y: 156 - 22, width: 284, height: 17)
        addSubview(prompt)
        promptLabel = prompt

        let tokenField = NSSecureTextField(frame: NSRect(x: 18, y: 156 - 56, width: 284, height: 26))
        tokenField.placeholderString = "gt_…"
        tokenField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        // WP-10 10.2: the secure field announces its purpose and never
        // echoes the typed/pasted secret.
        tokenField.setAccessibilityLabel("AI Hub token")
        tokenField.setAccessibilityHelp("Paste your AI Hub token. It is stored in your Keychain and never displayed.")
        addSubview(tokenField)
        field = tokenField

        // FirstMouseButton: a plain NSButton returns false from
        // acceptsFirstMouse, so the very first click on this panel (app
        // still inactive) only ACTIVATES the window and never reaches the
        // button — the user had to click the field (which DOES accept first
        // mouse) before Cancel responded. Accepting first mouse makes the
        // first click both activate AND click, matching user expectation.
        let save = FirstMouseButton(frame: NSRect(x: 18, y: 156 - 94, width: 68, height: 26))
        save.title = "Save"
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"   // Return saves — the whole flow is two keystrokes.
        save.target = self
        save.action = #selector(saveTapped)
        save.setAccessibilityLabel("Save token")
        addSubview(save)

        let cancel = FirstMouseButton(frame: NSRect(x: 94, y: 156 - 94, width: 68, height: 26))
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"   // Escape cancels.
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        cancel.isHidden = !showsCancel
        addSubview(cancel)
        cancelButton = cancel

        // The error line sits on its OWN row, BELOW the buttons — never beside
        // them. (Historical z-order overlap fix retained: see git blame.)
        let error = NSTextField(labelWithString: "")
        error.font = NSFont.systemFont(ofSize: 11)
        error.textColor = .systemRed
        error.lineBreakMode = .byTruncatingTail
        error.maximumNumberOfLines = 1
        error.frame = NSRect(x: 18, y: 156 - 112, width: 284, height: 14)
        addSubview(error)
        errorLabel = error

        // Explainer, quiet — says exactly where the token lives. Wraps to
        // two lines instead of hard-clipping mid-sentence.
        let note = NSTextField(wrappingLabelWithString: "Stored in your Keychain, never leaves this Mac except to the AI Hub gateway.")
        note.font = NSFont.systemFont(ofSize: 10.5)
        note.textColor = .labelColor.withAlphaComponent(0.42)
        note.maximumNumberOfLines = 2
        note.frame = NSRect(x: 18, y: 8, width: 284, height: 28)
        addSubview(note)
    }

    public required init?(coder: NSCoder) {
        fatalError("FirstRunView does not support NSCoder-based initialization")
    }

    /// Test support (WP-10): expose the secure field so the accessibility
    /// suite can verify the secret is never spoken. Not used by production
    /// flows — they go through focusField()/clearSecretEntry().
    var tokenFieldForTesting: NSSecureTextField? { field }

    /// Test support: focus without a live keyboard flow.
    func focusFieldForTesting() {
        window?.makeFirstResponder(field)
    }

    /// Focus the token field — called by the panel right after show().
    public func focusField() {
        window?.makeFirstResponder(field)
    }

    /// Sets the honest error line. Used by the save pipeline for outcomes
    /// beyond the plain Keychain-write failure (gateway rejection,
    /// network-unavailable validation), so each failure class explains
    /// itself (03.2).
    public func setErrorMessage(_ message: String?) {
        errorLabel?.stringValue = message ?? ""
    }

    /// Clears the secure field and any error text. Called on success and on
    /// cancel so neither the token nor a stale error outlives the flow
    /// (03.2). The token never remains in a dismissed panel's field.
    public func clearSecretEntry() {
        field?.stringValue = ""
        errorLabel?.stringValue = ""
    }

    @objc private func cancelTapped() {
        clearSecretEntry()
        onCancel?()
    }

    @objc private func saveTapped() {
        let token = (field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        if onSave?(token) == false {
            // The caller decides the copy when it knows the failure class;
            // the default here covers the plain Keychain-write failure.
            errorLabel?.stringValue = "Couldn't save to Keychain."
        } else {
            clearSecretEntry()
        }
    }
}

/// An NSButton that answers the click that ACTIVATES the window.
/// AppKit's default is the opposite: the first click on an inactive app's
/// window is consumed as pure activation ("click-through" is disabled), so
/// one click did nothing and only the SECOND click fired — exactly the
/// dead-Cancel report. The token field doesn't show this because
/// NSSecureTextField accepts first mouse on its own.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
