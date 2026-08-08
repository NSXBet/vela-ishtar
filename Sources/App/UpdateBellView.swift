// Sources/App/UpdateBellView.swift
// The update bell: a small SF-Symbol bell left of the version dot. It has two
// states. PENDING (a newer, unskipped release exists on GitHub): yellow, rocks
// for attention, clicking opens a card with the one-line install command, the
// release notes link, and "Skip this version". UP-TO-DATE (v1.0.0): grey and
// perfectly still, clicking says so and nothing more — the bell is now a
// permanent, quiet status light rather than an element that appears from
// nowhere, so "no news" is something you can actually read off the popover.
// Why a custom card: the popover is a borderless NON-activating NSPanel that
// never becomes key, so native menus/tooltips don't fire on it — same hard-won
// lesson as the version bullet (v0.3.2), same pattern: .activeAlways tracking,
// tip window level ABOVE the popover's .statusBar.
// RELEVANT FILES: Sources/App/PopoverView.swift, Sources/App/VersionBulletView.swift, Sources/VelaCore/ReleaseChecker.swift

import Cocoa

@MainActor
public final class UpdateBellView: NSView {

    /// The release this bell is announcing, or nil when the app is up to date.
    /// nil is the quiet grey state: no shake, no badge, no card actions.
    private let pendingRelease: VersionCheck.Release?
    /// The version this build is running — shown in the up-to-date card, so
    /// "you're current" comes with the evidence.
    private let runningVersion: String
    /// True when there's a newer release to announce.
    private var hasUpdate: Bool { pendingRelease != nil }

    /// Fired by "Skip this version" — the checker persists the choice and
    /// re-renders so the bell goes quiet. Never fired in the up-to-date state.
    public var onSkip: (() -> Void)?
    /// Fired by "View release notes" — main.swift dismisses the popover,
    /// which is also what tears this card down (its parent view leaves the
    /// window, and viewWillMove hides the card).
    public var onOpenRelease: (() -> Void)?

    private var cardWindow: NSWindow?
    private var trackingArea: NSTrackingArea?
    private var hoverWorkItem: DispatchWorkItem?
    private var isHovering = false

    /// The one-liner users paste into Terminal. `xattr -cr` clears the
    /// quarantine bit Homebrew leaves on the upgraded app.
    public static let installCommand = "brew update && brew upgrade --cask vela-ishtar && xattr -cr \"/Applications/Vela Ishtar.app\""

