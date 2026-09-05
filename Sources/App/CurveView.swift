// Sources/App/CurveView.swift
// Draws today's cumulative-spend curve: a filled polyline against a dotted
// budget ceiling, with a "now" tick marking the current UTC hour.
// Why: this is the popover's one real chart, so it gets its own file and
// its own draw(_:) rather than living inline in PopoverView -- the
// polyline/gradient/dash math is dense enough to want isolation, and
// Task 13's draw-on animation only needs to touch drawProgress here.
// RELEVANT FILES: Sources/App/PopoverView.swift, Sources/VelaCore/HistoryStore.swift, Sources/App/StatusItemController.swift

import Cocoa

/// Renders one day's hourly cumulative-spend curve inside a fixed 284x92pt
/// lane. configure(...) sets the data; draw(_:) is pure rendering off that
/// stored state, so appearance changes (light/dark) redraw for free.
@MainActor
public final class CurveView: NSView {
    /// 0 = nothing drawn, 1 = fully drawn. Task 13 animates this 0->1 on
    /// popover open; this file only has to honor it (clip to it), not
    /// animate it.
    public var drawProgress: CGFloat = 1.0 {
        didSet { needsDisplay = true }
    }

    // 24 slots, hourly[h] = cumulative spend as of UTC hour h, nil if that
    // hour hasn't happened yet today.
    private var hourly: [Double?] = Array(repeating: nil, count: 24)
    private var limit: Double = 0
    private var nowHourUTC: Int = 0
    // v0.3.0 ghost: the median day's cumulative curve (same 24-slot shape),
    // drawn beneath today's. nil = no ghost (below the history gate).
    private var ghost: [Double?]? = nil
    // B11: a disabled global limit renders NO ceiling line and no "$400"
    // label — the chart must not draw a ceiling that doesn't exist.
    private var limitEnabled = true
    // The ghost ALWAYS joins the y-scale even when its stroke is suppressed
    // (stale data): otherwise the scale would jump on every fresh↔stale flap,
    // visibly resizing today's curve for a reason the user can't see. The
    // stroke hides when stale; the scale stays put.
    private var drawGhostStroke = true

    // MARK: - Scrub state (v0.5.1)

