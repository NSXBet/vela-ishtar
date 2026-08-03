// Sources/App/main.swift
// Application entry point: boots the menu bar app and wires the polling
// pipeline (gateway → UsagePoller → StatusItemController → PopoverPanel)
// together.
// Why: bare swiftc has no @main attribute resolution across mixed targets,
// so the NSApplication bootstrap is explicit here. The click handler
// toggles the popover panel; its real content (PopoverView) lands in the
// next task, so a plain placeholder view stands in for now.
// RELEVANT FILES: Sources/App/StatusItemController.swift, Sources/App/PopoverPanel.swift, Sources/App/UsagePoller.swift, Sources/App/AIHubClient.swift

import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: UsagePoller?
    private var statusItem: StatusItemController?
    private var popover: PopoverPanel?

    /// Explicit nonisolated init: the top-level bootstrap below is
    /// nonisolated, so the delegate must be constructible from there;
    /// its methods stay @MainActor via the class annotation.
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let machine = PollStateMachine()
        let client = AIHubClient(tokenProvider: KeychainStore())
        let poller = UsagePoller(client: client, machine: machine)
        let controller = StatusItemController()

        controller.install()
        controller.onClick = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if let popover = self.popover, popover.isShown {
                popover.dismiss()
                return
            }
            // Lazy instantiation: the panel (and its content view) is only
            // built on first click, so the app doesn't create any windows
            // at launch.
            let panel = self.popover ?? PopoverPanel(contentView: Self.makePlaceholderContentView())
            self.popover = panel
            panel.show(relativeTo: controller.button)
        }

        poller.onState = { [weak controller, weak poller] state in
            guard let controller, let poller else { return }
            controller.render(state: state, burnBuffer: poller.machine.burnBuffer)
        }

        poller.start()
        self.poller = poller
        self.statusItem = controller
    }

    /// Flat 320x480 placeholder, no styling -- replaced by PopoverView in
    /// the next task. Its only job right now is to give PopoverPanel a
    /// real, correctly-sized content view to anchor and animate.
    private static func makePlaceholderContentView() -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
    }
}

let app = NSApplication.shared
// Belt-and-braces with LSUIElement in Info.plist: no Dock icon, no menu bar menus.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
