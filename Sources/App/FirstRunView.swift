// Sources/App/FirstRunView.swift
// Token entry view shown on first launch (and when the gateway rejects the
// saved token): one secure field, one save button, one honest error line.
// Why: Vela Ishtar needs each colleague's own AI Hub token to fetch their
// usage; the first run is the only moment the app ever asks for anything.
// RELEVANT FILES: Sources/App/KeychainStore.swift, Sources/App/PopoverPanel.swift, Sources/App/main.swift

import Cocoa

@MainActor
public final class FirstRunView: NSView {
    /// Called with the trimmed token when the user saves. The caller decides
    /// what happens next (Keychain write + pollNow).
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
        // them. It used to be framed at (96, 68, 206, 14), which overlaps
        // Cancel's (94, 62, 68, 26) by a 66×14 rect straddling the button's
        // middle. An NSTextField is opaque to hit-testing even when its string
        // is empty and it draws nothing, and it was added AFTER Cancel, so it
        // sat on top in z-order: hitTest at Cancel's dead centre returned the
        // LABEL, and 55% of the button's area was dead. The click landed on an
        // invisible label, Cancel never saw a mouseDown, and the user "had to
        // click twice" — the second click usually strayed into one of the thin
        // live bands above or below the label. That reads exactly like a
        // first-mouse/activation bug, which is why activation fixes never
        // helped. Below the buttons there is nothing to overlap, and the row
        // is full-width so the 139pt message fits without clipping.
        let error = NSTextField(labelWithString: "")
        error.font = NSFont.systemFont(ofSize: 11)
        error.textColor = .systemRed
        error.lineBreakMode = .byTruncatingTail
        error.maximumNumberOfLines = 1
        error.frame = NSRect(x: 18, y: 156 - 112, width: 284, height: 14)
        addSubview(error)
        errorLabel = error

        // Explainer, quiet — says exactly where the token lives. 88 chars at
        // 10.5pt is ~430pt, past the 284pt field: wrap to two lines instead
        // of hard-clipping mid-sentence (the "…except to" report).
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

    /// Focus the token field — called by the panel right after show().
    public func focusField() {
        window?.makeFirstResponder(field)
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    @objc private func saveTapped() {
        let token = (field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        // The caller returns false when the Keychain write failed.
        if onSave?(token) == false {
            errorLabel?.stringValue = "Couldn't save to Keychain."
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
