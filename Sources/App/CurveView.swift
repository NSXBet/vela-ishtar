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
    /// Not clipped by drawProgress: the ghost is context, not the reveal.
    private func drawGhost(in lane: CGRect, x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        guard let ghost, drawGhostStroke else { return }
        let points: [CGPoint] = ghost.enumerated().compactMap { hour, value in
            guard let value else { return nil }
            return CGPoint(x: x(hour), y: y(value))
        }
        guard points.count > 1 else { return }

        let stroke = NSBezierPath()
        stroke.move(to: points[0])
        points.dropFirst().forEach { stroke.line(to: $0) }
        stroke.lineWidth = Self.hairlineWidth
        stroke.lineJoinStyle = .round
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
        attributed.draw(at: CGPoint(x: lane.maxX - size.width, y: ceilingY + 2))
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
        attributed.draw(at: CGPoint(x: tickX - size.width / 2, y: lane.minY - size.height))
    }

    /// One device pixel, in points -- same idiom as StatusItemController's
    /// hairlineWidth, kept local since this file has no shared helpers module.
    private static var hairlineWidth: CGFloat {
        1.0 / (NSScreen.main?.backingScaleFactor ?? 2.0)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
