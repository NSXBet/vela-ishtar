// Sources/App/StatusItemController.swift
// Renders the menu bar pill (sparkline + amount + budget-tracing border)
// and owns the NSStatusItem that displays it.
// Why: this pill is the app's signature visual -- the border traces
// used_percent clockwise from top-center so the daily budget is legible
// at a glance without opening the popover. The border literally IS the
// budget gauge.
// RELEVANT FILES: Sources/VelaCore/BorderDash.swift, Sources/VelaCore/BurnBuffer.swift, Sources/VelaCore/PollStateMachine.swift, Sources/App/UsagePoller.swift

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

    // Pill geometry, in points -- matches the locked design spec.
    private static let pillSize = NSSize(width: 88, height: 22)
    private static let cornerRadius: CGFloat = 6

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

        let initialBuffer = BurnBuffer()
        button.image = makeImage(state: .neverFetched, burnBuffer: initialBuffer, appearance: button.effectiveAppearance)
        lastState = .neverFetched
        lastBurnBuffer = initialBuffer

        // A light/dark switch is render-worthy too (different ink colors resolve), but still discrete.
        // KVO's callback isn't statically MainActor -- hop over explicitly since this class is @MainActor.
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] btn, _ in
            Task { @MainActor in
                guard let self, let state = self.lastState, let buffer = self.lastBurnBuffer else { return }
                btn.image = self.makeImage(state: state, burnBuffer: buffer, appearance: btn.effectiveAppearance)
            }
        }
    }

    /// Re-renders only if `state` or `burnBuffer` actually changed since the last call (or install()'s initial draw).
    public func render(state: PollState, burnBuffer: BurnBuffer) {
        if let lastState, let lastBurnBuffer, lastState == state, lastBurnBuffer == burnBuffer {
            return
        }
        lastState = state
        lastBurnBuffer = burnBuffer
        guard let button = statusItem?.button else { return }
        button.image = makeImage(state: state, burnBuffer: burnBuffer, appearance: button.effectiveAppearance)
    }

    @objc private func clicked() {
        onClick?()
    }

    // MARK: - Rendering

    /// Pure render: turns a (state, burnBuffer) pair into an NSImage under
    /// the given appearance. Used by install() and by the snapshot tool
    /// (which fabricates arbitrary states without a real UsagePoller).
    public func makeImage(state: PollState, burnBuffer: BurnBuffer, appearance: NSAppearance) -> NSImage {
        let image = NSImage(size: Self.pillSize, flipped: false) { rect in
            // Resolve semantic colors under the TARGET appearance, not the ambient one -- snapshots need to force light/dark.
            var (ink, secondary, orange, red) = (NSColor.labelColor, NSColor.secondaryLabelColor, NSColor.systemOrange, NSColor.systemRed)
            appearance.performAsCurrentDrawingAppearance {
                (ink, secondary, orange, red) = (.labelColor, .secondaryLabelColor, .systemOrange, .systemRed)
            }
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let (usedPercent, limitEnabled) = Self.budgetFields(for: state)
            // The lane gets whatever width the amount doesn't need (6pt gap) --
            // a fixed-width lane overlapped long amounts like "$231.40".
            let amountWidth = Self.amountWidth(for: state)
            let laneWidth = max(rect.width - 8 - 6 - amountWidth - 8 - rect.minX * 0, 0)
            let sparklineLane = CGRect(x: rect.minX + 8, y: rect.minY + (rect.height - 14) / 2, width: laneWidth, height: 14)

            switch state {
            case .stale:
                // Everything dims to 55% and the amount switches to
                // secondaryLabelColor -- staleness overrides the "border
                // stays full strength" exception below.
                ctx.saveGState()
                ctx.setAlpha(0.55)
                Self.drawBorder(rect: rect, usedPercent: usedPercent, limitEnabled: limitEnabled, ink: ink, orange: orange, red: red)
                Self.drawSparkline(lane: sparklineLane, burnBuffer: burnBuffer, ink: ink)
                Self.drawAmount(pillRect: rect, text: Self.amountText(for: state), color: secondary)
                ctx.restoreGState()

            case .fresh, .neverFetched:
                // Border draws at full strength always -- it's the alarm and
                // must not dim even when exhausted. Only contents dim then.
                let exhausted = limitEnabled && BorderDash.isFull(usedPercent / 100.0)
                Self.drawBorder(rect: rect, usedPercent: usedPercent, limitEnabled: limitEnabled, ink: ink, orange: orange, red: red)
                ctx.saveGState()
                ctx.setAlpha(exhausted ? 0.55 : 1.0)
                Self.drawSparkline(lane: sparklineLane, burnBuffer: burnBuffer, ink: ink)
                Self.drawAmount(pillRect: rect, text: Self.amountText(for: state), color: ink)
                ctx.restoreGState()
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

    private static func amountText(for state: PollState) -> String {
        switch state {
        case .neverFetched:
            return "—"
        case .fresh(let usage), .stale(let usage, _):
            return String(format: "$%.2f", usage.dailyBudget.spentUSD)
        }
    }

    /// The border-is-the-budget trace. f = usedPercent / 100 (the API is
    /// 0...100, BorderDash's math is 0...1 -- this divide is the one place
    /// that conversion happens).
    /// f<=0 or !limitEnabled -> faint full outline, no trace.
    /// 0<f<0.85 -> faint outline + ink-70% trace. 0.85<=f<1 -> + orange
    /// trace. f>=1 -> solid closed loop in systemRed (no faint outline).
    private static func drawBorder(rect: CGRect, usedPercent: Double, limitEnabled: Bool, ink: NSColor, orange: NSColor, red: NSColor) {
        let borderRect = rect.insetBy(dx: 0.75, dy: 0.75)
        let r = min(cornerRadius, min(borderRect.width, borderRect.height) / 2)
        let path = clockwiseRoundedRectPath(in: borderRect, cornerRadius: r)
        path.lineWidth = 1.5

        let f = usedPercent / 100.0

        if limitEnabled, BorderDash.isFull(f) {
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

        guard limitEnabled, f > 0 else { return }

        let perimeter = BorderDash.perimeter(width: Double(borderRect.width), height: Double(borderRect.height), cornerRadius: Double(r))
        guard let pattern = BorderDash.pattern(forFraction: f, perimeter: perimeter) else { return }

        applyDash(path, on: CGFloat(pattern.on), off: CGFloat(pattern.off), phase: CGFloat(BorderDash.phase(perimeter: perimeter)))
        (f < 0.85 ? ink.withAlphaComponent(0.70) : orange).setStroke()
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

    private static func drawLeadingDot(at point: CGPoint, ink: NSColor) {
        let r: CGFloat = 1.5
        let dot = NSBezierPath(ovalIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        ink.withAlphaComponent(1.0).setFill()
        dot.fill()
    }

    /// Right-aligned, 8pt from the pill's right edge, vertically centered.
    /// Measured width of the amount text at the pill's font, so the
    /// sparkline lane can give it exactly the room it needs.
    private static func amountWidth(for state: PollState) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let text = amountText(for: state)
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
