// Sources/App/main.swift
// Application entry point (WP-06 06.1): boots the v2 pipeline —
// AppCoordinator → (CredentialController + PollCoordinator + HistoryRepository)
// → StatusItemController → PopoverPanel — including the first-run token
// flow and unauthorized recovery. The legacy UsagePoller/PollStateMachine
// live path is retired; AppCoordinator is the single state source and
// routes every committed snapshot through credentials.scope (the
// BASELINE.md mandatory gate).
// Why: bare swiftc has no @main attribute resolution across mixed targets,
// so the NSApplication bootstrap is explicit here. AppDelegate is now thin:
// it owns windows/clicks and delegates ALL data state to the coordinator.
// RELEVANT FILES: Sources/App/AppCoordinator.swift, Sources/App/StatusItemController.swift,
// Sources/App/PopoverPanel.swift, Sources/App/PopoverView.swift, Sources/App/FirstRunView.swift

import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var statusItem: StatusItemController?
    private var popover: PopoverPanel?
    private var popoverView: PopoverView?
    private var firstRunView: FirstRunView?
    private var updateChecker: UpdateChecker?
    /// WP-12: WP-09's local history explorer window (F02/F03 surface).
    private var historyExplorer: HistoryWindowController?
    private let keychain = KeychainStore()

    /// True once the user has clicked the status item at least once. The
    /// first-launch token prompt happens BEFORE any click, when the status
    /// item's backing window may not have a realized frame yet -- anchoring
    /// under the pill in that moment can pin the panel to a screen corner
    /// (reported: token prompt appeared bottom-left), so that one show is
    /// centered on screen instead.
    private var hasUserClickedPill = false

    /// Explicit nonisolated init: the top-level bootstrap below is
    /// nonisolated, so the delegate must be constructible from there;
    /// its methods stay @MainActor via the class annotation.
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let client = AIHubClient()
        let coordinator = AppCoordinator(
            transport: client,
            store: keychain,
            repository: HistoryRepository(directory: HistoryStore.defaultDirectory)
        )
        self.coordinator = coordinator

        let controller = StatusItemController()
        controller.install()
        self.statusItem = controller

        controller.onClick = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.hasUserClickedPill = true
            if let popover = self.popover, popover.isShown {
                popover.dismiss()
                return
            }
            self.openPopover(relativeTo: controller)
        }

        // WP-12: WP-09's local history explorer (day view, markers, CSV
        // export) — lazily created inside the controller on first open.
        let historyExplorer = HistoryWindowController(repository: coordinator.repository)
        self.historyExplorer = historyExplorer
        controller.onOpenHistoryExplorer = { [weak historyExplorer] in
            Task { @MainActor in await historyExplorer?.open() }
        }

        // The ONE observation point: every committed outcome lands here,
        // already routed through credentials.scope by the coordinator.
        coordinator.onUpdate = { [weak self, weak controller] update in
            guard let self, let controller else { return }
            if let buffer = self.coordinator?.burnBuffer {
                controller.render(connection: update.connection, burnBuffer: buffer, response: update.lastGoodResponse)
            }
            // An open popover is a live view: apply the new display state
            // in place (no section rebuild for unchanged sections).
            if let panel = self.popover, panel.isShown, let view = self.popoverView {
                view.apply(displayState: update.displayState, connection: update.connection,
                           response: update.lastGoodResponse, receivedAt: update.lastGoodReceivedAt)
            }
            // A rejected token re-opens the token flow with an explanation —
            // once per failure episode (03.3), never every 60s tick.
            if update.authJustRequired {
                self.openPopover(relativeTo: controller, firstRunPrompt: "Token rejected — paste a fresh one.")
            }
            // Persist on success — the curve and exhaustedAt survive relaunch.
            if case .live = update.connection {
                Task { [repository = self.coordinator?.repository] in
                    try? await repository?.save()
                }
            }
        }

        // Unauthorized recovery: authJustRequired (ONCE per failure episode,
        // 03.3) re-opens the token flow. Delivered through onUpdate below.
        // After sleep, poll immediately instead of showing up-to-60s-old
        // data with a confident green dot.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak coordinator] _ in
            Task { @MainActor in coordinator?.refresh(reason: .wake) }
        }

        Task { @MainActor in
            await coordinator.start()
        }

        // Update bell (v0.5.2): one checker for the app's lifetime. The
        // launch check runs while the popover is closed, so by the time the
        // user opens it the bell's state is already known — no network wait
        // on the UI path. When a fetch (or a skip) changes the state, an
        // open popover re-renders through the same path polls use.
        let runningVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let checker = UpdateChecker(runningVersion: runningVersion)
        checker.onChange = { [weak self] in
            self?.refreshOpenPopover()
        }
        self.updateChecker = checker
        checker.checkIfDue()

        // First run: no token saved yet — open the token flow at launch so
        // the app's one question gets answered immediately.
        if keychain.read() == nil {
            openPopover(relativeTo: controller)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        let repository = coordinator?.repository
        Task {
            try? await repository?.save()
        }
    }

    /// Re-renders the popover if it's currently open, from committed state.
    /// Used by the update checker when the bell's state changes mid-session.
    private func refreshOpenPopover() {
        guard let coordinator, let panel = popover, panel.isShown, let view = popoverView,
              let last = coordinator.lastSnapshot ?? nil else { return }
        view.apply(displayState: nil, connection: coordinator.polls.connection,
                   response: last.response, receivedAt: last.receivedAt)
    }

    /// Builds (once) and shows the popover under the status item. When
    /// `firstRunPrompt` is set — or no token exists — the content is the
    /// token-entry view; otherwise the normal usage view.
    ///
    /// `pollOnOpen` is false only on the Cancel path out of the token flow:
    /// polling there re-fires the dead token and the resulting 401 re-opens
    /// the prompt the user just dismissed (see onCancel).
    private func openPopover(relativeTo controller: StatusItemController, firstRunPrompt: String? = nil, pollOnOpen: Bool = true) {
        guard let coordinator else { return }

        // Re-check for a newer release each time the popover opens (v1.0.2).
        // checkIfDue is throttle-guarded (6h), so this is at most one GitHub
        // request per throttle window even if the user opens the popover all day.
        updateChecker?.checkIfDue()

        let needsToken = keychain.read() == nil || firstRunPrompt != nil

        // Fresh data on demand — but NOT in the first-run/unauthorized path:
        // with a dead token that's a guaranteed-failing extra request.
        if !needsToken, pollOnOpen {
            coordinator.refresh(reason: .opened)
        }

        // Loading state: still waiting for the first commit — show it in the
        // REAL PopoverView (fixed 320x480), not a throwaway panel. When the
        // first state lands, onUpdate applies the display state to this same
        // view in place — no panel swap.
        if coordinator.lastGoodResponse == nil, !needsToken {
            let view = self.popoverView ?? PopoverView()
            self.popoverView = view
            view.updateChecker = updateChecker
            view.onRequestDismiss = { [weak self] in self?.popover?.dismiss() }
            view.onReplaceToken = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.popover?.dismiss()
                self.popover = nil
                self.openPopover(relativeTo: controller, firstRunPrompt: "Paste your new AI Hub token.")
            }
            view.onOpenHistoryExplorer = { [weak self] in
                Task { @MainActor in await self?.historyExplorer?.open() }
            }
            view.renderLoadingState(now: Date())
            let panel = PopoverPanel(contentView: view)
            self.popover = panel
            panel.show(relativeTo: controller.button)
            return
        }

        if needsToken {
            let view = self.firstRunView ?? FirstRunView()
            self.firstRunView = view
            view.promptText = firstRunPrompt ?? "Paste your AI Hub token to begin."
            // Cancel makes sense only when a token already exists (the
            // "replace token" flow) — on true first run there's nothing to
            // go back to, so the button stays hidden.
            view.showsCancel = self.keychain.read() != nil
            view.onCancel = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.popover?.dismiss()
                self.popover = nil
                // Do NOT poll on the way out: re-firing a dead token just
                // 401s and re-opens the prompt the user dismissed. The next
                // scheduled tick (or any user action) re-arms the flow.
                self.openPopover(relativeTo: controller, pollOnOpen: false)
            }
            view.onSave = { [weak self] token in
                guard let self, let coordinator = self.coordinator else { return false }
                view.setErrorMessage("Validating token with AI Hub…")
                Task { @MainActor in
                    // Transactional replacement: the controller validates
                    // the candidate against the gateway BEFORE the Keychain
                    // write. The button IS the wait; the error line carries
                    // progress and every failure class.
                    let result = await coordinator.credentials.replaceToken(token)
                    switch result {
                    case .accepted:
                        view.setErrorMessage(nil)
                        view.clearSecretEntry()
                        await coordinator.credentialChanged()
                        self.popover?.dismiss()
                        self.popover = nil
                        if let controller = self.statusItem {
                            self.openPopover(relativeTo: controller)
                        }
                    case .rejected(let failure):
                        view.setErrorMessage(Self.rejectionText(failure))
                    case .storageFailed:
                        view.setErrorMessage("Couldn't save to Keychain.")
                    case .alreadyInProgress:
                        break
                    }
                }
                return true
            }
            let panel = PopoverPanel(contentView: view)
            self.popover = panel
            view.onSave = { [weak self] token in
                guard let self, let coordinator = self.coordinator else { return false }
                var saveResult = CredentialReplacementResult.alreadyInProgress
                let group = DispatchGroup()
                group.enter()
                Task { @MainActor in
                    // Transactional replacement: the controller validates
                    // the candidate against the gateway BEFORE the Keychain
                    // write. The save button IS the wait; FirstRunView keeps
                    // showing the typed card until this returns.
                    let result = await coordinator.credentials.replaceToken(token)
                    saveResult = result
                    group.leave()
                }
                group.wait()
                switch saveResult {
                case .accepted:
                    Task { @MainActor in
                        await coordinator.credentialChanged()
                    }
                    self.popover?.dismiss()
                    self.popover = nil
                    if let controller = self.statusItem {
                        self.openPopover(relativeTo: controller)
                    }
                    return true
                case .rejected(let failure):
                    view.setErrorMessage(Self.rejectionText(failure))
                    return false
                case .storageFailed:
                    view.setErrorMessage("Couldn't save to Keychain.")
                    return false
                case .alreadyInProgress:
                    return false
                }
            }
            // Token entry needs REAL keyboard ownership: activate the app
            // and make the panel key, otherwise ⌘V has no menu to travel
            // through and typing goes nowhere. Pre-first-click (launch,
            // or a 401 before any click) the pill's backing window may
            // not have a real frame yet -- center on screen instead of
            // anchoring into a corner.
            if hasUserClickedPill {
                panel.showForKeyboardInput(relativeTo: controller.button)
            } else {
                panel.showCenteredForKeyboardInput()
            }
            view.focusField()
            return
        }

        let view = self.popoverView ?? PopoverView()
        self.popoverView = view
        view.updateChecker = updateChecker
        view.onRequestDismiss = { [weak self] in self?.popover?.dismiss() }
        // "API key" swaps the popover into token-entry mode so a rotated
        // token can be pasted — the token itself never touches this view.
        view.onReplaceToken = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.popover?.dismiss()
            self.popover = nil
            self.openPopover(relativeTo: controller, firstRunPrompt: "Paste your new AI Hub token.")
        }
        // WP-12: the settings export row opens the history explorer.
        view.onOpenHistoryExplorer = { [weak self] in
            Task { @MainActor in await self?.historyExplorer?.open() }
        }
        // Pre-layout BEFORE the panel exists: update() sizes the view to
        // its content, so the panel is born at the right height — no visible
        // jump from the initial 480pt frame down to content.
        view.apply(displayState: coordinator.latestDisplayState,
                   connection: coordinator.polls.connection,
                   response: coordinator.lastGoodResponse,
                   receivedAt: coordinator.lastGoodReceivedAt)
        let panel = self.popover ?? PopoverPanel(contentView: view)
        self.popover = panel
        panel.show(relativeTo: controller.button)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.animateCurveDrawOn()
        }
    }

    private static func rejectionText(_ failure: CredentialValidationFailure) -> String {
        switch failure {
        case .unauthorized: return "Token rejected by AI Hub."
        case .badStatus(let code): return "AI Hub returned status \(code)."
        case .network: return "Couldn't reach AI Hub to validate the token."
        case .decode: return "AI Hub sent an unreadable response."
        }
    }
}

let app = NSApplication.shared
// Belt-and-braces with LSUIElement in Info.plist: no Dock icon, no menu bar menus.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
