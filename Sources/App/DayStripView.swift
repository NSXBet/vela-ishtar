// Sources/App/DayStripView.swift
// The 7-day strip: seven hairline bars under the TODAY curve, one per
// gateway day ending at today, each bar's height ∝ that day's total.
// Why: "is today a big day?" needs the week's shape at a glance; the strip
// answers it in 14pt of vertical space without axes or labels. Pure
// rendering off DayStrip.week's output — all math lives in VelaCore.
// RELEVANT FILES: Sources/VelaCore/DayStrip.swift, Sources/App/PopoverView.swift, Sources/App/CurveView.swift

import Cocoa

@MainActor
public final class DayStripView: NSView {
    public static let height: CGFloat = 14

    private let week: [DayStrip.Day]

    public init(week: [DayStrip.Day], frame: NSRect) {
        self.week = week
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        fatalError("DayStripView does not support NSCoder-based initialization")
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !week.isEmpty else { return }
        let maxTotal = week.compactMap(\.total).max() ?? 0

        // 7 equal columns; each bar is a 2pt-wide hairline centered in its
        // column, bottom-aligned, height ∝ total / maxTotal. Gaps (nil
        // total) draw nothing — an empty slot reads as "no data," not "$0".
        let columnWidth = bounds.width / CGFloat(week.count)
        for (index, day) in week.enumerated() {
            guard let total = day.total, maxTotal > 0 else { continue }
            let fraction = CGFloat(total / maxTotal)
            // Floor at 1pt so a nonzero day never vanishes next to a giant one.
            let barHeight = max(1, fraction * (bounds.height - 3))
            let x = columnWidth * CGFloat(index) + (columnWidth - 2) / 2
            let bar = NSBezierPath(rect: NSRect(x: x, y: bounds.minY, width: 2, height: barHeight))

            // Today is full-strength; past days fade with distance into the
            // week (oldest faintest) — the eye lands on the right edge.
            let ageFraction = CGFloat(index) / CGFloat(max(week.count - 1, 1))
            let alpha: CGFloat = day.isToday ? 0.85 : 0.22 + 0.38 * ageFraction
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            bar.fill()

            // Scar: a 1px tick on top of a day that hit its budget.
            if day.exhausted {
                let scar = NSBezierPath(rect: NSRect(x: x - 1, y: bounds.minY + barHeight + 1, width: 4, height: 1))
                NSColor.systemRed.withAlphaComponent(0.75).setFill()
                scar.fill()
            }
        }
    }
}
