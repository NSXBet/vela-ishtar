// Sources/App/UpdateBellView.swift
// The update bell: a small SF-Symbol bell left of the version dot, rendered
// from an EXPLICIT update state (WP-11 11.1) instead of a bare nil-means-
// current flag. AVAILABLE (a newer, unskipped release exists): yellow, rocks
// for attention, clicking opens the install card (Homebrew command, direct-
// download fallback, release notes, skip). SKIPPED: grey and still, but the
// card says the skipped release still exists — never "up to date". CURRENT:
// grey and still, "you're running vX". NEVER-CHECKED / CHECKING / FAILED:
// grey and still, and the card says exactly that instead of pretending — a
// failed check must never read as "everything is fine".
// Why a custom card: the popover is a borderless NON-activating NSPanel that
// never becomes key, so native menus/tooltips don't fire on it — same hard-won
// lesson as the version bullet (v0.3.2), same pattern: .activeAlways tracking,
// tip window level ABOVE the popover's .statusBar.
// RELEVANT FILES: Sources/App/PopoverView.swift, Sources/App/VersionBulletView.swift, Sources/VelaCore/ReleaseChecker.swift

import Cocoa

@MainActor
public final class UpdateBellView: NSView {

    /// The bell's explicit update state (WP-11 11.1). Every visual and every
    /// word of copy derives from this — the bell can no longer render
    /// "up to date" from a bare nil, because nil was five different truths.
    private var updateState: ReleaseChecker.UpdateState
    /// The version this build is running — shown in the current-state card,
    /// so "you're current" comes with the evidence.
    private let runningVersion: String
    /// True only when a newer, unskipped release is actually pending.
    private var hasUpdate: Bool {
        if case .available = updateState { return true }
        return false
    }

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

