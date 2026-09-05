// Sources/App/DayStripView.swift
// The week strip: seven GitHub-style intensity cells above the footer, one per
// day of the CURRENT Monday–Sunday week. At four or more observed days, each
// cell's fill level is proportional to that day's share of the week's biggest
// day; sparse weeks pin every observed day to level 1 so the stable frame never
// lets a lone day over-claim brightness. Hovering a cell shows that day's cost.
// Why: "is today a big day?" needs the week's shape at a glance. The
// contribution-graph grammar (small rounded cells on a 5-step ramp, a
// weekday letter under each) reads instantly, survives sparse weeks, and
// answers it in 20pt of vertical space without axes. v1.0.0 made the window a
// true calendar week, so the letters are the fixed M T W T F S S the eye can
// learn, and today's ring advances through a stable row instead of the whole
// row re-labelling every morning. Pure rendering off DayStrip.week's output —
// all math (window, intensity, hover text) lives in VelaCore.
// RELEVANT FILES: Sources/VelaCore/DayStrip.swift, Sources/App/PopoverView.swift, Sources/App/CurveView.swift

import Cocoa

@MainActor
public final class DayStripView: NSView {
    /// 10pt cell + 9pt letter strip + 1pt hairline between them. Read by
    /// PopoverView for layout, so the strip's growth stays a one-file change.
    public static let height: CGFloat = 22

    private let week: [DayStrip.Day]

    public init(week: [DayStrip.Day], frame: NSRect) {
        self.week = week
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        fatalError("DayStripView does not support NSCoder-based initialization")
    }

    // Header comment: see top of file.
    //
    // GitHub contribution-graph tokens (adapted from the web research for
    // v0.5.2): 10×10 cells, 2pt radius, a weekday letter under each cell.
    // The user's call: letters stay (the "days of the week" anchor), the
    // month labels + legend are dropped — a 7-cell row doesn't need them.
    //
    // v1.0.0: the letters are STATIC, in column order. The window is a true
    // Monday–Sunday week now, so column i is always the same weekday — no
    // need to parse each day's key to discover which letter it wears (and no
    // way for an unparseable key to leave a column unlabelled).
    private static let weekdayLetters = ["M", "T", "W", "T", "F", "S", "S"] // Mon…Sun

    private static let cellSize: CGFloat = 10
    private static let cellRadius: CGFloat = 2
    private static let letterHeight: CGFloat = 11

    /// The 5-step grey ramp, dark-first (the user lives in dark mode):
    /// level 0 is a hair above the popover background, level 4 nearly solid.
    /// `.textColor` ≈ labelColor without vibrancy — the levels stay distinct
    /// in any context, where the vibrancy of `.labelColor` can wash the low
    /// steps together on a .popover material.
    private static let levels: [CGFloat] = [0.07, 0.20, 0.38, 0.58, 0.85]

    private let letterFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let letterColor = NSColor.secondaryLabelColor.withAlphaComponent(0.6)

