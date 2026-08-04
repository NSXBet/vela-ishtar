// Sources/App/main.swift
// Application entry point: boots the menu bar app and wires the polling
// pipeline (gateway → UsagePoller → StatusItemController → PopoverPanel)
// together, including the first-run token flow and unauthorized recovery.
// Why: bare swiftc has no @main attribute resolution across mixed targets,
// so the NSApplication bootstrap is explicit here. The click handler
// toggles the popover panel; when no token exists yet (or the gateway
// rejects it), the popover opens in token-entry mode instead.
// RELEVANT FILES: Sources/App/StatusItemController.swift, Sources/App/PopoverPanel.swift, Sources/App/PopoverView.swift, Sources/App/FirstRunView.swift, Sources/App/UsagePoller.swift

import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: UsagePoller?
    private var statusItem: StatusItemController?
    private var popover: PopoverPanel?
    private var popoverView: PopoverView?
    private var firstRunView: FirstRunView?
    private let keychain = KeychainStore()

    /// Explicit nonisolated init: the top-level bootstrap below is
    /// nonisolated, so the delegate must be constructible from there;
    /// its methods stay @MainActor via the class annotation.
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let machine = PollStateMachine()
        let client = AIHubClient(tokenProvider: keychain)
        let poller = UsagePoller(client: client, machine: machine)
        let controller = StatusItemController()

        controller.install()
        controller.onClick = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if let popover = self.popover, popover.isShown {
                popover.dismiss()
                return
            }
            self.openPopover(relativeTo: controller)
        }

        poller.onState = { [weak controller, weak poller] state in
            guard let controller, let poller else { return }
            controller.render(state: state, burnBuffer: poller.machine.burnBuffer)
        }

        // A rejected token re-opens the token flow with an explanation —
        // a revoked credential must have a visible fix, not a forever-amber pill.
        poller.onUnauthorized = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.openPopover(relativeTo: controller, firstRunPrompt: "Token rejected — paste a fresh one.")
        }

        poller.start()
        self.poller = poller
        self.statusItem = controller

        // First run: no token saved yet — open the token flow at launch so
        // the app's one question gets answered immediately.
        if keychain.read() == nil {
            openPopover(relativeTo: controller)
        }
    }

    /// Builds (once) and shows the popover under the status item. When
    /// `firstRunPrompt` is set — or no token exists — the content is the
    /// token-entry view; otherwise the normal usage view.
    private func openPopover(relativeTo controller: StatusItemController, firstRunPrompt: String? = nil) {
        guard let poller else { return }

        // Fresh data on demand: opening the popover asks the gateway for a
        // new reading instead of waiting for the next 60s tick.
        poller.pollNow()

        let needsToken = keychain.read() == nil || firstRunPrompt != nil

        if needsToken {
            let view = self.firstRunView ?? FirstRunView()
            self.firstRunView = view
            if let firstRunPrompt { view.promptText = firstRunPrompt }
            view.onSave = { [weak self, weak poller] token in
                guard let self, let poller else { return false }
                guard self.keychain.write(token) else { return false }
                poller.pollNow()
                // Swap to the normal content immediately; the fresh state
                // lands on the next successful poll.
                self.popover?.dismiss()
                self.popover = nil
                if let controller = self.statusItem {
                    self.openPopover(relativeTo: controller)
                }
                return true
            }
            let panel = PopoverPanel(contentView: view)
            self.popover = panel
            panel.show(relativeTo: controller.button)
            view.focusField()
            return
        }

        let view = self.popoverView ?? PopoverView()
        self.popoverView = view
        let panel = self.popover ?? PopoverPanel(contentView: view)
        self.popover = panel
        view.update(state: poller.machine.state, history: poller.machine.history,
                    exhaustedAt: poller.machine.exhaustedAt,
                    lastSuccessAt: poller.machine.lastSuccessAt, now: Date())
        panel.show(relativeTo: controller.button)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.animateCurveDrawOn()
        }
    }
}

let app = NSApplication.shared
// Belt-and-braces with LSUIElement in Info.plist: no Dock icon, no menu bar menus.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
