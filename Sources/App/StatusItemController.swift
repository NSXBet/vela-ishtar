// Sources/App/StatusItemController.swift
// Renders the menu bar pill: sparkline, global-spend amount and border, plus
// a separate alert dot for an alarming nested model cap; owns the NSStatusItem.
// Why: the border remains the global budget gauge, while the dot adds model-cap
// urgency without changing what the existing pill instrument means.
// RELEVANT FILES: Sources/VelaCore/BorderDash.swift, Sources/VelaCore/ModelBudgetSignal.swift, Sources/VelaCore/PollStateMachine.swift, Sources/App/UsagePoller.swift

import Cocoa

/// Owns the NSStatusItem and re-draws its image only when the caller (the
/// App layer, fed by UsagePoller.onState) reports a genuinely new
/// (state, burnBuffer) pair. No timer, no animation loop lives here.
@MainActor
public final class StatusItemController: NSObject {
    /// Fired on left-click.
    public var onClick: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var appearanceObservation: NSKeyValueObservation?

    /// Exposed so the popover can anchor itself under this exact button.
    /// Only valid after install(); nil before that.
    public var button: NSStatusBarButton? { statusItem?.button }

    // Last-rendered inputs; render() skips redraw when both unchanged (zero-render-between-polls rule).
    private var lastState: PollState?
    private var lastBurnBuffer: BurnBuffer?
    // Cooldown expiry can change the dot without changing the response, so the
    // rendering guard also remembers the derived time-sensitive model signal.
    private var lastModelBudgetSignal: ModelBudgetSignal?

    // Pill geometry, in points -- matches the locked design spec. The three
    // widths are the condensation ladder (v0.3.0): full shows sparkline +
    // exact amount, compact drops the sparkline and rounds the amount,
    // hairline is the border gauge alone.
    private static let pillSizeFull = NSSize(width: 88, height: 22)
    private static let pillSizeCompact = NSSize(width: 52, height: 22)
    private static let pillSizeHairline = NSSize(width: 26, height: 22)
    private static let cornerRadius: CGFloat = 6

    /// The condensation level. `automatic` follows notch clipping; the user
    /// can pin a level from the right-click menu. Persisted across launches.
    private enum CalmLevel: Int {
        case automatic = 0, full, compact, hairline
    }
    private static let calmLevelDefaultsKey = "vela.calmLevel"
    private var calmLevel: CalmLevel {
        get { CalmLevel(rawValue: UserDefaults.standard.integer(forKey: Self.calmLevelDefaultsKey)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.calmLevelDefaultsKey) }
    }

    /// The effective pill size for the current calm level + clipping state.
    /// Automatic resolves to hairline when the status item is being clipped
    /// (notch), else full. An explicit user choice always wins.
    private var effectivePillSize: NSSize {
        switch calmLevel {
        case .full: return Self.pillSizeFull
        case .compact: return Self.pillSizeCompact
        case .hairline: return Self.pillSizeHairline
        case .automatic:
            return isClipped ? Self.pillSizeHairline : Self.pillSizeFull
        }
    }

    /// True when the status item's button window is occluded by the notch —
    /// the known adoption killer on notched MacBooks. Detection: the button's
    /// window is absent or hidden by the system. Failure direction matters:
    /// an absent window reports CLIPPED (narrow is the safe failure — a
    /// hairline where a full pill would fit costs nothing, a full pill
    /// behind the notch is invisible spend data).
    private var isClipped: Bool {
        guard let window = statusItem?.button?.window else { return true }
        return !window.isVisible
    }

    public override init() {
        super.init()
    }

    /// Creates the NSStatusItem, draws the initial (neverFetched) image, and wires click + appearance-change handlers.
    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        // Left-click toggles the popover (via onClick); right-click opens
        // the utility menu. Without this mask the button swallows right
        // clicks and the menu never fires.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // VoiceOver: the pill is an image with no text, so it needs an
        // explicit label + a value that tracks the spend reading.
        button.setAccessibilityLabel("AI Hub spend")
        button.setAccessibilityValue("no data yet")

        let initialBuffer = BurnBuffer()
        statusItem?.length = effectivePillSize.width
        button.image = bakedImage(state: .neverFetched, burnBuffer: initialBuffer, appearance: button.effectiveAppearance)
        lastState = .neverFetched
        lastBurnBuffer = initialBuffer

