// Sources/App/SecondaryPanelCoordinator.swift
// WP-07 07.4: one consistent native treatment + navigation seam for the
// summary's secondary surfaces — budget detail (WP-08 ships its content
// through this seam), connection detail, settings, and update info.
// Why: B10's source-confirmed rebuild churn also killed ancillary cards —
// a poll could close an open detail. This coordinator OWNS the child panel
// for the popover's lifetime: open state survives polls, Escape and an
// outside click dismiss, and the surface re-shows in place when content
// changes. Heavy history content stays lazy (the history window is WP-09's,
// reached through the same seam).
// RELEVANT FILES: Sources/App/PopoverPanel.swift, Sources/App/PopoverView.swift,
// Sources/App/UpdateBellView.swift, docs/v2/DESIGN.md §4 (secondary navigation)

import AppKit

@MainActor
public final class SecondaryPanelCoordinator: NSObject {

    /// Which secondary surface is open (at most one at a time — one
    /// consistent treatment, not a stack of orphan cards).
    public enum Surface: Equatable {
        case budgetDetail
        case connectionDetail
        case settings
        case updateInfo
    }

    /// Fired when the surface should close for app-level reasons (the
    /// update card's actions dismiss the whole popover).
    public var onRequestDismiss: (() -> Void)?

    private var panel: NSPanel?
    private(set) var openSurface: Surface?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Open / close

    /// Shows (or replaces) the secondary panel hosting `contentView` for
    /// `surface`. Anchor: near the popover's top edge, nonactivating — the
    /// popover stays on screen underneath.
    public func show(surface: Surface, contentView: NSView, relativeTo parent: NSWindow) {
        closePanel(keepSurface: surface)

        let size = contentView.frame.size
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = VelaDesign.Material.summaryEffect
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            effect.material = .titlebar // opaque fallback per DESIGN.md §3
        }
        contentView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: effect.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        // One level above the popover — the same band the update/version
        // cards occupy, so the whole secondary layer reads as one system.
        newPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        newPanel.hasShadow = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.contentView = effect
        newPanel.setAccessibilityElement(true)
        newPanel.setAccessibilityLabel(Self.accessibilityLabel(for: surface))

        parent.addChildWindow(newPanel, ordered: .above)
        // Anchor to the RIGHT edge of the popover — secondary surfaces sit
        // beside the main card, not over it (user preference).
        let frame = newPanel.frame
        newPanel.setFrameOrigin(NSPoint(
            x: parent.frame.maxX + 8,
            y: parent.frame.maxY - frame.height - 12
        ))
        clampToScreen(newPanel)
        newPanel.orderFront(nil)

        panel = newPanel
        openSurface = surface
    }

    /// Toggles: an open surface re-requested closes it.
    public func toggle(surface: Surface, contentView: NSView, relativeTo parent: NSWindow) {
        if openSurface == surface {
            close()
        } else {
            show(surface: surface, contentView: contentView, relativeTo: parent)
        }
    }

    /// Closes the panel if it shows `surface`; other surfaces stay open.
    /// Polls call this with every surface — a poll NEVER closes an open
    /// detail (B10).
    public func closeIfShowing(_ surface: Surface) {
        if openSurface == surface { close() }
    }

    public func close() {
        closePanel(keepSurface: nil)
    }

    private func closePanel(keepSurface: Surface?) {
        guard let existing = panel else {
            openSurface = keepSurface
            return
        }
        existing.parent?.removeChildWindow(existing)
        existing.orderOut(nil)
        panel = nil
        openSurface = keepSurface
    }

    private func clampToScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var origin = window.frame.origin
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - window.frame.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - window.frame.height - 4)
        window.setFrameOrigin(origin)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === panel else { return }
        panel = nil
        openSurface = nil
    }

    private static func accessibilityLabel(for surface: Surface) -> String {
        switch surface {
        case .budgetDetail: return "Budget detail"
        case .connectionDetail: return "Connection detail"
        case .settings: return "Settings"
        case .updateInfo: return "Update information"
        }
    }
}
