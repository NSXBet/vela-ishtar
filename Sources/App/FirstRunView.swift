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

    /// Optional lead-in line ("Paste your AI Hub token to begin." by default;
    /// "Token rejected — paste a fresh one." after a 401).
    public var promptText: String = "Paste your AI Hub token to begin." {
        didSet { promptLabel?.stringValue = promptText }
    }

    private weak var promptLabel: NSTextField?
    private weak var field: NSSecureTextField?
    private weak var errorLabel: NSTextField?

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 132))
        wantsLayer = true

        let prompt = NSTextField(labelWithString: promptText)
        prompt.font = NSFont.systemFont(ofSize: 13)
        prompt.textColor = .labelColor
        prompt.frame = NSRect(x: 18, y: 132 - 22, width: 284, height: 17)
        addSubview(prompt)
        promptLabel = prompt

        let tokenField = NSSecureTextField(frame: NSRect(x: 18, y: 132 - 56, width: 284, height: 26))
        tokenField.placeholderString = "gt_…"
        tokenField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        addSubview(tokenField)
        field = tokenField

        let save = NSButton(frame: NSRect(x: 18, y: 132 - 94, width: 68, height: 26))
        save.title = "Save"
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"   // Return saves — the whole flow is two keystrokes.
        save.target = self
        save.action = #selector(saveTapped)
        addSubview(save)

        let error = NSTextField(labelWithString: "")
        error.font = NSFont.systemFont(ofSize: 11)
        error.textColor = .systemRed
        error.frame = NSRect(x: 96, y: 132 - 88, width: 206, height: 14)
        addSubview(error)
        errorLabel = error

        // Explainer, quiet — says exactly where the token lives.
        let note = NSTextField(labelWithString: "Stored in your Keychain, never leaves this Mac except to the AI Hub gateway.")
        note.font = NSFont.systemFont(ofSize: 10.5)
        note.textColor = .labelColor.withAlphaComponent(0.42)
        note.frame = NSRect(x: 18, y: 10, width: 284, height: 13)
        addSubview(note)
    }

    public required init?(coder: NSCoder) {
        fatalError("FirstRunView does not support NSCoder-based initialization")
    }

    /// Focus the token field — called by the panel right after show().
    public func focusField() {
        window?.makeFirstResponder(field)
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
