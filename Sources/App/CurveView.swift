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
    // The ghost ALWAYS joins the y-scale even when its stroke is suppressed
    // (stale data): otherwise the scale would jump on every fresh↔stale flap,
    // visibly resizing today's curve for a reason the user can't see. The
    // stroke hides when stale; the scale stays put.
    private var drawGhostStroke = true

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
    public func configure(hourly: [Double?], limit: Double, nowHourUTC: Int, ghost: [Double?]? = nil, drawGhostStroke: Bool = true) {
        self.hourly = hourly
        self.limit = limit
        self.nowHourUTC = nowHourUTC
        self.ghost = ghost
        self.drawGhostStroke = drawGhostStroke
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
        let peak = max(hourly.compactMap { $0 }.max() ?? 0, ghost?.compactMap { $0 }.max() ?? 0)
        let yMax = max(limit, peak, 1) * 1.08
        func y(for value: Double) -> CGFloat { lane.minY + lane.height * CGFloat(value / yMax) }
        func x(for hour: Int) -> CGFloat { lane.minX + lane.width * CGFloat(hour) / 23.0 }

        // When the budget ceiling is above the visible scale, pin the
        // dotted line to the lane top so it still reads as "way up there".
        let ceilingY = min(y(for: limit), lane.maxY - 8)
        drawBudgetCeiling(in: lane, y: ceilingY)
        drawGhost(in: lane, x: x, y: y)
        drawCurve(in: lane, x: x, y: y)
        drawNowTick(in: lane, x: x(for: nowHourUTC))
    }

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
    private func drawCurve(in lane: CGRect, x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        // The curve reads as a DAY, not a stub: anchor the line at $0 on
        // the left edge (midnight UTC) so its shape is visible even when
        // only a few late hours have data (e.g. app restarted mid-day).
        var points: [CGPoint] = [CGPoint(x: x(0), y: y(0))]
        points.append(contentsOf: hourly.enumerated().compactMap { hour, value in
            guard let value else { return nil }
            return CGPoint(x: x(hour), y: y(value))
        })
        guard points.count > 1 else { return }

        // drawProgress clips the visible curve to its leading fraction --
        // Task 13's draw-on animation just has to set the property.
        let visibleCount = max(2, Int(CGFloat(points.count) * drawProgress.clamped(to: 0...1)))
        let visible = Array(points.prefix(visibleCount))
        guard visible.count > 1 else { return }

        if let ctx = NSGraphicsContext.current?.cgContext {
            let area = CGMutablePath()
            area.move(to: CGPoint(x: visible[0].x, y: lane.minY))
            visible.forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: visible[visible.count - 1].x, y: lane.minY))
            area.closeSubpath()

            ctx.saveGState()
            ctx.addPath(area)
            ctx.clip()
            let colors = [
                NSColor.labelColor.withAlphaComponent(0.30).cgColor,
                NSColor.labelColor.withAlphaComponent(0).cgColor,
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: lane.maxY), end: CGPoint(x: 0, y: lane.minY), options: [])
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

    /// Thin vertical tick at the current UTC hour's x position, with a
    /// small "now" label centered underneath.
    private func drawNowTick(in lane: CGRect, x tickX: CGFloat) {
        let tick = NSBezierPath()
        tick.move(to: CGPoint(x: tickX, y: lane.minY))
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
        // v0.4.0: the view is layer-backed now, so anything drawn outside
        // `bounds` is clipped. The "now" label used to hang BELOW the lane
        // (minY - height); draw it just INSIDE the bottom edge instead.
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
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
