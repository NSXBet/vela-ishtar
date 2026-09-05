// Tools/FixtureViews/SummaryFixtureView.swift
// Extracted from Tools/design_fixture_main.swift (WP-05): the ~470-line 360pt
// summary fixture view lives in its own file to keep the tool under the
// ~300 LOC/file standing limit. Compiled together with the fixture tool.
// RELEVANT FILES: Tools/design_fixture_main.swift, Sources/App/DesignTokens.swift, docs/v2/DESIGN.md

import AppKit

// MARK: - The v2 summary fixture view (renders FROM the frozen contracts)

/// Renders the §5.2 hierarchy at 360pt from contract values. Deliberately a
/// fixture-only renderer (not app code): it exists so reviewers can approve
/// the 360pt design before WP-06 builds the live presenter from the same
/// SummaryDisplayState. No I/O, no timers, no animation — a still frame.
@MainActor
final class SummaryFixtureView: NSView, FixtureAppearing {
    let budget: BudgetOverview
    let breakdown: ModelBreakdownState
    let monthTop: [ModelUsage]
    let width: CGFloat
    /// §5.4 variants: Increase Contrast lifts separator/caption inks; Reduce
    /// Transparency swaps the material for the opaque fallback (rendered by
    /// putting the summary on the busy backdrop, plus tokens' opaque colors).
    var increaseContrast = false
    var reduceTransparency = false

