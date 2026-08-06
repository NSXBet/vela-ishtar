// Sources/App/PopoverPanel.swift
// A borderless, nonactivating floating panel anchored under the status
// item, hosting the popover's content view with system vibrancy.
// Why: the popover is where the detail lives -- anchoring under the pill
// and dismissing on outside click must feel exactly like a native
// NSStatusItem popover, even though we're not using NSPopover itself
// (NSPopover forces activation on show, which steals focus from
// whatever app the user was in; a raw NSPanel does not).
// RELEVANT FILES: Sources/App/StatusItemController.swift, Sources/App/PopoverView.swift, Sources/App/main.swift

import Cocoa
import QuartzCore

/// Owns the floating panel window: vibrancy background, anchored
/// positioning under the status item button, open animation, and
/// outside-click dismissal. Task 12+ (PopoverView) only touches the
/// public surface below -- init(contentView:), show(relativeTo:),
/// dismiss(), isShown.
@MainActor
public final class PopoverPanel: NSPanel {
    /// Fixed panel size, taken from the content view at init time. The
    /// panel doesn't resize itself later -- content that needs a
    /// different size gets a new PopoverPanel.
    private let panelSize: NSSize

    /// The status item button that anchored the panel on the most recent
    /// show() call. Local outside-click monitoring ignores clicks on this
    /// button's window so a re-click of the pill is handled by
    /// StatusItemController.onClick's own toggle, not by us dismissing
    /// out from under it first.
    private weak var anchorButton: NSStatusBarButton?

    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    public init(contentView: NSView) {
        panelSize = contentView.frame.size

        // Vibrancy background: .popover material is the exact system look
        // for a status-item popover (frosted, adapts to light/dark).
        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effectView.material = .popover
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        super.init(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // canBecomeKey=true (below) must not turn the NORMAL popover into
        // a keyboard window: with the default (false), clicking ordinary
        // content could make the panel key and steal typing from the
        // user's real app. true = only views that need keys (text fields)
        // pull key status; the token flow's explicit makeKey() is
        // unaffected -- programmatic makeKey works regardless.
        becomesKeyOnlyIfNeeded = true
        // The panel is reused across show/dismiss cycles (see AppDelegate's
        // lazy instantiation) -- it must survive orderOut(), not deallocate.
        isReleasedWhenClosed = false

        self.contentView = effectView

        // The caller's content view is pinned edge-to-edge inside the
        // vibrant background via Auto Layout, so it tracks panelSize.
        contentView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: effectView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])
    }

    public required init?(coder: NSCoder) {
        fatalError("PopoverPanel does not support NSCoder-based initialization")
    }

    /// True while the panel is on-screen. NSPanel's own isVisible already
    /// tracks exactly this -- no separate flag to keep in sync.
    public var isShown: Bool { isVisible }

    /// Borderless panels default canBecomeKey to false, which would make
    /// keyboard input impossible (the token field could never receive
    /// ⌘V or typed text reliably). We allow becoming key; the normal
    /// popover flow stays nonactivating and never exercises this.
    public override var canBecomeKey: Bool { true }

    /// Edit-menu key equivalents, handled at the WINDOW level.
    /// Why: this is an LSUIElement agent with no menu bar, so the normal
    /// dispatch path (key equivalent → main menu → paste:) has no menu to
    /// travel through -- ⌘V in the token field silently did nothing, and
    /// users fell back to right-click → Paste (first field report).
    /// NSApplication.sendEvent offers key equivalents to the key window
    /// first (which then searches its view hierarchy), so overriding here
    /// catches them deterministically -- even though the first responder
    /// in a text field is the shared field editor (NSTextView), not the
    /// field itself. We forward to the responder chain exactly like the
    /// Edit menu would.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Compare only the modifier bits we MEAN: deviceIndependentFlagsMask
        // also includes Caps Lock and fn, so an exact-mask comparison would
        // silently reject ⌘V whenever the user has Caps Lock on.
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // ⌘ alone, or ⌘⇧ for Redo. Anything else (⌘⌥…, ⌘⌃…) is not ours.
        guard mods == .command || mods == [.command, .shift],
              let chars = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }

        let action: Selector?
        switch chars {
        case "v": action = #selector(NSText.paste(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = mods.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default:  action = nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        // If nothing in the responder chain handles it (e.g. focus left
        // the token field), don't swallow the keystroke -- hand it back
        // to the standard path so ⌘V can never "succeed into the void"
        // and read as the exact bug this override exists to fix.
        if NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Show

    /// Positions the panel top-center under `button`'s bottom-center (4pt
    /// gap), then shows it with the open animation (or instantly, under
    /// Reduce Motion).
    public func show(relativeTo button: NSStatusBarButton?) {
        anchorButton = button
        let targetFrame = anchoredFrame(relativeTo: button)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Reduce Motion: no scale/fade, just appear in place.
            setFrame(targetFrame, display: false)
            alphaValue = 1
            orderFrontRegardless()
        } else {
            // Start scaled to 96% of the target size, anchored at the same
            // top-center point as the final frame, so the scale reads as
            // "growing from the pill" rather than growing from a corner.
            let anchor = CGPoint(x: targetFrame.midX, y: targetFrame.maxY)
            let startSize = NSSize(width: targetFrame.width * 0.96, height: targetFrame.height * 0.96)
            let startFrame = NSRect(
                x: anchor.x - startSize.width / 2,
                y: anchor.y - startSize.height,
                width: startSize.width,
                height: startSize.height
            )

            alphaValue = 0
            setFrame(startFrame, display: false)
            orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
                // NSWindow's animator proxy supports setFrame(_:display:)
                // directly -- this is what makes the "scale" part work.
                self.animator().setFrame(targetFrame, display: true)
            }
        }

        installClickMonitors()
    }

    /// Shows the panel as a KEYBOARD-OWNING window: activates the app and
    /// makes the panel key, so a text field inside gets typed input AND
    /// key equivalents. Used only by the token-entry flow -- a menu bar
    /// app must never steal activation just to show numbers, but asking
    /// for a credential is exactly the moment the user expects to type.
    public func showForKeyboardInput(relativeTo button: NSStatusBarButton?) {
        show(relativeTo: button)
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
    }

    /// Shows the panel centered on the screen that currently has keyboard
    /// focus (falls back to the main screen). Used at first launch, when
    /// there was no click and the status item's backing window may not
    /// have a realized frame yet -- anchoring under the pill in that
    /// moment can compute off a garbage origin and pin the panel to a
    /// corner (reported: token prompt appeared bottom-left).
    public func showCenteredForKeyboardInput() {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)
        let centered = NSRect(
            x: visible.midX - panelSize.width / 2,
            y: visible.midY - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
        setFrame(centered, display: false)
        alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        installClickMonitors()
    }

    /// Anchor frame is computed fresh on every show() from
    /// `button.window?.frame` -- that window (the status item's own
    /// backing window) only exists, and only has a meaningful frame,
    /// while the status item is actually on-screen. Caching it at init
    /// time or across calls would go stale the moment the user rearranges
    /// their menu bar.
    private func anchoredFrame(relativeTo button: NSStatusBarButton?) -> NSRect {
        let gap: CGFloat = 4

        guard let buttonWindow = button?.window else {
            // No button window (e.g. status item scrolled into the menu
            // bar's overflow chevron) -- fall back to the active screen's
            // top-right corner rather than crashing or anchoring at (0,0).
            let screen = NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: panelSize.width, height: panelSize.height)
            let fallback = NSRect(
                x: visible.maxX - panelSize.width - 8,
                y: visible.maxY - panelSize.height - 8,
                width: panelSize.width,
                height: panelSize.height
            )
            return clamp(fallback, to: screen)
        }

        let buttonFrame = buttonWindow.frame // already in screen coordinates
        let origin = CGPoint(
            x: buttonFrame.midX - panelSize.width / 2,
            y: buttonFrame.minY - gap - panelSize.height
        )
        let frame = NSRect(origin: origin, size: panelSize)
        return clamp(frame, to: buttonWindow.screen)
    }

    /// Keeps the panel fully within the screen's visible frame (menu bar
    /// / Dock excluded) so it never renders half off-screen near a
    /// display edge.
    private func clamp(_ frame: NSRect, to screen: NSScreen?) -> NSRect {
        guard let visible = screen?.visibleFrame else { return frame }
        var result = frame
        if result.maxX > visible.maxX { result.origin.x = visible.maxX - result.width }
        if result.minX < visible.minX { result.origin.x = visible.minX }
        if result.maxY > visible.maxY { result.origin.y = visible.maxY - result.height }
        if result.minY < visible.minY { result.origin.y = visible.minY }
        return result
    }

    // MARK: - Dismiss

    /// Hides the panel and tears down the outside-click monitors. A
    /// nonactivating panel never becomes key, so there's no
    /// windowDidResignKey to hook -- the click monitors below are the
    /// only dismissal signal.
    public func dismiss() {
        // Capture BEFORE orderOut: only a panel that actually held key
        // status (the token flow's keyboard-owning shows) should hand
        // activation back. A normal popover that never became key must
        // not deactivate an app it never activated.
        let wasKey = isKeyWindow
        removeClickMonitors()
        orderOut(nil)
        // If the token flow activated us (showForKeyboardInput /
        // showCenteredForKeyboardInput), hand activation back so the app
        // returns to being a quiet background agent -- an LSUIElement app
        // that stays "active" after its one keyboard moment is over is
        // exactly the kind of focus theft the nonactivating design avoids.
        if wasKey, NSApp.isActive {
            NSApp.deactivate()
        }
    }

    // MARK: - Outside-click monitors

    /// Two monitors are needed because NSEvent's global monitor only
    /// reports clicks in OTHER applications' windows; clicks inside our
    /// own app (including the status item button itself) need the local
    /// monitor. Either one firing on a genuine "outside" click dismisses.
    private func installClickMonitors() {
        removeClickMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Ignore clicks inside the panel itself (that's content
            // interaction) and clicks on the anchor button (its own
            // action already toggles show/dismiss) -- everything else
            // inside our app counts as "outside" and dismisses.
            if event.window === self || event.window === self.anchorButton?.window {
                return event
            }
            self.dismiss()
            return event
        }
    }

    private func removeClickMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }
}
