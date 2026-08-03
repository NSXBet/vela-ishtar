// Sources/App/main.swift
// Application entry point: boots the menu bar app and wires the polling
// pipeline (gateway → UsagePoller → StatusItemController) together.
// Why: bare swiftc has no @main attribute resolution across mixed targets,
// so the NSApplication bootstrap is explicit here. The popover click
// handler lands in the next task; for now the pill is live and clickable.
// RELEVANT FILES: Sources/App/StatusItemController.swift, Sources/App/UsagePoller.swift, Sources/App/AIHubClient.swift, Sources/VelaCore/PollStateMachine.swift

import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var poller: UsagePoller?
    private var statusItem: StatusItemController?

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
        controller.onClick = {
            // Popover wiring lands with the popover task; the click proves
            // the status item is alive until then.
            print("Vela Ishtar: status item clicked")
        }

        poller.onState = { [weak controller, weak poller] state in
            guard let controller, let poller else { return }
            controller.render(state: state, burnBuffer: poller.machine.burnBuffer)
        }

        poller.start()
        self.poller = poller
        self.statusItem = controller
    }
}

let app = NSApplication.shared
// Belt-and-braces with LSUIElement in Info.plist: no Dock icon, no menu bar menus.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