    public init(release: VersionCheck.Release?, runningVersion: String) {
        self.pendingRelease = release
        self.runningVersion = runningVersion
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))

        let bell = NSImageView(frame: NSRect(x: 3, y: 3, width: 14, height: 14))
        // The badged bell is reserved for a real pending update — a badge with
        // nothing behind it is exactly the kind of false alarm this app avoids.
        bell.image = NSImage(
            systemSymbolName: hasUpdate ? "bell.badge.fill" : "bell",
            accessibilityDescription: hasUpdate ? "Update available" : "No updates"
        )
        bell.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        // Yellow ONLY while an update is pending — the whole point of that
        // state is to catch the eye. Up to date is the same quiet grey as the
        // version dot beside it (0.35 labelColor): present, legible, ignorable.
        bell.contentTintColor = hasUpdate ? .systemYellow : NSColor.labelColor.withAlphaComponent(0.35)
        addSubview(bell)
        bellImageView = bell

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        if let release {
            setAccessibilityLabel("Update available")
            setAccessibilityHelp("Vela Ishtar v\(release.tag) is available. Activate for install instructions.")
        } else {
            setAccessibilityLabel("No updates")
            setAccessibilityHelp("Vela Ishtar v\(runningVersion) is up to date.")
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("UpdateBellView does not support NSCoder-based initialization")
    }

    /// The shake (re)starts in viewDidMoveToWindow, NOT init: a layer added
    /// before the view is in a window has no presentation yet, and CA can
    /// drop an animation applied that early — the bell sat still on first
    /// render even though the keyframes were installed.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startShakeIfNeeded() }
    }

    private weak var bellImageView: NSImageView?

    private func startShakeIfNeeded() {
        // No update, no motion. The grey bell must be perfectly still — a
        // rocking bell that means "nothing to report" is a lie told in motion.
        guard hasUpdate else { return }
        guard let bell = bellImageView,
              bell.layer?.animation(forKey: "attentionShake") == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        bell.wantsLayer = true
        // NEVER touch layer.anchorPoint here. anchorPoint and position are
        // coupled: position is the point in the SUPERLAYER where anchorPoint
        // lands, so moving anchorPoint (0,0)→(0.5,0.5) without correcting
        // position slides the layer down-left by half its size — measured as
        // layer.frame (3,3,14,14) → (-4,-4,14,14), a 7pt shift. That was the
        // real "the bell moved again" bug: addVersionBullet's frame was right,
        // the glyph's LAYER was drawn 7pt off. Worse, AppKit resyncs
        // anchorPoint back to (0,0) on the next layout pass, so the offset
        // appeared and vanished depending on whether a layout had run since —
        // which is why it read as random drift and survived every re-pin.
        // Pivoting via a pre-composed transform needs no anchorPoint change.
        bell.layer?.add(Self.makeShake(size: bell.bounds.size), forKey: "attentionShake")
    }

    /// Attention shake: a gentle ±6° rock, 0.5s of motion then ~3.5s of
    /// stillness (repeatDuration caps the loop at 4s). Pause conditions:
    /// hovered (we already have the user's attention, and a rocking target
    /// is hard to click) or the card is open. Reduce Motion: never starts.
    ///
    /// Each keyframe is a full transform that translates to the glyph's centre,
    /// rotates, and translates back — so the rock pivots about the middle with
    /// anchorPoint left at AppKit's (0,0). The centre is an exact fixed point
    /// of every keyframe, so the bell can't wander while it rocks.
    private static func makeShake(size: CGSize) -> CAKeyframeAnimation {
        let shake = CAKeyframeAnimation(keyPath: "transform")
        shake.values = [0, 0.1, -0.1, 0.07, -0.07, 0].map {
            NSValue(caTransform3D: centredRotation($0, size))
        }
        shake.keyTimes = [0, 0.15, 0.35, 0.55, 0.75, 1]
        shake.duration = 0.5
        shake.repeatCount = .infinity
        shake.repeatDuration = 4
        return shake
    }

    /// A z-rotation about the centre of a `size`-sized layer, expressed
    /// without moving anchorPoint (see startShakeIfNeeded).
    private static func centredRotation(_ radians: CGFloat, _ size: CGSize) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        transform = CATransform3DRotate(transform, radians, 0, 0, 1)
        return CATransform3DTranslate(transform, -size.width / 2, -size.height / 2, 0)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .activeAlways: the panel never becomes key, so the default
        // active-when-key would never deliver entered/exited.
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // PopoverView rebuilds its hierarchy on every poll — the tracking
        // area does NOT reliably re-register on re-parenting inside a
        // nonactivating panel (the v0.5.2 "hover is dead until I click"
        // report). Force a fresh one whenever we land under a superview.
        if superview != nil { updateTrackingAreas() }
    }

    /// The bell's resting tint: attention-yellow with a pending update, the
    /// version dot's quiet grey when up to date.
    private var restingTint: NSColor {
        hasUpdate ? .systemYellow : NSColor.labelColor.withAlphaComponent(0.35)
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovering = true
        // Hover = we have the user's attention: pause the shake and brighten.
        // A rocking target is hard to click, and the shake's job is done.
        bellImageView?.layer?.removeAnimation(forKey: "attentionShake")
        hoverWorkItem?.cancel()
        // Brighten on hover in BOTH states, so the grey bell still reads as
        // clickable rather than as disabled chrome.
        let target: NSColor = hasUpdate ? .systemYellow : NSColor.labelColor.withAlphaComponent(0.75)
        let work = DispatchWorkItem { [weak self] in
            self?.bellImageView?.contentTintColor = target
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    public override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoverWorkItem?.cancel()
        bellImageView?.contentTintColor = restingTint
        // Resume the shake only if the card isn't open — while the card is
        // up, the user is already engaged and the bell should stay still.
        // (No-op in the up-to-date state; startShakeIfNeeded refuses.)
        if cardWindow == nil { startShakeIfNeeded() }
    }

    public override func mouseDown(with event: NSEvent) {
        if cardWindow == nil { showCard() } else { hideCard() }
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        // PopoverView rebuilds its hierarchy on every update; an open card
        // must not outlive the bell that spawned it.
        if newWindow == nil { hideCard() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func showCard() {
        guard cardWindow == nil, window != nil else { return }
        // Two very different cards. Up to date: one line, no actions, nothing
        // to do. Pending: the install card below.
        guard let release = pendingRelease else { showUpToDateCard(); return }
        showUpdateCard(for: release)
    }

    /// The quiet card for the up-to-date state: a single sentence naming the
    /// running version. No buttons — there is genuinely nothing to act on, and
    /// offering a control that does nothing would be worse than silence. Sized
    /// to its text rather than the install card's fixed 328pt.
    private func showUpToDateCard() {
        guard let parentWindow = window else { return }

        let padding: CGFloat = 12
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11)

        let title = NSTextField(labelWithString: "Vela Ishtar is up to date")
        title.font = titleFont
        title.textColor = .labelColor

        let body = NSTextField(labelWithString: "You're running v\(runningVersion).")
        body.font = bodyFont
        body.textColor = .secondaryLabelColor

        // Measured from the labels' own fittingSize (the v0.5.2 lesson: an
        // attributed string's tight glyph box under-measures and clips tails).
        let width = max(title.fittingSize.width, body.fittingSize.width) + 2 * padding
        let contentHeight = padding + title.fittingSize.height + 3 + body.fittingSize.height + padding

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .popover
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 8
        blur.layer?.masksToBounds = true
        content.addSubview(blur)

        var y = contentHeight - padding - title.fittingSize.height
        title.frame = NSRect(x: padding, y: y, width: width - 2 * padding, height: title.fittingSize.height)
        content.addSubview(title)
        y -= 3 + body.fittingSize.height
        body.frame = NSRect(x: padding, y: y, width: width - 2 * padding, height: body.fittingSize.height)
        content.addSubview(body)

        presentCard(content: content, width: width, parentWindow: parentWindow)
    }

    private func showUpdateCard(for pendingRelease: VersionCheck.Release) {
        guard let parentWindow = window else { return }

        // 328pt: the install command needs a 290pt measure column to wrap at
        // TWO lines — anything narrower breaks it to three and clips the
        // trailing `.app"` out of the well (the v0.5.2 "…xattr -cr \"/"
        // screenshot). 290 + 12 well insets + 24 padding = 326; +2 margin.
        let width: CGFloat = 328
        let padding: CGFloat = 12
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let commandFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        let title = NSTextField(wrappingLabelWithString: "Vela Ishtar v\(pendingRelease.tag) is available")
        title.font = titleFont
        title.textColor = .labelColor

        let body = NSTextField(wrappingLabelWithString: "Update with Homebrew — paste this into Terminal:")
        body.font = bodyFont
        body.textColor = .secondaryLabelColor

        let command = NSTextField(wrappingLabelWithString: Self.installCommand)
        command.font = commandFont
        command.textColor = .labelColor
        command.isSelectable = true

        // The command well's measure column (width - padding - well insets)
        // is 290pt at this card width — exactly where the install command
        // wraps to TWO lines; narrower wraps it to three and clips the tail.
        let titleSize = Self.measure(title.stringValue, font: titleFont, width: width - 2 * padding)
        let bodySize = Self.measure(body.stringValue, font: bodyFont, width: width - 2 * padding)
        let commandSize = Self.measure(Self.installCommand, font: commandFont, width: width - 2 * padding - 12)

        let buttonHeight: CGFloat = 22
        let gap: CGFloat = 8
        let contentHeight = padding + titleSize.height + 4 + bodySize.height + gap
            + commandSize.height + 12 + gap + buttonHeight + gap + buttonHeight + gap + buttonHeight + padding

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .popover
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 8
        blur.layer?.masksToBounds = true
        content.addSubview(blur)

        var y = contentHeight - padding - titleSize.height
        title.frame = NSRect(x: padding, y: y, width: width - 2 * padding, height: titleSize.height)
        content.addSubview(title)

        y -= 4 + bodySize.height
        body.frame = NSRect(x: padding, y: y, width: width - 2 * padding, height: bodySize.height)
        content.addSubview(body)

        // The command sits on a subtle rounded well so it reads as copyable
        // text, not prose.
        y -= gap + commandSize.height + 12
        let well = NSView(frame: NSRect(x: padding, y: y, width: width - 2 * padding, height: commandSize.height + 12))
        well.wantsLayer = true
        well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        well.layer?.cornerRadius = 6
        content.addSubview(well)
        command.frame = NSRect(x: padding + 6, y: y + 6, width: width - 2 * padding - 12, height: commandSize.height)
        content.addSubview(command)

        y -= gap + buttonHeight
        let copyButton = Self.makeButton(title: "Copy update command", frame: NSRect(x: padding, y: y, width: width - 2 * padding, height: buttonHeight))
        copyButton.target = self
        copyButton.action = #selector(copyCommand)
        content.addSubview(copyButton)

        y -= gap + buttonHeight
        let notesButton = Self.makeButton(title: "View release notes", frame: NSRect(x: padding, y: y, width: width - 2 * padding, height: buttonHeight))
        notesButton.target = self
        notesButton.action = #selector(openRelease)
        content.addSubview(notesButton)

        y -= gap + buttonHeight
        let skipButton = Self.makeButton(title: "Skip this version", frame: NSRect(x: padding, y: y, width: width - 2 * padding, height: buttonHeight))
        skipButton.target = self
        skipButton.action = #selector(skip)
        content.addSubview(skipButton)

        presentCard(content: content, width: width, parentWindow: parentWindow)
    }

    /// Wraps a built content view in the floating panel, places it beside the
    /// popover, fades it in, and stores it as `cardWindow`. Shared by both card
    /// variants so the placement rules (and the child-window parenting that
    /// keeps a card from outliving the popover) exist exactly once.
    private func presentCard(content: NSView, width: CGFloat, parentWindow: NSWindow) {
        let panel = NSPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = content
        panel.isFloatingPanel = true
        // Above the popover's .statusBar level, or the card renders behind it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Parented to the popover: the popover's outside-click monitor lets
        // child-window clicks pass (see PopoverPanel), and dismiss() can
        // orderOut every child in one pass — the card can't outlive it.
        parentWindow.addChildWindow(panel, ordered: .above)

        // Beside the popover, never over it — same side-choice logic as the
        // version bullet's tip: prefer the popover's right, flip left on a
        // right-anchored menu bar.
        let sideGap: CGFloat = 8
        let bellOnScreen = parentWindow.convertToScreen(convert(bounds, to: nil))
        let popover = parentWindow.frame
        let visible = (parentWindow.screen ?? NSScreen.main)?.visibleFrame

        let rightX = popover.maxX + sideGap
        let leftX = popover.minX - sideGap - width
        let originX: CGFloat
        if let visible {
            if rightX + width <= visible.maxX - 4 {
                originX = rightX
            } else if leftX >= visible.minX + 4 {
                originX = leftX
            } else {
                let roomRight = visible.maxX - popover.maxX
                let roomLeft = popover.minX - visible.minX
                originX = roomRight >= roomLeft
                    ? min(rightX, visible.maxX - width - 4)
                    : max(leftX, visible.minX + 4)
            }
        } else {
            originX = rightX
        }

        var originY = bellOnScreen.maxY - content.frame.height
        if let visible {
            originY = min(max(originY, visible.minY + 4), visible.maxY - content.frame.height - 4)
        }
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))

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
        cardWindow = panel
    }

    private func hideCard() {
        guard let card = cardWindow else { return }
        cardWindow = nil
        // Unparent as well as order out: the card is a child window of the
        // popover (see presentCard), so it must leave the childWindows list
        // when it closes — otherwise PopoverPanel.dismiss() would re-tear-down
        // a panel we no longer own.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            card.parent?.removeChildWindow(card)
            card.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.08
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.animator().alphaValue = 0
            }, completionHandler: {
                card.parent?.removeChildWindow(card)
                card.orderOut(nil)
            })
        }
        // Card closed → the attention shake may resume (unless hovered).
        if !isHovering { startShakeIfNeeded() }
    }

    @objc private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
        // Command is on the clipboard — the user's next stop is Terminal,
        // so take the card and the popover down behind them.
        onOpenRelease?()
    }

    @objc private func openRelease() {
        // Dismiss the popover FIRST — its outside-click monitors tear this
        // card down with it, and the release page opening in a browser is a
        // context switch away from the menu bar anyway.
        onOpenRelease?()
        // Only reachable from the pending-update card, which is only built
        // when pendingRelease is non-nil — but read it safely rather than
        // force-unwrap, so a future card wiring can't crash the app.
        if let release = pendingRelease, let url = URL(string: release.url) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func skip() {
        hideCard()
        onSkip?()
        // Skip re-renders the popover without this bell — closing the popover
        // keeps the user out of a mid-rebuild card.
        onOpenRelease?()
    }

    /// Rounded, tinted button — a real control, not body copy. The flat
    /// text-only style this replaced read as three more lines of prose, so
    /// users didn't parse them as clickable (v0.5.2 field report).
    private static func makeButton(title: String, frame: NSRect) -> NSButton {
        let button = NSButton(frame: frame)
        button.setButtonType(.momentaryLight)
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.title = title
        return button
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