        // A light/dark switch is render-worthy too (different ink colors resolve), but still discrete.
        // A light/dark switch is render-worthy too (different ink colors resolve), but still discrete.
        //
        // Observe NSApp.effectiveAppearance, NOT button.effectiveAppearance:
        // the button's KVO fires again when WE assign a new image in response
        // to a change (AppKit re-resolves the button's appearance during
        // setImage:), so observing it created a render→notify→render loop
        // that pinned the main thread (observed: ~70% of samples inside the
        // observer). The app's appearance only changes on a real light/dark
        // switch — exactly the discrete event we want.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem?.button,
                      let state = self.lastState, let buffer = self.lastBurnBuffer else { return }
                button.image = self.bakedImage(state: state, burnBuffer: buffer, appearance: button.effectiveAppearance)
            }
        }
    }

    /// Re-renders only if `state` or `burnBuffer` actually changed since the last call (or install()'s initial draw).
    public func render(state: PollState, burnBuffer: BurnBuffer) {
        let modelBudgetSignal = Self.modelBudgetSignal(for: state, now: Date())
        // The condensation level re-evaluates on EVERY call, before the
        // unchanged-guard: clipping changes arrive with no event of their
        // own, so a poll that returns an identical reading (common
        // overnight) must still be able to shrink the pill — otherwise the
        // notch-clipped state persists indefinitely, the exact failure the
        // ladder exists to fix.
        let width = effectivePillSize.width
        if statusItem?.length != width {
            statusItem?.length = width
            if let button = statusItem?.button {
                button.image = bakedImage(state: state, burnBuffer: burnBuffer, appearance: button.effectiveAppearance, modelBudgetSignal: modelBudgetSignal)
            }
        }
        if let lastState, let lastBurnBuffer,
           lastState == state, lastBurnBuffer == burnBuffer,
           lastModelBudgetSignal == modelBudgetSignal {
            return
        }
        lastState = state
        lastBurnBuffer = burnBuffer
        lastModelBudgetSignal = modelBudgetSignal
        guard let button = statusItem?.button else { return }
        button.image = bakedImage(state: state, burnBuffer: burnBuffer, appearance: button.effectiveAppearance, modelBudgetSignal: modelBudgetSignal)
        button.setAccessibilityLabel(Self.accessibilityLabel(for: modelBudgetSignal))
        button.setAccessibilityValue(Self.accessibilityValue(for: state))
    }

    /// The VoiceOver reading of the pill's current state, e.g.
    /// "$54.51 of $400, 14 percent". Kept terse — VoiceOver users hear
    /// this every time the pill updates.
    /// The alert label describes the small dot in words, rather than relying
    /// on its red hue to tell VoiceOver users that a model cap needs attention.
    private static func accessibilityLabel(for signal: ModelBudgetSignal?) -> String {
        guard let signal, signal.isAlarming else { return "AI Hub spend" }
        let modelName = ModelBudgetSignal.displayName(for: signal.model)
        switch signal.state {
        case .blocked, .exhausted:
            return "\(modelName) limit reached"
        case .alarm:
            return "\(modelName) limit nearly reached"
        default:
            return "\(modelName) limit needs attention"
        }
    }

    private static func accessibilityValue(for state: PollState) -> String {
        switch state {
        case .neverFetched:
            return "no data yet"
        case .fresh(let usage), .stale(let usage, _):
            let budget = usage.dailyBudget
            let percent = Int(budget.usedPercent.rounded())
            return String(format: "$%.2f of $%.0f, %d percent", budget.spentUSD, budget.limitUSD, percent)
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton?) {
        guard let event = NSApp.currentEvent else { onClick?(); return }
        if event.type == .rightMouseUp {
            showUtilityMenu()
        } else {
            onClick?()
        }
    }

    /// The right-click utility menu: three verbs, no settings, no clutter.
    /// Platform table stakes for a menu bar app — and the only way to Quit
    /// without Activity Monitor.
    private func showUtilityMenu() {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy today's spend", action: #selector(copyTodaysSpend), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        let historyItem = NSMenuItem(title: "Open history folder", action: #selector(openHistoryFolder), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        // Calm level (v0.3.0): how much chrome the pill shows. A submenu of
        // four mutually-exclusive choices with a checkmark on the active one.
        let calmMenu = NSMenu()
        let choices: [(String, CalmLevel)] = [
            ("Automatic", .automatic),
            ("Full", .full),
            ("Compact", .compact),
            ("Minimal", .hairline),
        ]
        for (title, level) in choices {
            let item = NSMenuItem(title: title, action: #selector(calmLevelPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level.rawValue
            item.state = (level == calmLevel) ? .on : .off
            calmMenu.addItem(item)
        }
        let calmItem = NSMenuItem(title: "Pill size", action: nil, keyEquivalent: "")
        calmItem.submenu = calmMenu
        menu.addItem(calmItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Vela Ishtar", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = statusItem?.button {
            // Pop the menu under the pill. statusItem.menu would hijack the
            // left-click too, so we present manually on right-click only.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func copyTodaysSpend() {
        guard let state = lastState else { return }
        let text: String
        switch state {
        case .neverFetched:
            text = "AI Hub — no data yet"
        case .fresh(let usage), .stale(let usage, _):
            let budget = usage.dailyBudget
            text = String(format: "AI Hub — today $%.2f of $%.0f (%d%%)",
                          budget.spentUSD, budget.limitUSD, Int(budget.usedPercent.rounded()))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openHistoryFolder() {
        NSWorkspace.shared.open(HistoryStore.defaultDirectory)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// Applies a calm-level choice from the Pill size submenu and forces a
    /// redraw (render() would skip it — neither state nor burnBuffer changed).
    @objc private func calmLevelPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let level = CalmLevel(rawValue: raw) else { return }
        calmLevel = level
        statusItem?.length = effectivePillSize.width
        guard let button = statusItem?.button, let state = lastState, let buffer = lastBurnBuffer else { return }
        button.image = bakedImage(state: state, burnBuffer: buffer, appearance: button.effectiveAppearance)
    }

    // MARK: - Rendering

    /// `NSImage(size:flipped:drawingHandler:)` produces an image backed by a
    /// custom image rep — AppKit re-executes the closure EVERY time the
    /// image draws. For an NSStatusItem that's catastrophic: the system's
    /// replicant layer snapshots the button's window on a repeating
    /// timer, and each snapshot re-runs the whole draw block (sparkline,
    /// border, text) plus a WindowServer round-trip. Observed: ~73% of main-
    /// thread samples inside `_updateReplicants`, footprint growing to 247MB
    /// from leaked replicant bitmaps. The fix is to bake the closure output
    /// into a plain bitmap once per real change, and hand AppKit the
    /// bitmap-backed image from then on.
    ///
    /// Used for every status-item assignment. `makeImage` itself stays
    /// closure-based so the snapshot tool can render arbitrary states
    /// one-shot without paying for a flatten it never reuses.
    public func bakedImage(
        state: PollState,
        burnBuffer: BurnBuffer,
        appearance: NSAppearance,
        modelBudgetSignal: ModelBudgetSignal? = nil
    ) -> NSImage {
        let closureImage = makeImage(
            state: state,
            burnBuffer: burnBuffer,
            appearance: appearance,
            modelBudgetSignal: modelBudgetSignal
        )
        guard let tiff = closureImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            // Baking failed (no graphics context?) — fall back to the
            // closure-backed image. Costs CPU under the replicant loop but
            // never costs a blank pill.
            return closureImage
        }
        let baked = NSImage(size: closureImage.size)
        baked.addRepresentation(bitmap)
        baked.isTemplate = false
        return baked
    }

    /// Pure render: turns a (state, burnBuffer) pair into an NSImage under
    /// the given appearance. Used by install() and by the snapshot tool
    /// (which fabricates arbitrary states without a real UsagePoller).
    public func makeImage(
        state: PollState,
        burnBuffer: BurnBuffer,
        appearance: NSAppearance,
        modelBudgetSignal: ModelBudgetSignal? = nil
    ) -> NSImage {
        let modelBudgetSignal = modelBudgetSignal ?? Self.modelBudgetSignal(for: state, now: Date())
        let size = effectivePillSize
        // What the current level draws: hairline is the border gauge alone;
        // compact adds a rounded amount; full adds the sparkline + exact amount.
        let drawsContents = size.width > Self.pillSizeHairline.width
        let drawsSparkline = size.width >= Self.pillSizeFull.width

        let image = NSImage(size: size, flipped: false) { rect in
            // Resolve semantic colors under the TARGET appearance, not the ambient one -- snapshots need to force light/dark.
            var (ink, secondary, yellow, orange, red) = (NSColor.labelColor, NSColor.secondaryLabelColor, NSColor.systemYellow, NSColor.systemOrange, NSColor.systemRed)
            appearance.performAsCurrentDrawingAppearance {
                (ink, secondary, yellow, orange, red) = (.labelColor, .secondaryLabelColor, .systemYellow, .systemOrange, .systemRed)
            }
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let (usedPercent, limitEnabled) = Self.budgetFields(for: state)
            // The lane gets whatever width the amount doesn't need (6pt gap) --
            // a fixed-width lane overlapped long amounts like "$231.40".
            let amountWidth = drawsContents ? Self.amountWidth(for: state, compact: !drawsSparkline) : 0
            let laneWidth = max(rect.width - 8 - 6 - amountWidth - 8, 0)
            let sparklineLane = CGRect(x: rect.minX + 8, y: rect.minY + (rect.height - 14) / 2, width: laneWidth, height: 14)

            switch state {
            case .stale:
                // Everything dims to 55% and the amount switches to
                // secondaryLabelColor -- staleness overrides the "border
                // stays full strength" exception below.
                ctx.saveGState()
                ctx.setAlpha(0.55)
                Self.drawBorder(rect: rect, usedPercent: usedPercent, limitEnabled: limitEnabled, ink: ink, yellow: yellow, orange: orange, red: red)
                if drawsSparkline { Self.drawSparkline(lane: sparklineLane, burnBuffer: burnBuffer, ink: ink) }
                if drawsContents { Self.drawAmount(pillRect: rect, text: Self.amountText(for: state, compact: !drawsSparkline), color: secondary) }
                if modelBudgetSignal?.isAlarming == true { Self.drawModelLimitDot(in: rect, color: red) }
                ctx.restoreGState()

            case .fresh, .neverFetched:
                // Border draws at full strength always -- it's the alarm and
                // must not dim even when exhausted. Only contents dim then.
                //
                // Deliberately `isFull` (100%), NOT the border's alarm
                // threshold (90%): dimming the amount says "your budget is
                // gone", which is only true once it actually is. The border
                // shouts earlier; the number stays full strength until the
                // money really has run out. Do not "align" these two.
                let exhausted = limitEnabled && BorderDash.isFull(usedPercent / 100.0)
                Self.drawBorder(rect: rect, usedPercent: usedPercent, limitEnabled: limitEnabled, ink: ink, yellow: yellow, orange: orange, red: red)
                ctx.saveGState()
                ctx.setAlpha(exhausted ? 0.55 : 1.0)
                if drawsSparkline { Self.drawSparkline(lane: sparklineLane, burnBuffer: burnBuffer, ink: ink) }
                if drawsContents { Self.drawAmount(pillRect: rect, text: Self.amountText(for: state, compact: !drawsSparkline), color: ink) }
                ctx.restoreGState()
                if modelBudgetSignal?.isAlarming == true { Self.drawModelLimitDot(in: rect, color: red) }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// usedPercent/limitEnabled live on the wrapped UsageResponse for
    /// .fresh/.stale; .neverFetched has none yet, so it's treated as 0% of
    /// an enabled budget (draws the faint empty-outline case).
    private static func budgetFields(for state: PollState) -> (usedPercent: Double, limitEnabled: Bool) {
        switch state {
        case .neverFetched:
            return (0, true)
        case .fresh(let usage), .stale(let usage, _):
            return (usage.dailyBudget.usedPercent, usage.dailyBudget.limitEnabled)
        }
    }

    /// Selects the same deterministic cap for the dot as the popover row.
    /// PollState already retains the full response during stale periods, so no
    /// persistence or second request is needed to carry model budgets here.
    private static func modelBudgetSignal(for state: PollState, now: Date) -> ModelBudgetSignal? {
        let budgets: [ModelBudget]
        switch state {
        case .neverFetched:
            return nil
        case .fresh(let usage), .stale(let usage, _):
            budgets = usage.dailyBudget.modelBudgets
        }
        let inputs = budgets.map { budget in
            ModelBudgetInput(
                model: budget.model,
                spentUSD: budget.spentUSD,
                limitUSD: budget.limitUSD,
                relaxedUntil: budget.cooldown?.relaxedUntil.flatMap(ISODate.parse)
            )
        }
        // `mostUrgent` ranks an active cooldown below every enforced cap;
        // when it is the only model record its `isAlarming` is still false,
        // so the dot remains suppressed while its spend/limit stays visible.
        return ModelBudgetSignal.mostUrgent(from: inputs, now: now)
    }

    private static func amountText(for state: PollState, compact: Bool = false) -> String {
        switch state {
        case .neverFetched:
            return "—"
        case .fresh(let usage), .stale(let usage, _):
            // Compact mode rounds to whole dollars — at 52pt wide there's no
            // room for cents, and "$231" reads fine at a glance.
            return compact
                ? String(format: "$%.0f", usage.dailyBudget.spentUSD)
                : String(format: "$%.2f", usage.dailyBudget.spentUSD)
        }
    }

    /// The border-is-the-budget trace. f = usedPercent / 100 (the API is
    /// 0...100, BorderDash's math is 0...1 -- this divide is the one place
    /// that conversion happens).
    ///
    /// The thresholds are BorderDash.level's, not inline numbers (v1.0.0):
    /// .empty  -> faint full outline, no trace.
    /// .trace  -> faint outline + ink-70% trace.
    /// .notice -> + yellow trace (past 50%).
    /// .amber  -> + amber trace (past 75%).
    /// .alarm  -> solid closed loop in systemRed, no faint outline (past 90%).
    ///
    /// The colour ramp escalates ink → yellow → amber → red, so the border
    /// reads as one rising signal. Yellow at the halfway mark is a heads-up
    /// ("half your day is gone"), amber is the warning, red is the alarm.
    ///
    /// Note the alarm now fires at 90%, BEFORE the budget is actually spent.
    /// The dash pattern still has to be drawn for 0.90 <= f < 1: `pattern`
    /// returns nil only at f >= 1, so a red partial loop would otherwise
    /// render as a red DASH sitting at 90-something percent. We close the loop
    /// explicitly for the whole alarm band instead, which is the point — the
    /// alarm is "you are about to run out", and a closed ring says that.
    private static func drawBorder(rect: CGRect, usedPercent: Double, limitEnabled: Bool, ink: NSColor, yellow: NSColor, orange: NSColor, red: NSColor) {
        let borderRect = rect.insetBy(dx: 0.75, dy: 0.75)
        let r = min(cornerRadius, min(borderRect.width, borderRect.height) / 2)
        let path = clockwiseRoundedRectPath(in: borderRect, cornerRadius: r)
        path.lineWidth = 1.5

        let f = usedPercent / 100.0
        let level = BorderDash.level(forFraction: f, limitEnabled: limitEnabled)

        if level == .alarm {
            clearDash(path)
            red.setStroke()
            path.stroke()
            return
        }

        // Faint outline is the "empty gauge" baseline; the brighter trace
        // (when there's spend to show) draws on top of it below.
        clearDash(path)
        ink.withAlphaComponent(0.12).setStroke()
        path.stroke()

        guard level != .empty else { return }

        let perimeter = BorderDash.perimeter(width: Double(borderRect.width), height: Double(borderRect.height), cornerRadius: Double(r))
        guard let pattern = BorderDash.pattern(forFraction: f, perimeter: perimeter) else { return }

        applyDash(path, on: CGFloat(pattern.on), off: CGFloat(pattern.off), phase: CGFloat(BorderDash.phase(perimeter: perimeter)))
        let traceColor: NSColor
        switch level {
        case .amber:  traceColor = orange
        case .notice: traceColor = yellow
        // .empty and .alarm both returned above; .trace is the quiet default.
        default:      traceColor = ink.withAlphaComponent(0.70)
        }
        traceColor.setStroke()
        path.stroke()
    }

    /// Age-faded burn history: soft area fill under the line, a stroke that
    /// fades from 15% ink (oldest) to 100% (newest), and a leading dot.
    private static func drawSparkline(lane: CGRect, burnBuffer: BurnBuffer, ink: NSColor) {
        guard let normalized = burnBuffer.normalized() else {
            // Nothing burned yet -- a flat hairline reads as "no signal"
            // rather than a misleading spike at zero.
            let hairline = NSBezierPath()
            hairline.move(to: CGPoint(x: lane.minX, y: lane.midY))
            hairline.line(to: CGPoint(x: lane.maxX, y: lane.midY))
            hairline.lineWidth = hairlineWidth
            ink.withAlphaComponent(0.3).setStroke()
            hairline.stroke()
            return
        }

        let points: [CGPoint] = normalized.enumerated().map { i, v in
            let x = normalized.count > 1
                ? lane.minX + lane.width * CGFloat(i) / CGFloat(normalized.count - 1)
                : lane.maxX
            return CGPoint(x: x, y: lane.minY + lane.height * CGFloat(v))
        }

        guard points.count > 1 else {
            // A single sample can't be a line; the dot still shows activity.
            drawLeadingDot(at: points[0], ink: ink)
            return
        }

        // Soft area fill: a vertical gradient (ink 15% -> transparent)
        // clipped under the polyline -- cheaper than fading a fill along
        // the curve itself.
        if let ctx = NSGraphicsContext.current?.cgContext {
            let area = CGMutablePath()
            area.move(to: CGPoint(x: points[0].x, y: lane.minY))
            points.forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: lane.minY))
            area.closeSubpath()

            ctx.saveGState()
            ctx.addPath(area)
            ctx.clip()
            let colors = [ink.withAlphaComponent(0.15).cgColor, ink.withAlphaComponent(0).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: lane.maxY), end: CGPoint(x: 0, y: lane.minY), options: [])
            }
            ctx.restoreGState()
        }

        // Age-faded stroke: one NSBezierPath has one color, so the
        // 0.15 -> 1.0 ramp is drawn as one segment per adjacent pair of
        // points rather than a handful of coarser bands.
        for i in 1..<points.count {
            let alpha: CGFloat = points.count > 2
                ? 0.15 + (0.85 * CGFloat(i - 1) / CGFloat(points.count - 2))
                : 1.0
            let segment = NSBezierPath()
            segment.move(to: points[i - 1])
            segment.line(to: points[i])
            segment.lineWidth = hairlineWidth * 2
            ink.withAlphaComponent(alpha).setStroke()
            segment.stroke()
        }

        drawLeadingDot(at: points[points.count - 1], ink: ink)
    }

    /// The separate 4pt marker says that a nested enforced cap needs action.
    /// It is intentionally independent from the global-budget border gauge.
    private static func drawModelLimitDot(in pillRect: CGRect, color: NSColor) {
        let diameter: CGFloat = 4
        let dot = NSBezierPath(ovalIn: CGRect(
            x: pillRect.minX + 3,
            y: pillRect.midY - diameter / 2,
            width: diameter,
            height: diameter
        ))
        color.setFill()
        dot.fill()
    }

    private static func drawLeadingDot(at point: CGPoint, ink: NSColor) {
        let r: CGFloat = 1.5
        let dot = NSBezierPath(ovalIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        ink.withAlphaComponent(1.0).setFill()
        dot.fill()
    }

    /// Right-aligned, 8pt from the pill's right edge, vertically centered.
    /// Measured width of the amount text at the pill's font, so the
    /// sparkline lane can give it exactly the room it needs.
    private static func amountWidth(for state: PollState, compact: Bool = false) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let text = amountText(for: state, compact: compact)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func drawAmount(pillRect: CGRect, text: String, color: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        attributed.draw(at: CGPoint(x: pillRect.maxX - 8 - size.width, y: pillRect.midY - size.height / 2))
    }

    /// Rounded-rect path built as explicit segments starting at top-center
    /// and proceeding clockwise (top -> right -> bottom -> left), per the
    /// design spec -- this is what makes the dash's "on" portion read as
    /// "how much budget is used" rather than starting at an arbitrary corner.
    private static func clockwiseRoundedRectPath(in rect: CGRect, cornerRadius r: CGFloat) -> NSBezierPath {
        let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
        let midX = rect.midX
        let path = NSBezierPath()

        path.move(to: CGPoint(x: midX, y: y1))
        path.line(to: CGPoint(x: x1 - r, y: y1))
        path.appendArc(withCenter: CGPoint(x: x1 - r, y: y1 - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: CGPoint(x: x1, y: y0 + r))
        path.appendArc(withCenter: CGPoint(x: x1 - r, y: y0 + r), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        path.line(to: CGPoint(x: x0 + r, y: y0))
        path.appendArc(withCenter: CGPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: -90, endAngle: -180, clockwise: true)
        path.line(to: CGPoint(x: x0, y: y1 - r))
        path.appendArc(withCenter: CGPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: CGPoint(x: midX, y: y1))
        path.close()
        return path
    }

    private static func applyDash(_ path: NSBezierPath, on: CGFloat, off: CGFloat, phase: CGFloat) {
        let pattern: [CGFloat] = [on, off]
        pattern.withUnsafeBufferPointer { buffer in
            path.setLineDash(buffer.baseAddress, count: 2, phase: phase)
        }
    }

    private static func clearDash(_ path: NSBezierPath) {
        path.setLineDash(nil, count: 0, phase: 0)
    }

    /// One device pixel, in points. Menu bar screens are effectively always
    /// Retina (scale 2), but this reads the real value so hairlines stay
    /// crisp on any scale rather than hardcoding 0.5.
    private static var hairlineWidth: CGFloat {
        1.0 / (NSScreen.main?.backingScaleFactor ?? 2.0)
    }
}
