// Sources/App/VersionBulletView.swift
// The top-right version bullet: a 6pt dot that shows the running version +
// what's-new list on hover. Why a custom tooltip: the popover is a borderless
// NON-activating NSPanel that never becomes key, and AppKit's native
// NSView.toolTip only resolves through the key window's event path — on this
// panel it never fires (the v0.3.2 report: hovering the dot showed nothing).
// So we draw the tip ourselves: a tracking area on the hit view toggles a
// small floating panel. Two hard-won details:
//   - .activeAlways on the tracking area (the panel never becomes key)
//   - tip window level ABOVE the popover's .statusBar, or it renders behind
// RELEVANT FILES: Sources/App/PopoverView.swift, Sources/App/PopoverPanel.swift

import Cocoa

@MainActor
public final class VersionBulletView: NSView {

    private let version: String
    private let notes: [(version: String, note: String)]
    private var trackingArea: NSTrackingArea?
    private var tipWindow: NSWindow?
    private var showWorkItem: DispatchWorkItem?

    public init(version: String, notes: [(version: String, note: String)]) {
        self.version = version
        self.notes = notes
        super.init(frame: .zero)

        let dotSize: CGFloat = 6
        let dot = NSView(frame: NSRect(x: (20 - dotSize) / 2, y: (20 - dotSize) / 2, width: dotSize, height: dotSize))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
        dot.layer?.cornerRadius = dotSize / 2
        addSubview(dot)

        // Build the spoken help from the SAME filtered list showTip() renders,
        // so VoiceOver and the visual tip never diverge (the running version's
        // own line is dropped from both).
        var lines = ["Changelog", "You're running v\(version)", ""]
        lines += WhatsNew.visibleNotes(running: version, notes: notes).map { "\($0.version) — \($0.note)" }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Vela Ishtar changelog")
        setAccessibilityHelp(lines.joined(separator: "\n"))
    }

    public required init?(coder: NSCoder) {
        fatalError("VersionBulletView does not support NSCoder-based initialization")
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .activeAlways: the panel never becomes key, so the default
        // active-when-key would never deliver entered/exited either.
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        // 400ms discoverability delay: instant reads as a UI glitch, the
        // native ~1s is too slow for a chrome affordance.
        showWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showTip() }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public override func mouseExited(with event: NSEvent) {
        showWorkItem?.cancel()
        hideTip()
    }