    /// The scrubbed hour while the pointer is over the lane; nil = no hover.
    /// Set on mouseMoved/Entered (via CurveScrub), cleared on mouseExited.
    /// Drawing it is just two extra strokes in draw(_:) — no view rebuild.
    private var scrub: CurveScrub.ScrubPoint? = nil {
        didSet {
            // Mouse jitter delivers many moved events per second on one point;
            // redraw only when the resolved scrub point changes.
            if scrub != oldValue { needsDisplay = true }
        }
    }
    private var scrubTrackingArea: NSTrackingArea?
    /// The floating readout card ("2 pm · $31.40"). Created on hover, torn
    /// down on exit/popover close. Owns its own level above the popover's
    /// .statusBar — the same hard-won lesson as the VersionBulletView tip.
    private var readoutPanel: NSPanel?
    /// The pointer's lane-x, remembered across a PopoverView rebuild. The 60s
    /// update tears the hierarchy down and re-adds this view, which fires
    /// viewWillMove(toWindow: nil) → clearScrub() and kills the hover — so the
    /// x is stashed on teardown and the hover re-derived in
    /// viewDidMoveToWindow, where `window` is valid again. nil everywhere
    /// else: a scrub that ended for any other reason (mouseExited, midnight
    /// rollover) leaves nothing to restore, so no card can resurrect over a
    /// hover that's already gone.
    private var pendingScrubRestoreX: CGFloat?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        // v0.4.0: back the view with a layer so the draw-on reveal can ride
        // the GPU. The curve content is static during the 0.5s window, so
        // instead of re-running draw(_:) 14 times on a timer (the old
        // DispatchWorkItem steps, which dropped frames), we render ONCE and
        // animate a mask's width 0->full. That's vsync-locked 60fps.
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        fatalError("CurveView does not support NSCoder-based initialization")
    }

    /// Stores the day's data and triggers a redraw. `limit` and `hourly`
    /// come straight from HistoryStore.DayRecord; nowHourUTC positions the
    /// "now" tick. `ghost` is PaceEngine.ghostCurve's output (or nil).
    /// `drawGhostStroke` suppresses ONLY the stroke (stale data) — the ghost
    /// still contributes to the y-scale so the scale never flaps.
    // Rebuild-safe scrub (v0.5.1): PopoverView's 60s update tears the whole
    // hierarchy down and re-adds this view, so `window` is NIL at configure
    // time — the teardown (viewWillMove(toWindow: nil)) has already cleared
    // any hover, and a readout refresh here would have no window to anchor
    // to. The scrub is therefore simply re-derived on the next mouseMoved.
    public func configure(hourly: [Double?], limit: Double, nowHourUTC: Int, ghost: [Double?]? = nil, drawGhostStroke: Bool = true, limitEnabled: Bool = true) {
        self.hourly = hourly
        self.limit = limitEnabled ? limit : 0
        self.limitEnabled = limitEnabled
        self.nowHourUTC = nowHourUTC
        self.ghost = ghost
        self.drawGhostStroke = drawGhostStroke
        // Rebuild-safe scrub (v0.5.1): a hover in progress survives a data
        // tick — re-derive the dot from the FRESH hourly at the pointer's
        // last x (kept in `scrub`), never drop it just because the data
        // ticked, and re-show the card so its text tracks the moved dot. If
        // the re-derive went nil — the UTC-midnight rollover is the case that
        // matters, when the fresh day starts all-nil — the floating card must
        // die with the dot, or it hovers showing yesterday's hour over a dot
        // that no longer exists.
        //
        // All of this only applies while the view STAYS in its window. On a
        // hierarchy rebuild, update() calls configure() AFTER
        // removeFromSuperview but BEFORE re-add: scrub is already nil
        // (viewWillMove cleared it) and window is nil, so there is nothing to
        // re-derive and no way to show a card. That path's hover restore lives
        // in viewDidMoveToWindow — and calling clearScrub() here would wipe
        // the pendingScrubRestoreX it restores from.
        if window != nil {
            if let current = scrub {
                scrub = CurveScrub.scrubPoint(atX: current.x, hourly: hourly, laneWidth: Double(bounds.width))
            }
            if scrub == nil {
                clearScrub()
            } else {
                // The re-derive can move the dot to a new value (fresh data
                // landed under a stationary pointer): the card must follow,
                // or it keeps reading the pre-tick number over a moved dot.
                updateReadout()
            }
        }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let lane = bounds

        // Y scale: driven by the day's data, not the budget ceiling, so
        // the curve occupies real vertical space. The ghost's peak joins
        // the scale too — a big median day must not push the ghost off the
        // top of the lane. The $400 ceiling line still reads as "far above"
        // via the dotted hairline (drawn at the lane top when off-scale).
        // Floor at 25% of limit so a tiny-peak day doesn't zoom to absurdity.
        //
        // v1.0.0: the plot bottoms at `plotBottom`, not lane.minY — see
        // nowLabelGutter. Everything that touches the floor (the value scale,
        // the area fill's base, the tick and crosshair feet) reads it from
        // here, so the label band below stays clear of all of them.
        let peak = max(hourly.compactMap { $0 }.max() ?? 0, ghost?.compactMap { $0 }.max() ?? 0)
        let yMax = max(limit, peak, 1) * 1.08
        let plotBottom = lane.minY + Self.nowLabelGutter
        func y(for value: Double) -> CGFloat { plotBottom + (lane.maxY - plotBottom) * CGFloat(value / yMax) }
        func x(for hour: Int) -> CGFloat { lane.minX + lane.width * CGFloat(hour) / 23.0 }

        // When the budget ceiling is above the visible scale, pin the
        // dotted line to the lane top so it still reads as "way up there".
        let ceilingY = min(y(for: limit), lane.maxY - 8)
        drawBudgetCeiling(in: lane, y: ceilingY)
        drawGhost(in: lane, x: x, y: y)
        drawCurve(in: lane, plotBottom: plotBottom, x: x, y: y)
        drawNowTick(in: lane, plotBottom: plotBottom, x: x(for: nowHourUTC))
        drawScrub(in: lane, plotBottom: plotBottom, x: x, y: y)
    }

    /// Vertical band reserved at the BOTTOM of the lane for the "now" label.
    ///
    /// Why a gutter and not a nudge: the label sat at `lane.minY + 2` while the
    /// curve's $0 baseline sat at `lane.minY` exactly, so on a normal day (spend
    /// far below the ceiling) the stroke ran at ~minY+10 — straight through the
    /// label's ink, which spans roughly minY+4 to minY+9. Moving the label
    /// "down" can't fix that: it has only 2pt left before minY, and the view is
    /// layer-backed (v0.4.0), so anything drawn below `bounds` is clipped away
    /// — which is the exact bug that put the label INSIDE the lane in the first
    /// place. The clearance has to come from the plot floor lifting instead.
    ///
    /// 13pt: the 9pt label's text box is 11pt tall drawn at minY+2 (so it ends
    /// at minY+13), leaving the curve's $0 baseline resting just above it with
    /// a few points of air over the actual glyph tops.
    private static let nowLabelGutter: CGFloat = 13

    /// The median-day ghost: same polyline shape as today's curve, 20%
    /// opacity hairline, drawn BENEATH the main curve. No fill, no label —
    /// the shape is the sentence ("here's what a normal day looks like").
    /// v0.4.0: the draw-on reveal is a whole-layer mask, so the ghost (and
    /// ceiling, and now-tick) wipe in together with the curve — the reveal is
    /// a full-lane sweep, not a curve-only draw-on.
    private func drawGhost(in lane: CGRect, x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        guard let ghost, drawGhostStroke else { return }
        // Break the path at every nil slot (v0.3.1): the engine leaves
        // under-sampled hours nil ON PURPOSE ("gaps stay gaps"), so joining
        // across a nil would draw a confident interpolated line where the
        // honest answer was silence. Each contiguous non-nil run is its own
        // sub-path.
        let stroke = NSBezierPath()
        stroke.lineWidth = Self.hairlineWidth
        stroke.lineJoinStyle = .round
        var penDown = false
        var segmentCount = 0
        for (hour, value) in ghost.enumerated() {
            if let value {
                let point = CGPoint(x: x(hour), y: y(value))
                if penDown { stroke.line(to: point) } else { stroke.move(to: point); penDown = true; segmentCount += 1 }
            } else {
                penDown = false
            }
        }
        guard segmentCount > 0, ghost.contains(where: { $0 != nil }) else { return }
        NSColor.labelColor.withAlphaComponent(0.20).setStroke()
        stroke.stroke()
    }

    /// Dotted hairline at the budget ceiling, with a faint "$400"-style
    /// label at the right edge. Reuses StatusItemController's dash-pattern
    /// idiom (setLineDash via an unsafe buffer).
    private func drawBudgetCeiling(in lane: CGRect, y ceilingY: CGFloat) {
        guard limit > 0 else { return }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: lane.minX, y: ceilingY))
        path.line(to: CGPoint(x: lane.maxX, y: ceilingY))
        path.lineWidth = Self.hairlineWidth
        let pattern: [CGFloat] = [2, 3]
        pattern.withUnsafeBufferPointer { buffer in
            path.setLineDash(buffer.baseAddress, count: 2, phase: 0)
        }
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        path.stroke()

        let text = "$\(Int(limit.rounded()))"
        let font = NSFont.systemFont(ofSize: 9)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.35),
        ])
        let size = attributed.size()
        // v0.4.0: layer-backed now, so the label must stay inside the lane or
        // it's clipped. When the ceiling is pinned to the lane top, drawing at
        // ceilingY + 2 would spill above bounds — tuck the label just under
        // the line instead.
        let labelY = min(ceilingY + 2, lane.maxY - size.height - 1)
        attributed.draw(at: CGPoint(x: lane.maxX - size.width, y: labelY))
    }

    /// Cumulative-spend polyline with a filled area under it. Gaps (nil
    /// slots for hours not yet observed) are skipped by simply omitting
    /// their point -- the segment on either side of a gap draws straight
    /// across it, which reads as "interpolated" without any extra math.
    private func drawCurve(in lane: CGRect, plotBottom: CGFloat, x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        // B15: SEGMENTED observed paths. The old renderer anchored an
        // artificial $0 point at midnight and joined straight across nil
        // gaps — both are claims the data doesn't support. Now each
        // contiguous run of observed hours is its own sub-path; a gap is a
        // visible break, and the line starts at the FIRST OBSERVED hour,
        // never an invented origin.
        let runs = Self.observedRuns(hourly: hourly)
        guard !runs.isEmpty else { return }

        // drawProgress clips the visible curve to its leading fraction --
        // Task 13's draw-on animation just has to set the property.
        let totalPoints = runs.reduce(0) { $0 + $1.count }
        guard totalPoints > 1 else { return }
        var consumed = 0

        for run in runs {
            let points = run.map { (hour: Int, value: Double) in CGPoint(x: x(hour), y: y(value)) }
            consumed += run.count
            // Reveal: show points up to the drawProgress fraction of the
            // whole series; a partially revealed run truncates its tail.
            let fraction = drawProgress.clamped(to: 0...1)
            let budget = Int(CGFloat(totalPoints) * fraction)
            let remaining = budget - (consumed - run.count)
            let visibleCount = max(0, min(run.count, remaining))
            let visible = Array(points.prefix(visibleCount))
            guard visible.count > 1 else { continue }

            if let ctx = NSGraphicsContext.current?.cgContext {
                let area = CGMutablePath()
                area.move(to: CGPoint(x: visible[0].x, y: plotBottom))
                visible.forEach { area.addLine(to: $0) }
                area.addLine(to: CGPoint(x: visible[visible.count - 1].x, y: plotBottom))
                area.closeSubpath()

                ctx.saveGState()
                ctx.addPath(area)
                ctx.clip()
                let colors = [
                    NSColor.labelColor.withAlphaComponent(0.30).cgColor,
                    NSColor.labelColor.withAlphaComponent(0).cgColor,
                ]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: lane.maxY), end: CGPoint(x: 0, y: plotBottom), options: [])
                }
                ctx.restoreGState()
            }

            let stroke = NSBezierPath()
            stroke.move(to: visible[0])
            visible.dropFirst().forEach { stroke.line(to: $0) }
            stroke.lineWidth = 1.75
            stroke.lineJoinStyle = .round
            NSColor.labelColor.setStroke()
            stroke.stroke()
        }
    }

    /// Contiguous runs of observed (non-nil) hours, in hour order. The
    /// segmentation rule for B15: gaps break the path, nothing bridges.
    nonisolated static func observedRuns(hourly: [Double?]) -> [[(hour: Int, value: Double)]] {
        var runs: [[(hour: Int, value: Double)]] = []
        var current: [(hour: Int, value: Double)] = []
        for (hour, value) in hourly.enumerated() {
            if let value {
                current.append((hour, value))
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Thin vertical tick at the current UTC hour's x position, with a
    /// small "now" label centered underneath — in the gutter below the plot,
    /// so the curve's stroke can no longer run through the word (v1.0.0).
    private func drawNowTick(in lane: CGRect, plotBottom: CGFloat, x tickX: CGFloat) {
        let tick = NSBezierPath()
        // The tick stops at the plot floor rather than the lane's: running it
        // into the gutter would strike straight through the label it captions.
        tick.move(to: CGPoint(x: tickX, y: plotBottom))
        tick.line(to: CGPoint(x: tickX, y: lane.maxY))
        tick.lineWidth = 0.75
        NSColor.labelColor.withAlphaComponent(0.30).setStroke()
        tick.stroke()

        let text = "now"
        let font = NSFont.systemFont(ofSize: 9)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.35),
        ])
        let size = attributed.size()
        // The view is layer-backed (v0.4.0), so anything drawn outside `bounds`
        // is clipped — the label must stay INSIDE the lane. It sits at the very
        // bottom, in the reserved gutter; the plot floor is now `plotBottom`
        // above it, so nothing the chart draws reaches down here.
        attributed.draw(at: CGPoint(x: tickX - size.width / 2, y: lane.minY + 2))
    }

    /// One device pixel, in points -- same idiom as StatusItemController's
    /// hairlineWidth, kept local since this file has no shared helpers module.
    private static var hairlineWidth: CGFloat {
        1.0 / (NSScreen.main?.backingScaleFactor ?? 2.0)
    }

    // MARK: - Draw-on reveal (v0.4.0, 60fps)

    /// Reveals the already-drawn curve left-to-right over 0.5s using a
    /// GPU-composited mask animation, instead of re-running draw(_:) on a
    /// timer. Call AFTER configure(...) so the content is current.
    ///
    /// How it works: drawProgress is forced to 1 and the view rendered once,
    /// then a CAShapeLayer mask is attached whose width animates 0 -> full.
    /// Core Animation interpolates the mask on the compositor thread, locked
    /// to vsync -- this is what makes it a true 60fps sweep rather than the
    /// old ~14-step DispatchWorkItem stair-step. A poll mid-animation is now
    /// harmless: configure() just re-renders content under the moving mask.
    ///
    /// Reduce Motion callers skip this entirely (drawProgress stays 1, no
    /// mask) -- the gate lives in main.swift, this method assumes motion is
    /// allowed.
    public func animateReveal() {
        // Force a full, current render so frame 1 of the reveal isn't a
        // half-masked blank. drawProgress=1 means drawCurve shows everything.
        drawProgress = 1
        layoutSubtreeIfNeeded()
        displayIfNeeded()

        guard let layer else { return }

        // A rectangular mask we grow from zero-width to full-width. Using a
        // shape layer keeps the mask crisp; animating its path's width is the
        // cheapest possible reveal (one property, GPU-interpolated).
        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        let fullRect = CGRect(x: 0, y: 0, width: layer.bounds.width, height: layer.bounds.height)
        let zeroRect = CGRect(x: 0, y: 0, width: 0, height: layer.bounds.height)
        // Model value is the FINAL (full-width) path, not the zero-width start.
        // With a CABasicAnimation we then animate FROM zero TO the model value
        // and remove it on completion — so when the animation ends, the layer
        // rests at full width with no lingering presentation-vs-model split.
        // (The old fillMode=.forwards + isRemovedOnCompletion=false pattern
        // left the MODEL path at zero-width: any later mask removal would have
        // snapped the curve to blank. Resting on the model value removes that
        // landmine.)
        mask.path = CGPath(rect: fullRect, transform: nil)
        layer.mask = mask

        let anim = CABasicAnimation(keyPath: "path")
        anim.fromValue = CGPath(rect: zeroRect, transform: nil)
        anim.toValue = CGPath(rect: fullRect, transform: nil)
        anim.duration = 0.5
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        mask.add(anim, forKey: "reveal")
    }

    /// Retained API (PopoverView.animateCurveDrawOn calls it). The sonar
    /// ring it used to re-arm is RETIRED (plan §5.3) — a no-op now.
    public func rearmScrubRing() {}

    // MARK: - Curve scrubber (v0.5.1)

    /// The hover crosshair + value dot. Two strokes: a 0.75pt vertical
    /// hairline at the snapped hour's x, and a filled dot on the curve at
    /// that hour's value. The math (which hour, where it sits) is CurveScrub's
    /// — this only renders its answer.
    private func drawScrub(in lane: CGRect, plotBottom: CGFloat, x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        guard let scrub else { return }
        let cx = x(scrub.hour)

        let line = NSBezierPath()
        // Stops at the plot floor for the same reason the "now" tick does —
        // the gutter below belongs to the label.
        line.move(to: CGPoint(x: cx, y: plotBottom))
        line.line(to: CGPoint(x: cx, y: lane.maxY))
        line.lineWidth = 0.75
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        line.stroke()

        // Filled dot with a hairline ring cut out of it, so it reads on both
        // the curve stroke and the fill beneath.
        let dotRadius: CGFloat = 3.5
        let dotRect = CGRect(x: cx - dotRadius, y: y(scrub.value) - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: 1.5, dy: 1.5)).fill()
        NSColor.labelColor.setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: 2.2, dy: 2.2)).fill()
    }

    // MARK: Tracking

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let scrubTrackingArea { removeTrackingArea(scrubTrackingArea) }
        // .activeAlways: the popover panel never becomes key, so the default
        // active-when-key would never deliver moved/entered/exited. Same fix
        // as VersionBulletView.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        scrubTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { clearScrub(); return }
        let nextScrub = CurveScrub.scrubPoint(atX: Double(local.x), hourly: hourly, laneWidth: Double(bounds.width))
        // Mouse jitter delivers many moved events per second on one point;
        // skip the redraw and panel reposition when the resolved point matches.
        guard nextScrub != scrub else { return }
        scrub = nextScrub
        updateReadout()
    }

    public override func mouseEntered(with event: NSEvent) {
        // v2.0: the sonar introduction is RETIRED (plan §5.3 — charts show
        // interaction through the subtle hover/focus state, no attention
        // pulse). Hover feedback is the crosshair + dot the scrub already
        // draws; nothing animates on entry.
    }

    public override func mouseExited(with event: NSEvent) {
        clearScrub()
    }

    /// PopoverView rebuilds its hierarchy on every update; an open readout
    /// must not outlive the curve that spawned it. Tearing down here (panel
    /// removed from screen) mirrors VersionBulletView's tip teardown.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            // Stash the pointer's lane-x BEFORE clearScrub drops it, so the
            // hover can be rebuilt after the re-add (viewDidMoveToWindow).
            // Only an active scrub stashes — a hover that already ended (or a
            // midnight-rollover clear) leaves nothing to resurrect.
            if let scrub { pendingScrubRestoreX = scrub.x }
            clearScrub()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Rebuild restore: update() re-adds this view right after configure()
        // set the fresh data, so the hover comes back against the NEW hourly —
        // re-derived from the stashed lane-x, the card re-shown now that
        // `window` is valid. A nil re-derive (the day rolled over mid-rebuild)
        // leaves the card dead, which is exactly right.
        if window != nil, let x = pendingScrubRestoreX {
            pendingScrubRestoreX = nil
            scrub = CurveScrub.scrubPoint(atX: Double(x), hourly: hourly, laneWidth: Double(bounds.width))
            if scrub != nil { updateReadout() }
        }
    }

    private func clearScrub() {
        scrub = nil
        // A scrub that ends for real (mouseExited, rollover, a readout that
        // lost its window) must not be restorable — drop any rebuild stash
        // with it, or the next re-add would resurrect a dead hover.
        pendingScrubRestoreX = nil
        // Unparent BEFORE orderOut: the card is a child window of the popover
        // (see updateReadout), and a child left in the list after its view is
        // rebuilt would be ordered out by PopoverPanel.dismiss() against a
        // panel we no longer own — and worse, orderOut alone leaves the
        // popover holding a stale child.
        if let panel = readoutPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        readoutPanel = nil
    }

    // MARK: Readout card

    /// The floating "2 pm · $31.40" card, anchored to the dot. Created once
    /// per hover, updated per move. Level is `.statusBar + 2`: one above the
    /// changelog tip (+1), which is itself above the popover's .statusBar —
    /// the scrubber is the topmost thing the popover can show.
    private func updateReadout() {
        guard let scrub, let parentWindow = window else { clearScrub(); return }

        let text = CurveScrub.readoutText(utcHour: scrub.hour, value: scrub.value)
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        // Measure with a probe label's fittingSize, NOT attributed.size(): the
        // attributed string's tight glyph box under-measures by ~4.5pt (75.1 vs
        // 80.0 for "3 pm · $35.00"), which clipped the trailing money on screen.
        // The label's own fittingSize is the width the text actually needs.
        let probe = NSTextField(labelWithString: "")
        probe.attributedStringValue = attributed
        let textSize = probe.fittingSize
        let padding: CGFloat = 7
        let cardWidth = textSize.width + padding * 2
        let cardHeight = textSize.height + padding * 2

        let panel: NSPanel
        if let existing = readoutPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear

            let content = NSView(frame: NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight))
            let blur = NSVisualEffectView(frame: content.bounds)
            blur.material = .popover
            blur.state = .active
            blur.blendingMode = .behindWindow
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 6
            blur.layer?.masksToBounds = true
            content.addSubview(blur)
            panel.contentView = content
            // Parented to the popover: dismiss() closes child windows in one
            // pass (PopoverPanel.swift), so the card dies WITH the popover
            // instead of orbiting it as an orphan. clearScrub() unparents.
            parentWindow.addChildWindow(panel, ordered: .above)
            readoutPanel = panel
        }
        // Resize the panel AND its content to the new text (v1.0.0 fix). The
        // card is reused as the pointer scrubs, and the readout width varies a
        // lot across the day ("9 am · $4.20" vs "12 pm · $197.33"), so resizing
        // only the window left the content view and its blur at the first
        // hover's size — a frosted slab overhanging the window. Same bug, and
        // same fix, as the day strip's per-day card.
        panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: cardWidth, height: cardHeight)), display: false)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        panel.contentView?.subviews.compactMap { $0 as? NSVisualEffectView }.forEach {
            $0.frame = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)
        }

        // Reuse a single label across moves.
        let label: NSTextField
        if let existing = panel.contentView?.subviews.compactMap({ $0 as? NSTextField }).first {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.isBezeled = false
            label.isEditable = false
            label.backgroundColor = .clear
            panel.contentView?.addSubview(label)
        }
        label.attributedStringValue = attributed
        // textSize is now the label's OWN fittingSize (measured by the probe
        // above), so the frame is exactly wide enough — no slack guesswork.
        label.frame = NSRect(x: padding, y: padding, width: textSize.width, height: textSize.height)

        // Anchor beside the dot: prefer right, flip left near the lane's right
        // edge; vertically centered on the dot. Clamp inside the screen.
        let dotInView = CGPoint(x: CurveScrub.xPosition(forHour: scrub.hour, laneWidth: Double(bounds.width)), y: yOffset(for: scrub.value))
        let dotOnScreen = parentWindow.convertToScreen(NSRect(origin: convert(dotInView, to: nil), size: .zero)).origin
        let curveOnScreen = parentWindow.convertToScreen(convert(bounds, to: nil))
        let gap: CGFloat = 8
        var originX = dotOnScreen.x + gap
        if originX + cardWidth > curveOnScreen.maxX + 40 {
            originX = dotOnScreen.x - gap - cardWidth
        }
        var originY = dotOnScreen.y - cardHeight / 2
        if let visible = (parentWindow.screen ?? NSScreen.main)?.visibleFrame {
            originX = min(max(originX, visible.minX + 4), visible.maxX - cardWidth - 4)
            originY = min(max(originY, visible.minY + 4), visible.maxY - cardHeight - 4)
        }
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFront(nil)
    }

    /// The dot's y in VIEW coordinates, mirroring draw(_:)'s y-scale. The
    /// readout anchors to the dot, so it must resolve the same scale the
    /// curve used. draw(_:)'s lane is `bounds`, so lane.minY is 0 here — and
    /// the plot floor is nowLabelGutter above it (v1.0.0). Keep this in step
    /// with draw(_:)'s `y(for:)` or the card detaches from the dot.
    private func yOffset(for value: Double) -> CGFloat {
        let peak = max(hourly.compactMap { $0 }.max() ?? 0, ghost?.compactMap { $0 }.max() ?? 0)
        let yMax = max(limit, peak, 1) * 1.08
        let plotBottom = bounds.minY + Self.nowLabelGutter
        return plotBottom + (bounds.maxY - plotBottom) * CGFloat(value / yMax)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