    /// Designated init: the bell renders exactly the state it is handed.
    public init(state: ReleaseChecker.UpdateState, runningVersion: String) {
        self.updateState = state
        self.runningVersion = runningVersion
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))

        let bell = NSImageView(frame: NSRect(x: 3, y: 3, width: 14, height: 14))
        // The badged bell is reserved for a real pending update — a badge with
        // nothing behind it is exactly the kind of false alarm this app avoids.
        bell.image = NSImage(
            systemSymbolName: hasUpdate ? "bell.badge.fill" : "bell",
            accessibilityDescription: Self.accessibilityLabel(for: state)
        )
        bell.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        // Yellow ONLY while an update is pending — the whole point of that
        // state is to catch the eye. Every other state (current, skipped,
        // never checked, checking, failed) is the same quiet grey as the
        // version dot beside it (0.35 labelColor): present, legible,
        // ignorable. Skipped is grey on purpose: the user opted out of the
        // nag, but the card still tells the truth (see showCard).
        bell.contentTintColor = hasUpdate ? .systemYellow : NSColor.labelColor.withAlphaComponent(0.35)
        addSubview(bell)
        bellImageView = bell

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // WP-10 (B14): a button role without a press is a dead control in
        // VoiceOver — accessibilityPerformPress (below) routes activation
        // through the same mouseDown path the pointer uses.
        setAccessibilityLabel(Self.accessibilityLabel(for: state))
        setAccessibilityHelp(Self.accessibilityHelp(for: state, runningVersion: runningVersion))
    }

    /// Compat shim for the pre-WP-07 call site in PopoverView, which only
    /// has `updateChecker?.pendingRelease` (a Release?) to pass. nil here is
    /// AMBIGUOUS — it can mean current, skipped, failed, or never checked —
    /// so the shim refuses to claim "up to date" from it: nil renders as the
    /// quiet grey bell with the neutral card, never the "is up to date"
    /// sentence. WP-07/coordinator should rewire to `init(state:...)`.
    /// ponytail: shim removed when PopoverView passes the real state.
    public convenience init(release: VersionCheck.Release?, runningVersion: String) {
        if let release {
            self.init(state: .available(release), runningVersion: runningVersion)
        } else {
            self.init(state: .neverChecked, runningVersion: runningVersion)
        }
    }

    private static func accessibilityLabel(for state: ReleaseChecker.UpdateState) -> String {
        switch state {
        case .available: return "Update available"
        case .skipped: return "Update available (skipped)"
        case .checkedCurrent: return "No updates"
        case .neverChecked: return "Updates not checked yet"
        case .checking: return "Checking for updates"
        case .failed: return "Update check failed"
        }
    }

    private static func accessibilityHelp(for state: ReleaseChecker.UpdateState, runningVersion: String) -> String {
        switch state {
        case .available(let release):
            return "Vela Ishtar v\(release.tag) is available. Activate for install instructions."
        case .skipped(let release):
            return "Vela Ishtar v\(release.tag) is available but skipped. Activate for options."
        case .checkedCurrent:
            return "Vela Ishtar v\(runningVersion) is up to date."
        case .neverChecked:
            return "The app has not checked for updates yet."
        case .checking:
            return "Checking for updates."
        case .failed:
            return "The last update check failed. Activate for how to check manually."
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("UpdateBellView does not support NSCoder-based initialization")
    }

    // MARK: - In-place state application (WP-07: chrome persists across polls)

    /// Re-applies a new update state WITHOUT rebuilding: re-tints the bell,
    /// swaps the symbol, restarts/stops the attention shake, and refreshes
    /// accessibility. The bell view itself is built once; a poll or a
    /// checker change never recreates it (B10: polls must not close the
    /// update card or replay attention motion).
    public func apply(state newState: ReleaseChecker.UpdateState, runningVersion: String) {
        guard newState != updateState else { return }
        updateState = newState
        bellImageView?.image = NSImage(
            systemSymbolName: hasUpdate ? "bell.badge.fill" : "bell",
            accessibilityDescription: Self.accessibilityLabel(for: newState)
        )
        bellImageView?.contentTintColor = hasUpdate ? .systemYellow : NSColor.labelColor.withAlphaComponent(0.35)
        setAccessibilityLabel(Self.accessibilityLabel(for: newState))
        setAccessibilityHelp(Self.accessibilityHelp(for: newState, runningVersion: runningVersion))
        if window != nil { startShakeIfNeeded() }
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

    /// WP-10 (B14): VoiceOver activation toggles the state card exactly as
    /// a click does — the button role finally has a press behind it.
    public override func accessibilityPerformPress() -> Bool {
        mouseDown(with: NSEvent())
        return true
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        // PopoverView rebuilds its hierarchy on every update; an open card
        // must not outlive the bell that spawned it.
        if newWindow == nil { hideCard() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func showCard() {
        guard cardWindow == nil, window != nil else { return }
        // One card per truth. Only checkedCurrent may say "up to date";
        // skipped says "available, skipped"; failed/never-checked/checking
        // say exactly that instead of pretending to know.
        switch updateState {
        case .checkedCurrent:
            showInfoCard(title: "Vela Ishtar is up to date",
                         body: "You're running v\(runningVersion).")
        case .skipped(let release):
            showInfoCard(title: "Vela Ishtar v\(release.tag) is available",
                         body: "You skipped this version. Newer releases will light the bell again.")
        case .neverChecked:
            showInfoCard(title: "Not checked yet",
                         body: "The app hasn't checked for updates yet. It checks automatically every 6 hours.")
        case .checking:
            showInfoCard(title: "Checking for updates…",
                         body: "Asking GitHub for the latest release.")
        case .failed:
            showInfoCard(title: "Update check failed",
                         body: "The last check didn't go through. Check manually at github.com/NSXBet/vela-ishtar/releases")
        case .available(let release):
            showUpdateCard(for: release)
        }
    }

    /// The quiet card for every non-actionable state: a title, one sentence,
    /// no buttons — there is genuinely nothing to do, and offering a control
    /// that does nothing would be worse than silence. Only the copy differs
    /// per state (see showCard). Sized to its text rather than the install
    /// card's fixed 328pt.
    private func showInfoCard(title titleText: String, body bodyText: String) {
        guard let parentWindow = window else { return }

        let padding: CGFloat = 12
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 11)

        let title = NSTextField(labelWithString: titleText)
        title.font = titleFont
        title.textColor = .labelColor

        let body = NSTextField(labelWithString: bodyText)
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

        // Both install channels, honestly labeled (WP-11 11.3): Homebrew is
        // the primary; "View release notes" below also links the ZIP for a
        // direct download. The ZIP is unsigned/notarization-free, so the
        // same xattr note applies either way — but the brew path runs it
        // for the user, which is why it leads.
        let alt = NSTextField(wrappingLabelWithString: "No Homebrew? View release notes below and download the ZIP instead.")
        alt.font = bodyFont
        alt.textColor = .secondaryLabelColor

        let command = NSTextField(wrappingLabelWithString: Self.installCommand)
        command.font = commandFont
        command.textColor = .labelColor
        command.isSelectable = true

        // The command well's measure column (width - padding - well insets)
        // is 290pt at this card width — exactly where the install command
        // wraps to TWO lines; narrower wraps it to three and clips the tail.
        let titleSize = Self.measure(title.stringValue, font: titleFont, width: width - 2 * padding)
        let bodySize = Self.measure(body.stringValue, font: bodyFont, width: width - 2 * padding)
        let altSize = Self.measure(alt.stringValue, font: bodyFont, width: width - 2 * padding)
        let commandSize = Self.measure(Self.installCommand, font: commandFont, width: width - 2 * padding - 12)

        let buttonHeight: CGFloat = 22
        let gap: CGFloat = 8
        let contentHeight = padding + titleSize.height + 4 + bodySize.height + 3 + altSize.height + gap
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

        y -= 3 + altSize.height
        alt.frame = NSRect(x: padding, y: y, width: width - 2 * padding, height: altSize.height)
        content.addSubview(alt)

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
                MainActor.assumeIsolated {
                    card.parent?.removeChildWindow(card)
                    card.orderOut(nil)
                }
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
        // when the state is .available — but read it safely rather than
        // force-unwrap, so a future card wiring can't crash the app.
        if case .available(let release) = updateState, let url = URL(string: release.url) {
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