    public override func mouseDown(with event: NSEvent) {
        // A click under a floating panel shouldn't be swallowed silently.
        showWorkItem?.cancel()
        hideTip()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        // PopoverView rebuilds its hierarchy on every update; an open tip
        // must not outlive the bullet that spawned it.
        if newWindow == nil { hideTip() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func showTip() {
        guard tipWindow == nil, let parentWindow = window else { return }

        // Vibrancy card: "Changelog" title in semibold, a "You're running vX"
        // subtitle grounding the version, then the notes in regular secondary —
        // one typographic register below the popover's own copy. The running
        // version's own note line is filtered (the subtitle already says it).
        let width: CGFloat = 232
        let padding: CGFloat = 10
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let subtitleFont = NSFont.systemFont(ofSize: 11)
        let noteFont = NSFont.systemFont(ofSize: 11)

        let title = NSTextField(wrappingLabelWithString: "Changelog")
        title.font = titleFont
        title.textColor = .labelColor

        let subtitle = NSTextField(wrappingLabelWithString: "You're running v\(version)")
        subtitle.font = subtitleFont
        subtitle.textColor = .secondaryLabelColor

        let visibleNotes = WhatsNew.visibleNotes(running: version, notes: notes)
        let noteText = visibleNotes.map { "\($0.version) — \($0.note)" }.joined(separator: "\n")
        let notesLabel = NSTextField(wrappingLabelWithString: noteText)
        notesLabel.font = noteFont
        notesLabel.textColor = .secondaryLabelColor

        let titleSize = Self.measure(title.stringValue, font: titleFont, width: width - 2 * padding)
        let subtitleSize = Self.measure(subtitle.stringValue, font: subtitleFont, width: width - 2 * padding)
        let notesSize = Self.measure(noteText, font: noteFont, width: width - 2 * padding)
        let gap: CGFloat = 6
        let subtitleGap: CGFloat = 2
        let contentHeight = padding + titleSize.height + subtitleGap + subtitleSize.height + gap + notesSize.height + padding

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .popover
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 8
        blur.layer?.masksToBounds = true
        content.addSubview(blur)

        title.frame = NSRect(x: padding, y: contentHeight - padding - titleSize.height, width: width - 2 * padding, height: titleSize.height)
        subtitle.frame = NSRect(x: padding, y: title.frame.minY - subtitleGap - subtitleSize.height, width: width - 2 * padding, height: subtitleSize.height)
        notesLabel.frame = NSRect(x: padding, y: padding, width: width - 2 * padding, height: notesSize.height)
        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(notesLabel)

        let panel = NSPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = content
        panel.isFloatingPanel = true
        // Above the popover's .statusBar level, or the tip renders behind it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        // Placement: the card lives entirely OUTSIDE the popover, beside the
        // bullet — never over the hero numbers. Preferred side is the
        // popover's right; if the card wouldn't fit between the popover and
        // the screen's right edge it flips to the popover's LEFT (on a
        // right-anchored menu bar this is the common case, not the edge case).
        // x is deliberately NOT clamped into visibleFrame: the old clamp
        // (min(x, maxX - width - 4)) is exactly what drags an outside-right
        // card back over the popover. The side choice already guarantees
        // the card is fully on-screen.
        let sideGap: CGFloat = 8
        let dotOnScreen = parentWindow.convertToScreen(convert(bounds, to: nil))
        let popover = parentWindow.frame
        let visible = (parentWindow.screen ?? NSScreen.main)?.visibleFrame

        let rightX = popover.maxX + sideGap
        let leftX  = popover.minX - sideGap - width
        let originX: CGFloat
        if let visible {
            if rightX + width <= visible.maxX - 4 {
                originX = rightX
            } else if leftX >= visible.minX + 4 {
                originX = leftX
            } else {
                // Neither side fits (very narrow display): take the side with
                // more room and clamp there, accepting a partial overlap.
                let roomRight = visible.maxX - popover.maxX
                let roomLeft  = popover.minX - visible.minX
                originX = roomRight >= roomLeft
                    ? min(rightX, visible.maxX - width - 4)
                    : max(leftX, visible.minX + 4)
            }
        } else {
            originX = rightX
        }

        // Top-aligned with the bullet: a side tooltip, not a dropdown.
        var originY = dotOnScreen.maxY - content.frame.height
        if let visible {
            originY = min(max(originY, visible.minY + 4), visible.maxY - content.frame.height - 4)
        }
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        // Parented to the popover: dismiss() closes child windows in one pass
        // (PopoverPanel.swift), so the tip dies WITH the popover instead of
        // floating on as an orphan. hideTip() unparents.
        parentWindow.addChildWindow(panel, ordered: .above)

        // Motion: fade only (a sliding tip reads as a toast, not a tooltip).
        // 120ms in / 80ms out — the asymmetric, snappier exit is the premium
        // tell. Reduce Motion gets a hard cut.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.orderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        tipWindow = panel
    }

    private func hideTip() {
        guard let tip = tipWindow else { return }
        tipWindow = nil
        // Unparent as well as order out: the tip is a child window of the
        // popover (see showTip), and a stale child left in the list would be
        // re-torn-down by PopoverPanel.dismiss() against a panel we no longer
        // own.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            tip.parent?.removeChildWindow(tip)
            tip.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.08
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                tip.animator().alphaValue = 0
            }, completionHandler: {
                tip.parent?.removeChildWindow(tip)
                tip.orderOut(nil)
            })
        }
    }

    /// NSString measurement at a fixed width: NSTextField.fittingSize ignores
    /// a wrapping width constraint, so measure the glyphs directly.
    private static func measure(_ string: String, font: NSFont, width: CGFloat) -> NSSize {
        let rect = (string as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return NSSize(width: width, height: ceil(rect.height))
    }
}
