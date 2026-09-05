// Tools/FixtureViews/BudgetDetailFixtureView.swift
// Extracted from Tools/design_fixture_main.swift (WP-05): budget-detail
// fixture surface (all caps + marker receipts). See SummaryFixtureView.swift
// for the extraction rationale.
// RELEVANT FILES: Tools/design_fixture_main.swift, Sources/App/DesignTokens.swift

import AppKit

// MARK: - Budget detail fixture (§5.1 secondary-panel treatment)

/// The secondary "budget detail" surface: every cap as its own row (headroom,
/// cooldown, blocked), plus one marker receipt block showing a measured delta
/// and an explicitly-unavailable one — MarkerReceipt (§7.2) rendered.
@MainActor
final class BudgetDetailFixtureView: NSView, FixtureAppearing {
    let budget: BudgetOverview
    var fixtureAppearance: NSAppearance = NSAppearance(named: .aqua)!

    func resolve(_ build: () -> NSColor) -> NSColor {
        resolveBuild(fixtureAppearance, build)
    }

    init(budget: BudgetOverview) {
        self.budget = budget
        super.init(frame: NSRect(x: 0, y: 0, width: VelaDesign.Layout.summaryWidth, height: 300))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    private var yOffset: CGFloat = 0
    private var rows: [NSView] = []

    private func add(_ view: NSView, height: CGFloat) {
        view.frame.origin.y = bounds.height - yOffset - height
        addSubview(view)
        rows.append(view)
        yOffset += height
    }

    private var inset: CGFloat { VelaDesign.Layout.contentInset }
    private var contentWidth: CGFloat { bounds.width - 2 * inset }

    func layoutContent() {
        // Compute the height FIRST (named section arithmetic), size the frame,
        // then place rows bottom-anchored — placing against a frame that
        // later shrinks clips everything below the shrink.
        let height: CGFloat = 12
            + CGFloat(budget.modelSignals.count) * 44 // one note line per cap (worst case)
            + 0.5
            + 18                                     // MARKER header
            + 44 + 44 + 16                           // two marker rows + caption
            + 12
        setFrameSize(NSSize(width: bounds.width, height: height))
        yOffset = 0
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        add(sectionHeader("MODEL CAPS"), height: 18)
        for signal in budget.modelSignals {
            add(capDetailRow(signal), height: signal.note == nil ? 32 : 44)
        }
        add(hairline(), height: 0.5)
        yOffset += VelaDesign.Layout.sectionSpacing

        add(sectionHeader("MARKER — “opus experiment”"), height: 18)
        add(markerRow(name: "Measured delta", value: "$12.40",
                      note: "Since 09:02 · exact receipt · 2 observations · scope unchanged"), height: 44)
        add(markerRow(name: "Blocked example", value: "Unavailable",
                      note: "No baseline observation exists at or before the marker start"), height: 44)
        add(caption("Markers never invent a number — an unmeasurable interval says why.", width: contentWidth), height: 16)
        yOffset += 12
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = VelaDesign.Typography.sectionLabel
        label.textColor = resolve { VelaDesign.Color.sectionLabel }
        label.frame = NSRect(x: inset, y: 0, width: 260, height: 14)
        return label
    }

    private func hairline() -> NSView {
        let line = NSView(frame: NSRect(x: inset, y: 0, width: contentWidth, height: 0.5))
        line.wantsLayer = true
        line.layer?.backgroundColor = resolve { VelaDesign.Color.hairline(contrast: false) }.cgColor
        return line
    }

    private func caption(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = VelaDesign.Typography.secondary
        label.textColor = resolve { VelaDesign.Color.caption(contrast: false) }
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: inset, y: 0, width: width, height: 14)
        return label
    }

    private func capDetailRow(_ signal: BudgetOverview.ModelSignal) -> NSView {
        detailRow(name: signal.model.split(separator: "/").last.map(String.init) ?? signal.model,
                  value: signal.limitUSD.map { "$\(fmt(signal.spentUSD)) of $\(fmt($0))" } ?? "no cap",
                  note: signal.note,
                  fraction: signal.limitUSD.map { limit in limit > 0 ? min(signal.spentUSD / limit, 1) : 1 },
                  kind: signal.fillKind)
    }

    private func markerRow(name: String, value: String, note: String) -> NSView {
        detailRow(name: name, value: value, note: note, fraction: nil, kind: .neutral)
    }

    private func detailRow(name: String, value: String, note: String?, fraction: Double?, kind: VelaDesign.Color.BudgetFillKind) -> NSView {
        let rowHeight: CGFloat = note == nil ? 32 : 44
        let row = NSView(frame: NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight))
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = VelaDesign.Typography.body
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        // 44pt rows stack: name top, note bottom (no overlap); 32pt rows
        // center the name.
        nameLabel.frame = NSRect(x: inset, y: note == nil ? 8 : 24, width: 170, height: 18)
        row.addSubview(nameLabel)
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = VelaDesign.Typography.budgetValue
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right
        let valueW = ceil((value as NSString).size(withAttributes: [.font: VelaDesign.Typography.budgetValue]).width)
        valueLabel.frame = NSRect(x: bounds.width - inset - valueW, y: note == nil ? 8 : 24, width: valueW, height: 16)
        row.addSubview(valueLabel)
        if let fraction {
            let trackX = inset + 170 + 12
            let trackW = bounds.width - inset - valueW - 12 - trackX
            if trackW > 24 {
                let track = NSView(frame: NSRect(x: trackX, y: note == nil ? 15 : 20, width: trackW, height: 2))
                track.wantsLayer = true
                track.layer?.backgroundColor = resolve { VelaDesign.Color.trackBackground(contrast: false) }.cgColor
                track.layer?.cornerRadius = 1
                track.layer?.masksToBounds = true
                let fill = NSView(frame: NSRect(x: 0, y: 0, width: track.bounds.width * fraction, height: 2))
                fill.wantsLayer = true
                fill.layer?.backgroundColor = VelaDesign.Color.trackFill(kind: kind).cgColor
                track.addSubview(fill)
                row.addSubview(track)
            }
        }
        if let note {
            let noteLabel = caption(note, width: contentWidth)
            noteLabel.frame.origin.y = 4
            row.addSubview(noteLabel)
        }
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(name)
        row.setAccessibilityValue(note.map { "\(value). \($0)" } ?? value)
        return row
    }
}

// Shared per-signal helpers used by BudgetDetailFixtureView rows.
extension BudgetOverview.ModelSignal {
    /// Detail-row fill color: blocked = alarm, relaxed = neutral (a bypass is
    /// active, the cap is not binding), otherwise the spend band.
    fileprivate var fillKind: VelaDesign.Color.BudgetFillKind {
        if limitUSD == 0 { return .alarm }
        if relaxedUntil != nil { return .neutral }
        guard let limit = limitUSD, limit > 0 else { return .neutral }
        let f = spentUSD / limit
        if f >= 0.9 { return .alarm }
        if f >= 0.75 { return .amber }
        if f >= 0.5 { return .notice }
        return .neutral
    }

    /// Detail-row note: the state sentence a cap row must be able to say.
    fileprivate var note: String? {
        if limitUSD == 0 { return "Blocked — this model's cap is $0" }
        if let relaxed = relaxedUntil {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            formatter.timeZone = TimeZone(identifier: "UTC")!
            return "Cooldown bypass active until \(formatter.string(from: relaxed)) UTC"
        }
        return nil
    }
}
