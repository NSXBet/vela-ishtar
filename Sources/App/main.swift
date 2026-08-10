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
    private var updateChecker: UpdateChecker?
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
        var machine = PollStateMachine()
        machine.loadHistory()   // restore persisted spend history before the first poll
        let client = AIHubClient(tokenProvider: keychain)
        let poller = UsagePoller(client: client, machine: machine)
        let controller = StatusItemController()

        controller.install()
        controller.onClick = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.hasUserClickedPill = true
            if let popover = self.popover, popover.isShown {
                popover.dismiss()
                return
            }
            self.openPopover(relativeTo: controller)
        }

        poller.onState = { [weak self, weak controller, weak poller] state in
            guard let self, let controller, let poller else { return }
            controller.render(state: state, burnBuffer: poller.machine.burnBuffer)
            // Persist on success — the curve and exhaustedAt survive relaunch.
            if case .fresh = state { poller.machine.saveHistory() }
            // An open popover is a live view, not a snapshot: refresh it on
            // every poll so the health dot, timestamp, and banner stay true.
            // This also covers the loading state (state was .neverFetched):
            // the same PopoverView shrinks to content height once, in place.
            //
            // v0.3.4: while still .neverFetched, DON'T rebuild. A failed
            // first poll keeps the state .neverFetched, and update()'s
            // loading branch would wipe the rehydrated cold-open view for a
            // spinner positioned for a 480pt panel — clipped on the short
            // panel the cold-open path opens. renderLoadingState already
            // rendered the right thing (cached reading dimmed, or the honest
            // spinner); leave it up until real data (.fresh / .stale) lands.
            if case .neverFetched = state { return }
            if let panel = self.popover, panel.isShown, let view = self.popoverView {
                view.update(state: state, history: poller.machine.history,
                            exhaustedAt: poller.machine.exhaustedAt,
                            lastSuccessAt: poller.machine.lastSuccessAt, now: Date(),
                            todayModelSplit: poller.machine.todayModelSplit)
            }
        }

        // A rejected token re-opens the token flow with an explanation —
        // a revoked credential must have a visible fix, not a forever-amber pill.
        poller.onUnauthorized = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.openPopover(relativeTo: controller, firstRunPrompt: "Token rejected — paste a fresh one.")
        }

        // After sleep, poll immediately instead of showing up-to-60s-old
        // data with a confident green dot.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak poller] _ in
            Task { @MainActor in poller?.pollNow() }
        }

        poller.start()
        self.poller = poller
        self.statusItem = controller

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
        poller?.machine.saveHistory()
    }

    /// Re-renders the popover if it's currently open, from the poller's
    /// latest state. Used by the update checker when the bell's state
    /// changes mid-session (a fetch landed, or the user skipped a version).
    private func refreshOpenPopover() {
        guard let poller, let panel = popover, panel.isShown, let view = popoverView else { return }
        view.update(state: poller.machine.state, history: poller.machine.history,
                    exhaustedAt: poller.machine.exhaustedAt,
                    lastSuccessAt: poller.machine.lastSuccessAt, now: Date(),
                    todayModelSplit: poller.machine.todayModelSplit)
    }

    /// Builds (once) and shows the popover under the status item. When
    /// `firstRunPrompt` is set — or no token exists — the content is the
    /// token-entry view; otherwise the normal usage view.
    ///
    /// `pollOnOpen` is false only on the Cancel path out of the token flow:
    /// polling there re-fires the dead token and the resulting 401 re-opens
    /// the prompt the user just dismissed (see onCancel).
    private func openPopover(relativeTo controller: StatusItemController, firstRunPrompt: String? = nil, pollOnOpen: Bool = true) {
        guard let poller else { return }

        // Re-check for a newer release each time the popover opens (v1.0.2).
        // checkIfDue is throttle-guarded (6h), so this is at most one GitHub
        // request per throttle window even if the user opens the popover all day.
        // Runs before any branch so a long-lived menu-bar app — which may stay
        // running for weeks between restarts — still lights the bell when a new
        // release ships mid-session. The launch check alone (below) only fires on
        // process restart.
        updateChecker?.checkIfDue()

        let needsToken = keychain.read() == nil || firstRunPrompt != nil

        // Fresh data on demand — but NOT in the first-run/unauthorized path:
        // with a dead token that's a guaranteed-failing extra request.
        if !needsToken, pollOnOpen {
            poller.pollNow()
        }

        // Still waiting for the first poll — show the loading state in the
        // REAL PopoverView (fixed 320x480), not a throwaway panel. When the
        // first state lands, onState updates this same view in place and it
        // shrinks to content height exactly once — no hero jump, no panel swap.
        if case .neverFetched = poller.machine.state, !needsToken {
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
            // Cold-open fix (v0.3.4): pass the loaded history + now so the
            // loading view can show today's last reading dimmed instead of a
            // blank spinner for the 0.5–1s the first fetch takes.
            view.renderLoadingState(history: poller.machine.history, now: Date())
            let panel = PopoverPanel(contentView: view)
            self.popover = panel
            panel.show(relativeTo: controller.button)
            return
        }

        if needsToken {
            let view = self.firstRunView ?? FirstRunView()
            self.firstRunView = view
            // Re-arm the unauthorized latch on entry: if the user closes this
            // panel WITHOUT saving (Cancel or outside-click), a still-dead
            // token must re-prompt on the next 401 — not fail silently. A
            // successful save leads to a poll that re-latches on failure, so
            // resetting here is safe in every path.
            poller.resetUnauthorizedNotification()
            if let firstRunPrompt { view.promptText = firstRunPrompt }
            // Cancel makes sense only when a token already exists (the
            // "replace token" flow) — on true first run there's nothing to
            // go back to, so the button stays hidden.
            view.showsCancel = self.keychain.read() != nil
            view.onCancel = { [weak self, weak controller, weak poller] in
                guard let self, let controller else { return }
                // User backed out of the recovery flow without saving — the
                // token is still dead, so re-arm the notification: the next
                // 401 re-opens the prompt instead of failing silently forever.
                poller?.resetUnauthorizedNotification()
                self.popover?.dismiss()
                self.popover = nil
                // ...but do NOT poll on the way out. Re-arming the latch and
                // then immediately firing a request with the same dead token
                // guarantees a 401 within a few hundred ms, which re-opens
                // this very panel — Cancel appeared to do nothing at all. The
                // 60s timer still polls, still 401s, and still re-prompts, so
                // the forever-amber guard is intact; it just no longer bounces
                // the user straight back into the prompt they dismissed.
                self.openPopover(relativeTo: controller, pollOnOpen: false)
            }
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
        // Pre-layout BEFORE the panel exists: update() sizes the view to
        // its content, so the panel is born at the right height — no visible
        // jump from the initial 480pt frame down to content.
        view.update(state: poller.machine.state, history: poller.machine.history,
                    exhaustedAt: poller.machine.exhaustedAt,
                    lastSuccessAt: poller.machine.lastSuccessAt, now: Date(),
                    todayModelSplit: poller.machine.todayModelSplit)
        let panel = self.popover ?? PopoverPanel(contentView: view)
        self.popover = panel
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