    init(width: CGFloat, budget: BudgetOverview, breakdown: ModelBreakdownState,
         monthTop: [ModelUsage]) {
        self.width = width
        self.budget = budget
        self.breakdown = breakdown
        self.monthTop = monthTop
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 470))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("no coder") }

    private var yOffset: CGFloat = 0
    /// The appearance this fixture renders under — set by renderPNG before
    /// layout. Every wrapped ink resolves through `resolve` against it,
    /// because a windowless view resolves dynamic colors against the app's
    /// current appearance (wrong for one of the two passes).
    var fixtureAppearance: NSAppearance = NSAppearance(named: .aqua)!
    /// Builds + resolves the token ink INSIDE the fixture's appearance scope
    /// (see resolveBuild — instance caching makes pass-in resolution wrong).
    func resolve(_ build: () -> NSColor) -> NSColor {
        resolveBuild(fixtureAppearance, build)
    }

    private var rows: [NSView] = []

    private func add(_ view: NSView, height: CGFloat) {
        view.frame.origin.y = bounds.height - yOffset - height
        addSubview(view)
        rows.append(view)
        yOffset += height
    }

    private var inset: CGFloat { VelaDesign.Layout.contentInset }
    private var contentWidth: CGFloat { width - 2 * inset }

    /// One-pass layout; computes the final height first (from named slots),
    /// then places rows bottom-anchored. No self-recursion: the height pass
    /// and the placement pass are the same loop against a pre-sized frame.
    func layoutContent() {
        let contrast = increaseContrast
        let now = fixtureNow()
        yOffset = 0
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        setFrameSize(NSSize(width: width, height: estimateHeight()))

        // 1. Section label row: TODAY + Settings control (≥24pt hit target).
        let header = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        let todayLabel = NSTextField(labelWithString: "TODAY")
        todayLabel.font = VelaDesign.Typography.sectionLabel
        // Resolved under the EXPLICIT appearance: withAlphaComponent colors
        // resolve lazily, and the fixture has no window to inherit one from —
        // resolving at draw time resolved the CURRENT app appearance instead
        // (the "dark ink in the light render" bug).
        todayLabel.textColor = resolve { VelaDesign.Color.sectionLabel }
        todayLabel.frame = NSRect(x: inset, y: 2, width: 60, height: 14)
        header.addSubview(todayLabel)
        let settings = NSButton(title: "Settings", target: nil, action: nil)
        settings.isBordered = false
        settings.bezelStyle = .inline
        settings.font = VelaDesign.Typography.secondaryInteractive
        settings.contentTintColor = .secondaryLabelColor
        let settingsW: CGFloat = 64
        settings.frame = NSRect(x: width - inset - settingsW, y: 0, width: settingsW,
                                height: VelaDesign.Rows.controlMinHeight)
        header.addSubview(settings)
        add(header, height: 18)

        // 2. Hero: 30pt semibold tabular amount + baseline suffix. Reserved
        // hero width — the $9,999.99 worst case sizes the slot, not the sample.
        // Unlimited still shows the REAL spend — "$0.00" would lie.
        let heroText = String(format: "$%.2f", budget.globalSpentUSD)
        let heroW = ceil((heroText as NSString).size(withAttributes: [.font: VelaDesign.Typography.hero]).width)
        let hero = NSTextField(labelWithString: heroText)
        hero.font = VelaDesign.Typography.hero
        hero.textColor = .labelColor
        hero.frame = NSRect(x: inset, y: 0, width: heroW + 2, height: 30)
        add(hero, height: 34)

        // 3. Remaining-of-limit line, right of the hero's baseline.
        let suffixText = budget.globalLimitEnabled
            ? String(format: "$%.2f remaining of $%.0f", max(budget.globalLimitUSD - budget.globalSpentUSD, 0), budget.globalLimitUSD)
            : "No daily limit"
        let suffix = NSTextField(labelWithString: suffixText)
        suffix.font = VelaDesign.Typography.heroSuffix
        suffix.textColor = .secondaryLabelColor
        suffix.frame = NSRect(x: inset, y: 0, width: contentWidth, height: 18)
        add(suffix, height: 18)

        // 4. Reserved status slot — EVERY state fills it (§5.3: meaningful
        // neutral content, never an unexplained blank hole).
        add(statusSlot(contrast: contrast), height: VelaDesign.Rows.statusSlotHeight)

        // 5. Most urgent model cap row (spend ÷ cap, color by band).
        if let signal = budget.modelSignals.first(where: { $0.limitUSD != nil }) {
            add(capRow(signal), height: 32)
        }
        add(hairline(contentWidth, contrast: contrast), height: 0.5)

        // 6. Today's observations lane + caption.
        yOffset += VelaDesign.Layout.sectionSpacing
        add(sectionLabel("TODAY'S OBSERVATIONS"), height: 14)
        // No spend yet → an EMPTY lane (dotted ceiling only). A fabricated
        // curve would contradict the $0 hero and the "no spend" copy.
        let hasObservations = budget.globalSpentUSD > 0
        let curve = CurveView(frame: NSRect(x: inset, y: 0, width: contentWidth, height: 92))
        curve.configure(hourly: hasObservations ? fixtureHourly() : Array(repeating: nil, count: 24),
                        limit: budget.globalLimitUSD,
                        nowHourUTC: 12, ghost: nil, drawGhostStroke: false)
        curve.drawProgress = 1
        add(curve, height: 92)
        let curveNoteText = hasObservations
            ? "Comparison available only with enough history"
            : "No observations recorded yet today"
        let curveNote = caption(curveNoteText, width: contentWidth, contrast: contrast)
        add(curveNote, height: 16)

        add(hairline(contentWidth, contrast: contrast), height: 0.5)

        // 7. Models section: label + scope total + Today/Month switcher, then
        // the ALWAYS-five-row block (never-resize guarantee, carried from v1).
        add(modelsHeader(), height: 26)
        add(modelsBlock(contrast: contrast), height: CGFloat(VelaDesign.Rows.maxModelRows) * VelaDesign.Rows.dataRowStride)

        add(hairline(contentWidth, contrast: contrast), height: 0.5)

        // 8. History strip: M T W T F S S cells; a gap day is a visible,
        // unfilled cell — an explained empty slot, not dead air.
        add(historyStrip(), height: 24)

        // 9. Secondary navigation row.
        add(secondaryNav(), height: 28)

        // Bottom pad.
        yOffset += 12
        // Second pass: rows were placed against the estimate; now shift to
        // their true positions by re-framing against the final height.
        let finalHeight = estimateHeight()
        setFrameSize(NSSize(width: width, height: finalHeight))
    }

    /// Height arithmetic duplicated from layoutContent's named adds — both
    /// must list the same sections. Cheap (a dozen constants) and keeps
    /// layoutContent free of two-phase bookkeeping.
    private func estimateHeight() -> CGFloat {
        var h: CGFloat = 12   // top pad
        h += 18               // header
        h += 34               // hero
        h += 18               // remaining line
        h += VelaDesign.Rows.statusSlotHeight
        if budget.modelSignals.contains(where: { $0.limitUSD != nil }) { h += 32 }
        h += 0.5              // hairline
        h += VelaDesign.Layout.sectionSpacing + 14 + 92 + 16   // observations
        h += 0.5              // hairline
        h += 26               // models header
        h += CGFloat(VelaDesign.Rows.maxModelRows) * VelaDesign.Rows.dataRowStride
        h += 0.5              // hairline
        h += 24               // history strip
        h += 28               // nav row
        h += 12               // bottom pad
        return h
    }

    // MARK: section builders

    /// Reserved status slot: neutral freshness line for fresh states; tinted
    /// band (border + label) for stale/auth/error. Band height constant so
    /// the card's geometry never breathes between states.
    private func statusSlot(contrast: Bool) -> NSView {
        let slot = NSView(frame: NSRect(x: 0, y: 0, width: width, height: VelaDesign.Rows.statusSlotHeight))
        let text: String
        var kind: VelaDesign.Color.StatusKind = .neutral
        switch budget.freshness {
        case .fresh:
            text = "Latest observation · 12:31 · \(budget.resetDescription)"
        case .stale(let last):
            kind = .notice
            let stamp = last.map { Self.clock.string(from: $0) } ?? "—"
            text = "AI Hub unreachable — retrying. Data last received \(stamp) UTC."
        case .invalidated(let reason):
            kind = .alarm
            text = reason
        }
        if kind == .neutral {
            let line = caption(text, width: contentWidth, contrast: contrast)
            line.frame.origin.y = 8
            slot.addSubview(line)
        } else {
            let band = NSView(frame: NSRect(x: inset, y: 2, width: contentWidth, height: 28))
            band.wantsLayer = true
            let tint = (resolve { VelaDesign.Color.statusBand(kind: kind, contrast: contrast).background },
                        resolve { VelaDesign.Color.statusBand(kind: kind, contrast: contrast).border })
            band.layer?.backgroundColor = tint.0.cgColor
            band.layer?.borderColor = tint.1.cgColor
            band.layer?.borderWidth = 1
            band.layer?.cornerRadius = 7
            let label = NSTextField(labelWithString: text)
            label.font = VelaDesign.Typography.secondaryInteractive
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 8, y: 7, width: band.bounds.width - 16, height: 15)
            band.addSubview(label)
            band.setAccessibilityElement(true)
            band.setAccessibilityLabel("Connection status")
        }
        return slot
    }

    /// One cap row: name (truncate tail, full route in a11y) · 2pt track ·
    /// "$spent of $limit" (tabular, right).
    private func capRow(_ signal: BudgetOverview.ModelSignal) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        let name = signal.model.split(separator: "/").last.map(String.init) ?? signal.model
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = VelaDesign.Typography.budgetName
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        let valueText = "$\(fmt(signal.spentUSD)) of $\(fmt(signal.limitUSD ?? 0))"
        let valueW = ceil((valueText as NSString).size(withAttributes: [.font: VelaDesign.Typography.budgetValue]).width)
        nameLabel.frame = NSRect(x: inset, y: 8, width: contentWidth - valueW - 12, height: 18)
        row.addSubview(nameLabel)
        let valueLabel = NSTextField(labelWithString: valueText)
        valueLabel.font = VelaDesign.Typography.budgetValue
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: width - inset - valueW, y: 9, width: valueW, height: 16)
        row.addSubview(valueLabel)
        let fraction: CGFloat = {
            guard let limit = signal.limitUSD, limit > 0 else { return 0 }
            return CGFloat(min(signal.spentUSD / limit, 1))
        }()
        let kind: VelaDesign.Color.BudgetFillKind =
            signal.limitUSD == 0 ? .alarm
            : fraction >= 0.9 ? .alarm : fraction >= 0.75 ? .amber : fraction >= 0.5 ? .notice : .neutral
        let track = NSView(frame: NSRect(x: inset, y: 3, width: contentWidth, height: 2))
        track.wantsLayer = true
        track.layer?.backgroundColor = resolve { VelaDesign.Color.trackBackground(contrast: increaseContrast) }.cgColor
        track.layer?.cornerRadius = 1
        track.layer?.masksToBounds = true
        let fill = NSView(frame: NSRect(x: 0, y: 0, width: track.bounds.width * fraction, height: 2))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = VelaDesign.Color.trackFill(kind: kind).cgColor
        track.addSubview(fill)
        row.addSubview(track)
        // Full accessible value: untruncated route + amounts (§5.2 semantic
        // truncation with full accessible value).
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("Model budget, \(signal.model)")
        row.setAccessibilityValue("\(valueText) — \(Int(fraction * 100))% of cap used")
        return row
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = VelaDesign.Typography.sectionLabel
        label.textColor = resolve { VelaDesign.Color.sectionLabel }
        label.frame = NSRect(x: inset, y: 0, width: 220, height: 14)
        return label
    }

    private func caption(_ text: String, width: CGFloat, contrast: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = VelaDesign.Typography.secondary
        label.textColor = resolve { VelaDesign.Color.caption(contrast: contrast) }
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: inset, y: 0, width: width, height: 14)
        return label
    }

    private func hairline(_ width: CGFloat, contrast: Bool) -> NSView {
        let line = NSView(frame: NSRect(x: inset, y: 0, width: width, height: 0.5))
        line.wantsLayer = true
        line.layer?.backgroundColor = resolve { VelaDesign.Color.hairline(contrast: contrast) }.cgColor
        return line
    }

    /// MODELS label + selected-period total (right of the label, before the
    /// switcher — §5.2 puts the period total IN the models section).
    private func modelsHeader() -> NSView {
        let header = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        header.addSubview(sectionLabel("MODELS"))
        let total = NSTextField(labelWithString: String(format: "$%.2f", periodTotal()))
        total.font = VelaDesign.Typography.money
        total.textColor = .labelColor
        total.alignment = .right
        total.frame = NSRect(x: inset, y: 5, width: contentWidth - 130, height: 16)
        header.addSubview(total)
        let switcher = PeriodSwitcher(labels: ["Today", "Month"])
        switcher.frame = NSRect(x: width - inset - 118, y: 3, width: 118, height: 20)
        switcher.layoutSubtreeIfNeeded()
        switcher.setSelected(0, animated: false)
        header.addSubview(switcher)
        return header
    }

    private func periodTotal() -> Double {
        budget.globalSpentUSD
    }

    /// The five-stride models block, per ModelBreakdownState. Available:
    /// named rows (desc) with share inline; residual → pinned honest "Other".
    /// Empty/unavailable/inconsistent: the truthful total + reason, padded to
    /// the same five strides — the block never changes height across states.
    private func modelsBlock(contrast: Bool) -> NSView {
        let block = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(VelaDesign.Rows.maxModelRows) * VelaDesign.Rows.dataRowStride))
        var y: CGFloat = 0
        func note(_ text: String) {
            let label = caption(text, width: contentWidth, contrast: contrast)
            label.frame.origin.y = block.bounds.height - y - 20
            block.addSubview(label)
            y += VelaDesign.Rows.dataRowStride
        }
        switch breakdown {
        case .available(let rows, let total, _):
            let ordered = rows.sorted { $0.totalCostUSD > $1.totalCostUSD }
            for model in ordered.prefix(VelaDesign.Rows.maxModelRows) {
                let share = total > 0 ? Int((model.totalCostUSD / total * 100).rounded()) : 0
                block.addSubview(modelRow(name: model.model, cost: model.totalCostUSD,
                                          share: share, isOther: false, y: y, contrast: contrast))
                y += VelaDesign.Rows.dataRowStride
            }
            // Honest residual: when named rows don't sum to the day total,
            // the pinned "Other" row says so instead of pretending.
            let namedSum = ordered.prefix(VelaDesign.Rows.maxModelRows).reduce(0) { $0 + $1.totalCostUSD }
            if namedSum < total - 0.005, ordered.count >= VelaDesign.Rows.maxModelRows {
                block.addSubview(modelRow(name: "Other", cost: total - namedSum,
                                          share: 0, isOther: true, y: y, contrast: contrast))
            }
        case .empty:
            note("No spend yet today — totals will appear with the first observation.")
        case .unavailable(let reason):
            let totalRow = modelRow(name: "All models", cost: periodTotal(), share: 0,
                                    isOther: true, y: y, contrast: contrast)
            block.addSubview(totalRow)
            y += VelaDesign.Rows.dataRowStride
            note(reason)
        case .inconsistent(let reason):
            note("Today's per-model rows don't add up to the day total — showing the total only. (\(reason))")
        }
        return block
    }

    /// One models-table row: name+share (truncate tail, share stays attached)
    /// · cost (13pt tabular, right) · share (11pt tabular, right). Columns at
    /// fixed offsets so decimal points stack; 78pt cost column clears
    /// $9,999.99 with margin at 360pt.
    private func modelRow(name rawName: String, cost: Double, share: Int, isOther: Bool, y: CGFloat, contrast: Bool) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: blockY(y), width: width, height: VelaDesign.Rows.dataRowHeight))
        let displayName = isOther ? rawName : (rawName.split(separator: "/").last.map(String.init) ?? rawName)
        let attr = NSMutableAttributedString(string: displayName, attributes: [
            .font: VelaDesign.Typography.body,
            .foregroundColor: NSColor.labelColor,
        ])
        if !isOther {
            attr.append(NSAttributedString(string: " · \(share)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: resolve { VelaDesign.Color.caption(contrast: contrast) },
            ]))
        }
        let nameLabel = NSTextField(labelWithAttributedString: attr)
        nameLabel.lineBreakMode = .byTruncatingTail
        let costW: CGFloat = 78
        let shareW: CGFloat = 44
        nameLabel.frame = NSRect(x: inset, y: 0, width: contentWidth - costW - shareW - 12, height: 24)
        row.addSubview(nameLabel)
        let costLabel = NSTextField(labelWithString: String(format: "$%.2f", cost))
        costLabel.font = VelaDesign.Typography.money
        costLabel.alignment = .right
        costLabel.frame = NSRect(x: width - inset - costW - shareW - 8, y: 0, width: costW, height: 24)
        row.addSubview(costLabel)
        let shareLabel = NSTextField(labelWithString: isOther ? "" : "\(share)%")
        shareLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        shareLabel.textColor = resolve { VelaDesign.Color.caption(contrast: contrast) }
        shareLabel.alignment = .right
        shareLabel.frame = NSRect(x: width - inset - shareW, y: 2, width: shareW, height: 20)
        row.addSubview(shareLabel)
        // Accessibility carries the FULL route — the display name truncates,
        // the value does not (§5.2).
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(isOther ? "Other models" : rawName)
        row.setAccessibilityValue(String(format: "$%.2f, %d%% of today's spend", cost, share))
        return row
    }

    /// Block-internal stride y → view-absolute y (blocks are bottom-anchored).
    /// Stride offset from the block's TOP → bottom-anchored view y (non-flipped).
    private func blockY(_ strideY: CGFloat) -> CGFloat {
        CGFloat(VelaDesign.Rows.maxModelRows) * VelaDesign.Rows.dataRowStride
            - strideY - VelaDesign.Rows.dataRowHeight
    }

    /// M T W T F S S intensity cells. nil = observed gap → visible unfilled
    /// cell (an explained empty slot). The live strip stays DayStripView;
    /// this renders the 360pt placement for review.
    private func historyStrip() -> NSView {
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        let cellSide: CGFloat = 10
        let gap = (contentWidth - 7 * cellSide) / 6
        let levels: [Double?] = [0.2, 0.6, nil, 0.9, 0.4, 1.0, 0.1]
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        for i in 0..<7 {
            let x = inset + CGFloat(i) * (cellSide + gap)
            let cell = NSView(frame: NSRect(x: x, y: 12, width: cellSide, height: cellSide))
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 2
            if let level = levels[i] {
                cell.layer?.backgroundColor = NSColor.controlAccentColor
                    .withAlphaComponent(0.25 + 0.65 * level).cgColor
            } else {
                cell.layer?.backgroundColor = resolve { VelaDesign.Color.trackBackground(contrast: increaseContrast) }.cgColor
            }
            strip.addSubview(cell)
            let letter = NSTextField(labelWithString: letters[i])
            letter.font = NSFont.systemFont(ofSize: 9)
            letter.textColor = resolve { VelaDesign.Color.caption(contrast: increaseContrast) }
            letter.alignment = .center
            letter.frame = NSRect(x: x - 2, y: 0, width: cellSide + 4, height: 11)
            strip.addSubview(letter)
        }
        strip.setAccessibilityElement(true)
        strip.setAccessibilityLabel("This week's daily spend")
        strip.setAccessibilityValue("Monday to Sunday intensity cells; Wednesday has no recorded data")
        return strip
    }

    /// History · Start a marker · Dashboard ↗ — secondary-view entries at
    /// 24pt control height (§5.2 controls floor).
    private func secondaryNav() -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        func link(_ title: String, x: CGFloat, w: CGFloat) -> NSButton {
            let button = NSButton(title: title, target: nil, action: nil)
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = VelaDesign.Typography.secondaryInteractive
            button.contentTintColor = .secondaryLabelColor
            button.frame = NSRect(x: x, y: 2, width: w, height: VelaDesign.Rows.controlMinHeight)
            return button
        }
        row.addSubview(link("History", x: inset, w: 60))
        row.addSubview(link("Start a marker", x: inset + 76, w: 100))
        row.addSubview(link("Dashboard ↗", x: width - inset - 96, w: 96))
        return row
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")!
        return formatter
    }()
}