    public override func draw(_ dirtyRect: NSRect) {
        guard !week.isEmpty else { return }
        let levels = DayStrip.intensities(week: week)

        // 7 full-width columns (the user's pick over a compact cluster): the
        // cell sits centered in each, keeping the edge-to-edge rhythm the
        // bars had. Cells own the top; the letters sit in a strip at the
        // bottom so the two never collide.
        let columnWidth = bounds.width / CGFloat(week.count)
        let cellsBottom = bounds.minY + Self.letterHeight

        // Hairline under the cells: without it a sparse week renders as
        // floating squares with no column affordance (the v0.3.1 "what are
        // these marks" report — the rule survives the bars→cells swap).
        let hairline = NSBezierPath(rect: NSRect(x: 0, y: cellsBottom, width: bounds.width, height: 0.5))
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        hairline.fill()

        for (index, day) in week.enumerated() {
            // Device-pixel-aligned column centre. THIS is why a cell could look
            // slightly off-centre in its ring, intermittently (v1.0.0 report):
            // 284/7 = 40.571…, so six of the seven raw centres land on
            // fractional points — e.g. Friday's cell origin fell on x=177.571
            // (device pixel 355.14 at 2x). A 10pt square drawn there is
            // antialiased unevenly, more ink on one edge than the other, so the
            // square reads as shifted inside its own ring. It looked
            // intermittent because the hover ring (inset -2) and today's ring
            // (inset -1) each round differently, so the apparent offset came
            // and went with whichever ring happened to be drawn.
            //
            // Rounding the centre to a whole point fixes all of it at once:
            // cellSize is even, so the cell origin, both ring insets, and the
            // letter's centre all stay on whole points — and whole points are
            // whole device pixels at both 1x and 2x. The columns shift by at
            // most half a point, which is invisible; the crisp edges are not.
            let centerX = (columnWidth * CGFloat(index) + columnWidth / 2).rounded()

            // Every column draws a cell. VelaCore resolves sparse weeks as a
            // flat level-1 floor for observed days; gaps and future days stay
            // level 0. The stable grid appears from day one without making a
            // lone observation look like the week's brightest day.
            let level = levels[index]
            let cellRect = NSRect(
                x: centerX - Self.cellSize / 2,
                y: cellsBottom + 1,
                width: Self.cellSize,
                height: Self.cellSize
            )
            NSColor.textColor.withAlphaComponent(Self.levels[level]).setFill()
            NSBezierPath(roundedRect: cellRect, xRadius: Self.cellRadius, yRadius: Self.cellRadius).fill()

            // Today gets a ring: on a quiet week (most cells at the low
            // steps) the "now" edge would otherwise be invisible.
            if day.isToday {
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                let ring = NSBezierPath(roundedRect: cellRect.insetBy(dx: -1, dy: -1), xRadius: Self.cellRadius + 1, yRadius: Self.cellRadius + 1)
                ring.lineWidth = 0.75
                ring.stroke()
            }

            // Hover highlight (v1.0.0): a hairline ring on the hovered cell so
            // the floating cost card is unambiguously ABOUT this column. Drawn
            // after today's ring, so hovering today reads as both.
            if index == hoveredIndex {
                NSColor.labelColor.withAlphaComponent(0.85).setStroke()
                let ring = NSBezierPath(roundedRect: cellRect.insetBy(dx: -2, dy: -2), xRadius: Self.cellRadius + 2, yRadius: Self.cellRadius + 2)
                ring.lineWidth = 1.0
                ring.stroke()
            }

            // The weekday letter under every column. Static M T W T F S S: the
            // window is a fixed Monday–Sunday week, so column i wears a known
            // letter regardless of what its key parses to. Today is slightly
            // stronger to mark the "now" edge.
            let letter = Self.weekdayLetters[index] as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: letterFont,
                .foregroundColor: day.isToday
                    ? NSColor.secondaryLabelColor.withAlphaComponent(0.9)
                    : letterColor,
            ]
            let size = letter.size(withAttributes: attrs)
            letter.draw(at: NSPoint(x: centerX - size.width / 2, y: bounds.minY), withAttributes: attrs)
        }
    }

    // MARK: - Per-day hover (v1.0.0)

    /// The hovered column, or nil. Setting it redraws (for the highlight ring).
    private var hoveredIndex: Int? {
        didSet {
            guard hoveredIndex != oldValue else { return }
            needsDisplay = true
        }
    }
    private var hoverTrackingArea: NSTrackingArea?
    /// The floating cost card ("$42.18"). Same idiom as CurveView's scrub
    /// readout — a borderless non-activating NSPanel above the popover's
    /// .statusBar level. NOT an NSToolTip: this popover is a nonactivating
    /// panel that never becomes key, and AppKit's native tooltips only resolve
    /// through the key window's event path, so they never fire here at all
    /// (the v0.3.2 report that produced VersionBulletView's custom tip).
    private var readoutPanel: NSPanel?
    /// The index currently shown by the card. Repeated mouseMoved events inside
    /// one cell do not need to rebuild or reposition the same panel.
    private var lastReadoutIndex: Int? = nil

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        // .activeAlways + .inVisibleRect: the popover panel never becomes key,
        // so the default active-when-key would never deliver moved/exited —
        // same fix as CurveView's scrub area.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // PopoverView rebuilds its hierarchy on every 60s poll, and a tracking
        // area does NOT reliably re-register on re-parenting inside a
        // nonactivating panel (the v0.5.2 "hover is dead until I click"
        // report, fixed the same way on UpdateBellView).
        if superview != nil { updateTrackingAreas() }
    }

    public override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local), !week.isEmpty else { clearHover(); return }
        let columnWidth = bounds.width / CGFloat(week.count)
        let index = min(week.count - 1, max(0, Int(local.x / columnWidth)))
        hoveredIndex = index
        showReadout(for: index)
    }

    public override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    /// PopoverView rebuilds its hierarchy on every update; an open card must
    /// not outlive the strip that spawned it. Same teardown as CurveView's
    /// readout and VersionBulletView's tip.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { clearHover() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func clearHover() {
        hoveredIndex = nil
        lastReadoutIndex = nil
        // Unparent BEFORE orderOut: the card is a child window of the popover
        // (see showReadout), and PopoverPanel.dismiss() closes child windows
        // in one pass — a card left parented after rebuild would be torn down
        // against a panel we no longer own.
        if let panel = readoutPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        readoutPanel = nil
    }

    /// The floating cost card above the hovered cell. Cost ONLY — the column's
    /// letter and ring already say which day, so repeating the date would be
    /// noise. A no-data day (a past gap or a day still ahead) has no card at
    /// all: DayStrip.hoverText answers nil and the hover stays quiet rather
    /// than asserting "$0.00", which would be a claim we can't make.
    private func showReadout(for index: Int) {
        guard let text = DayStrip.hoverText(total: week[index].total),
              let parentWindow = window else {
            clearHover()
            return
        }
        // Mouse jitter delivers many moved events per second inside one cell;
        // skip rebuilding and repositioning a card that is already shown.
        guard index != lastReadoutIndex || readoutPanel == nil else { return }
        lastReadoutIndex = index

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        // Measure with a probe label's fittingSize, NOT attributed.size(): the
        // attributed string's tight glyph box under-measures by ~4.5pt, which
        // is what clipped the trailing money off the curve's readout (v0.5.2).
        let probe = NSTextField(labelWithString: "")
        probe.attributedStringValue = attributed
        let textSize = probe.fittingSize
        let padding: CGFloat = 6
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
            // Same level as the curve's readout: one above the changelog tip,
            // which is itself above the popover's .statusBar.
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
            // instead of orbiting it as an orphan. clearHover() unparents.
            parentWindow.addChildWindow(panel, ordered: .above)
            readoutPanel = panel
        }
        // Resize the panel AND its content to the new text (v1.0.0 fix). The
        // card is REUSED as the pointer slides between cells, and the money
        // strings differ in width ("$46.65" is 56pt, "$197.33" is 63pt), so
        // resizing only the window left the content view and its blur at the
        // FIRST hover's size — a 63pt frosted slab overhanging a 56pt window
        // by 7pt. It looked like an off-centre cell, and only reproduced when
        // arriving from a NEIGHBOUR (coming from above builds a fresh card at
        // the correct size, which is why hovering straight down looked fine).
        //
        // autoresizing can't be relied on here: the content view is installed
        // as the panel's contentView, so its resize behaviour is AppKit's to
        // decide. Setting both frames explicitly is the version that can't
        // drift.
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
        label.frame = NSRect(x: padding, y: padding, width: textSize.width, height: textSize.height)

        // Centered ABOVE the hovered cell (the strip sits on the footer rule,
        // so there's no room below it). Clamped inside the visible screen.
        // The centre is rounded exactly as draw(_:) rounds it, so the card
        // points at where the cell actually IS, not at the raw column centre.
        let columnWidth = bounds.width / CGFloat(week.count)
        let cellCenterX = (columnWidth * CGFloat(index) + columnWidth / 2).rounded()
        let cellCenter = CGPoint(x: cellCenterX, y: bounds.maxY)
        let cellOnScreen = parentWindow.convertToScreen(NSRect(origin: convert(cellCenter, to: nil), size: .zero)).origin
        var originX = cellOnScreen.x - cardWidth / 2
        var originY = cellOnScreen.y + 6
        if let visible = (parentWindow.screen ?? NSScreen.main)?.visibleFrame {
            originX = min(max(originX, visible.minX + 4), visible.maxX - cardWidth - 4)
            originY = min(max(originY, visible.minY + 4), visible.maxY - cardHeight - 4)
        }
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFront(nil)
    }
}
