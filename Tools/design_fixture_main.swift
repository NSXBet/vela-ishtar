// Tools/design_fixture_main.swift
// WP-05: standalone AppKit design-fixture harness. Renders the proposed 360pt
// v2 summary (§5.2 hierarchy) plus every §5.3/§5.4 state, in light AND dark,
// as PNGs under build/v2-design/. For the 05.1 legibility comparison the
// CURRENT 320pt card is rendered by the real PopoverView with the same
// fixture data — the comparison is shipped pixels vs proposed pixels.
// Why: WP-06/07/08 convert the live UI to these designs; reviewers need the
// pixels, not prose. Like Tools/snapshot_main.swift this drives real view
// classes off synthetic state — NO live session, NO credentials, NO network,
// NO Keychain. State fixtures speak the §7.2 contract vocabulary
// (BudgetOverview, ModelBreakdownState, Freshness) so the designs are
// reviewable against the frozen contracts before any presenter exists.
//
// Build & run (same single-module compile as snapshot_main, minus main.swift):
//   swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
//     Sources/VelaCore/*.swift \
//     $(ls Sources/App/*.swift | grep -v '/main.swift$') \
//     Tools/design_fixture_main.swift \
//     -o /tmp/vela-design-fixture \
//     -framework Cocoa -framework ServiceManagement -framework Security -framework QuartzCore \
//   && VELA_DESIGN_DIR=build/v2-design /tmp/vela-design-fixture
//
// Output root: VELA_DESIGN_DIR (absolute or ~-relative), default
// build/v2-design under the repo root. Never docs/assets.
// RELEVANT FILES: Sources/App/DesignTokens.swift, Tools/snapshot_main.swift,
// Sources/App/PopoverView.swift, docs/v2/DESIGN.md

import Cocoa

// MARK: - Output plumbing

/// Resolves the fixture output root. Only env override; default build/v2-design.
private func designDir() -> URL {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tools/
        .deletingLastPathComponent()   // repo root
    let raw = (ProcessInfo.processInfo.environment["VELA_DESIGN_DIR"] ?? "")
        .trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return repoRoot.appendingPathComponent("build/v2-design") }
    let expanded = (raw as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded)
}

/// Rasterizes a fully-laid-out view onto an OPAQUE canvas at 2x. `busy`
/// paints a striped desktop-like backdrop first — the honest test for
/// "does the ink survive without the material" (the Reduce Transparency
/// question, §5.1/§5.4).
@MainActor
private func renderPNG(_ view: NSView, appearance: NSAppearance, busy: Bool = false) throws -> Data {
    // Dynamic NSColors (labelColor et al.) resolve against the VIEW's
    // effectiveAppearance — not the drawing handler — because cacheDisplay
    // re-enters per-subview. Setting it on the root propagates to every child.
    view.appearance = appearance
    // SummaryFixtureView/BudgetDetailFixtureView resolve wrapped inks through
    // this stored appearance (see their `resolve` helper).
    if let fixture = view as? SummaryFixtureView { fixture.fixtureAppearance = appearance }
    if let fixture = view as? BudgetDetailFixtureView { fixture.fixtureAppearance = appearance }
    let pointSize = view.bounds.size
    let scale: CGFloat = 2
    let pixelWidth = Int((pointSize.width * scale).rounded())
    let pixelHeight = Int((pointSize.height * scale).rounded())
    guard pixelWidth > 0, pixelHeight > 0 else {
        throw DesignError.raster("empty \(Int(pointSize.width))×\(Int(pointSize.height))pt frame")
    }
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else {
        throw DesignError.raster("bitmap alloc failed for \(pixelWidth)×\(pixelHeight)")
    }
    bitmap.size = pointSize
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw DesignError.raster("graphics context bind failed")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    appearance.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: pointSize).fill()
        if busy {
            // Diagonal stripes: a stand-in for arbitrary desktop content
            // behind a translucent panel.
            NSColor.underPageBackgroundColor.setFill()
            NSRect(origin: .zero, size: pointSize).fill()
            NSColor.windowBackgroundColor.withAlphaComponent(0.5).setFill()
            var x: CGFloat = 0
            while x < pointSize.width {
                NSRect(x: x, y: 0, width: 7, height: pointSize.height).fill(using: .sourceOver)
                x += 14
            }
        }
        view.cacheDisplay(in: NSRect(origin: .zero, size: pointSize), to: bitmap)
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw DesignError.raster("PNG encode failed")
    }
    return png
}

private enum DesignError: Error, CustomStringConvertible {
    case raster(String)
    var description: String {
        switch self { case .raster(let d): return "raster failed: \(d)" }
    }
}

/// Compact money formatter for fixture copy ("$9,999.99").
private func fmt(_ amount: Double) -> String {
    amount.rounded() == amount
        ? String(format: "%.0f", amount)
        : String(format: "%.2f", amount)
}

// MARK: - Synthetic data (no network, no credentials, deterministic)

/// Deterministic reference instant — fixtures must not depend on when the
/// tool runs, or two renders of "the same" state never diff cleanly.
private func fixtureNow() -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    // 2026-09-04 12:31:00 UTC — matches the §5.2 sketch's "12:31".
    return cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12, minute: 31))!
}

private func dayKey(_ date: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let comps = cal.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
}

/// Deterministic, non-secret fixture scope (§7.2 UsageScope). A literal
/// fixture UUID — never a token, never a real account id.
private func fixtureScope() -> UsageScope {
    UsageScope(kind: .credential,
               opaqueID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!,
               gatewayOrigin: "https://fixture.invalid")
}

private func overview(spent: Double, limit: Double, freshness: Freshness,
                      signals: [BudgetOverview.ModelSignal], reset: String) -> BudgetOverview {
    BudgetOverview(globalLimitEnabled: limit > 0, globalLimitUSD: limit, globalSpentUSD: spent,
                   modelSignals: signals, resetDescription: reset, freshness: freshness)
}

/// The worst-case cap set: very long route near its cap, a relaxed cooldown,
/// and a $0 BLOCKED cap — all in one detail render (plan §5.4).
private func capSignals() -> [BudgetOverview.ModelSignal] {
    [
        BudgetOverview.ModelSignal(
            model: "anthropic/claude-opus-5-thinking-extended-route",
            spentUSD: 19.20, limitUSD: 20, headroomUSD: 0.80, relaxedUntil: nil),
        BudgetOverview.ModelSignal(
            model: "moonshotai/kimi-k3",
            spentUSD: 6.10, limitUSD: 50, headroomUSD: 43.90,
            relaxedUntil: fixtureNow().addingTimeInterval(3600)),
        BudgetOverview.ModelSignal(
            model: "google/gemini-3.5-pro-preview-internal",
            spentUSD: 0, limitUSD: 0, headroomUSD: 0, relaxedUntil: nil),
    ]
}

private func oneSignal() -> [BudgetOverview.ModelSignal] {
    [capSignals()[0]]
}

/// The canonical live fixture: $9,999.99-scale amounts on one row, a very
/// long route on another, five rows total (§5.4 worst cases together).
private func worstCaseMonthModels() -> [ModelUsage] {
    [
        ModelUsage(model: "moonshotai/kimi-k3", totalCostUSD: 9_999.99, totalTokens: 681_013_553, requests: 8_204),
        ModelUsage(model: "anthropic/claude-opus-5-thinking-extended", totalCostUSD: 318.42, totalTokens: 41_959_265, requests: 2_481),
        ModelUsage(model: "google/gemini-3.5-pro-preview-internal", totalCostUSD: 62.17, totalTokens: 12_902_000, requests: 1_102),
        ModelUsage(model: "deepseek/deepseek-v4-chat", totalCostUSD: 18.75, totalTokens: 9_004_120, requests: 512),
        ModelUsage(model: "amazon/nova-micro", totalCostUSD: 12.59, totalTokens: 1_504_000, requests: 104),
    ]
}

private func worstCaseTodayModels(dayTotal: Double) -> [ModelUsage] {
    let kimi = dayTotal * 0.82
    return [
        ModelUsage(model: "moonshotai/kimi-k3", totalCostUSD: kimi, totalTokens: 3_902_000, requests: 24),
        ModelUsage(model: "anthropic/claude-opus-5-thinking-extended", totalCostUSD: dayTotal - kimi, totalTokens: 218_000, requests: 7),
    ]
}

/// The live-comparison fixture response. The 320pt side renders through the
/// REAL PopoverView, so this UsageResponse feeds both sides of 05.1.
private func comparisonResponse(now: Date) -> UsageResponse {
    UsageResponse(
        tokenId: "fixture",
        dailyBudget: DailyBudget(
            limitUSD: 400, spentUSD: 54.51, remainingUSD: 345.49, usedPercent: 13.6,
            limitEnabled: true, spendDate: dayKey(now),
            modelBudgets: [
                ModelBudget(model: "anthropic/claude-opus-5-thinking-extended-route",
                            spentUSD: 19.20, limitUSD: 20, remainingUSD: 0.80, percentUsed: 96,
                            cooldownEligible: false, cooldown: nil),
            ]
        ),
        currentMonth: MonthStats(totalCostUSD: 10_411.17, totalTokens: 896_400_000, requests: 12_403),
        topModels: worstCaseMonthModels(),
        today: MonthStats(totalCostUSD: 54.51, totalTokens: 4_120_000, requests: 31),
        todayModels: worstCaseTodayModels(dayTotal: 54.51)
    )
}

/// Rising hourly cumulative for the observations lane.
private func fixtureHourly() -> [Double?] {
    var hourly: [Double?] = Array(repeating: nil, count: 24)
    var cumulative: Double = 0
    for hour in 0...12 {
        cumulative += 1.2 + Double(hour) * 0.55
        hourly[hour] = cumulative
    }
    return hourly
}


/// Resolves a dynamic color under an explicit appearance. A windowless view
/// resolves dynamic colors at draw time against the app's CURRENT appearance —
/// wrong for one of the two appearance passes in the fixture harness.
@MainActor
private func resolveBuild(_ appearance: NSAppearance, _ build: () -> NSColor) -> NSColor {
    var resolved = NSColor.clear
    appearance.performAsCurrentDrawingAppearance {
        // Build the color INSIDE the scope: a dynamic NSColor caches its
        // cgColor on first resolution, so an instance resolved under one
        // appearance returns that variant forever after (probe-verified).
        resolved = build().usingColorSpace(.sRGB) ?? NSColor.clear
    }
    return resolved
}

// MARK: - The v2 summary fixture view (renders FROM the frozen contracts)

/// Renders the §5.2 hierarchy at 360pt from contract values. Deliberately a
/// fixture-only renderer (not app code): it exists so reviewers can approve
/// the 360pt design before WP-06 builds the live presenter from the same
/// SummaryDisplayState. No I/O, no timers, no animation — a still frame.
@MainActor
private final class SummaryFixtureView: NSView {
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

// MARK: - Budget detail fixture (§5.1 secondary-panel treatment)

/// The secondary "budget detail" surface: every cap as its own row (headroom,
/// cooldown, blocked), plus one marker receipt block showing a measured delta
/// and an explicitly-unavailable one — MarkerReceipt (§7.2) rendered.
@MainActor
private final class BudgetDetailFixtureView: NSView {
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

// MARK: - State fixtures (§5.3) and rendering

/// Builds (budget, breakdown) for a named §5.3 state. The last good snapshot
/// is retained SEPARATELY from the connection state (§7.2 ConnectionState):
/// stale/auth/error keep rendering their figures — dimmed, honestly labeled —
/// while the status band says what happened.
@MainActor
private func stateFixture(_ name: String) -> (budget: BudgetOverview, breakdown: ModelBreakdownState) {
    let now = fixtureNow()
    let fresh = Freshness.fresh(receivedAt: now, maxAgeSeconds: 90)
    switch name {
    case "loading":
        // Connecting: a NEUTRAL status line (spinner in the live app), never
        // a stale band — nothing has failed yet (§5.3).
        return (
            overview(spent: 0, limit: 0,
                     freshness: .fresh(receivedAt: now, maxAgeSeconds: 90),
                     signals: [], reset: "waiting for the first reading"),
            .unavailable(reason: "Connecting to AI Hub — first observation will appear here.")
        )
    case "cache":
        // First cached paint: yesterday's shape of numbers, explicitly not live.
        return (
            overview(spent: 41.02, limit: 400,
                     freshness: .stale(lastReceivedAt: now.addingTimeInterval(-3_400)),
                     signals: oneSignal(), reset: "resets at UTC midnight"),
            .unavailable(reason: "Per-model breakdown is monthly only")
        )
    case "stale":
        return (
            overview(spent: 54.51, limit: 400,
                     freshness: .stale(lastReceivedAt: now.addingTimeInterval(-1_920)),
                     signals: capSignals(), reset: "resets at UTC midnight"),
            .unavailable(reason: "Per-model breakdown needs a fresh reading")
        )
    case "auth":
        return (
            overview(spent: 54.51, limit: 400,
                     freshness: .invalidated(reason: "AI Hub rejected this API key — open API key to paste a new one"),
                     signals: [], reset: "resets at UTC midnight"),
            .unavailable(reason: "Authentication required")
        )
    case "error":
        return (
            overview(spent: 54.51, limit: 400,
                     freshness: .invalidated(reason: "AI Hub unreachable — retrying. Data last received 09:02."),
                     signals: [], reset: "resets at UTC midnight"),
            .unavailable(reason: "Network error")
        )
    case "unlimited":
        return (
            overview(spent: 12.88, limit: 0,
                     freshness: fresh, signals: [], reset: "no daily limit"),
            .available(rows: [ModelUsage(model: "moonshotai/kimi-k3", totalCostUSD: 12.88, totalTokens: 902_000, requests: 9)],
                       total: 12.88, scope: fixtureScope())
        )
    case "missing-data":
        return (
            overview(spent: 54.51, limit: 400,
                     freshness: fresh, signals: capSignals(), reset: "resets at UTC midnight"),
            .unavailable(reason: "This gateway build has no per-model data for today")
        )
    case "no-spend":
        return (
            overview(spent: 0, limit: 400,
                     freshness: fresh, signals: [], reset: "resets at UTC midnight"),
            .empty
        )
    case "invalid-response":
        return (
            overview(spent: 54.51, limit: 400,
                     freshness: .invalidated(reason: "AI Hub sent a response that could not be validated — retrying"),
                     signals: [], reset: "resets at UTC midnight"),
            .inconsistent(reason: "named rows exceed the day total")
        )
    default:
        return (
            overview(spent: 54.51, limit: 400, freshness: fresh,
                     signals: capSignals(), reset: "resets at UTC midnight"),
            .available(rows: worstCaseTodayModels(dayTotal: 54.51), total: 54.51, scope: fixtureScope())
        )
    }
}

@MainActor
private func renderAll(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = fixtureNow()
    let appearances: [(String, NSAppearance)] = [
        ("light", NSAppearance(named: .aqua)!),
        ("dark", NSAppearance(named: .darkAqua)!),
    ]

    // -- 05.1 comparison: the CURRENT 320pt card renders through the REAL
    //    PopoverView with the same fixture data; the proposed 360pt side
    //    renders through SummaryFixtureView. Same data, both appearances. ---
    let response = comparisonResponse(now: now)
    // Seed history for the curve + day strip via a throwaway temp store.
    let historyDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vela-design-fixtures-\(UUID().uuidString)")
    var history = HistoryStore(directory: historyDir)
    for offset in 1...6 {
        let day = now.addingTimeInterval(Double(-offset) * 86_400)
        history.record(spentToday: 18.0 + Double((offset * 7) % 29), limit: 400, at: day, spendDate: dayKey(day))
    }
    var cumulative: Double = 0
    for hour in 0...12 {
        cumulative += 1.5 + Double(hour) * 0.42
        history.record(spentToday: cumulative, limit: 400,
                       at: now.addingTimeInterval(Double(hour - 12) * 3600),
                       spendDate: dayKey(now))
    }

    // The real 320pt card needs a PollState; fresh is the honest live state.
    let v1View = PopoverView()
    v1View.update(state: .fresh(response), history: history,
                  exhaustedAt: nil, lastSuccessAt: now, now: now)

    // The proposed 360pt side, from contract values.
    let liveBudget = overview(spent: 54.51, limit: 400,
                              freshness: .fresh(receivedAt: now, maxAgeSeconds: 90),
                              signals: capSignals(), reset: "resets at UTC midnight")
    let liveBreakdown = ModelBreakdownState.available(rows: worstCaseTodayModels(dayTotal: 54.51),
                                                      total: 54.51, scope: fixtureScope())
    for (appearanceName, appearance) in appearances {
        let pngV1 = try renderPNG(v1View, appearance: appearance)
        let v1URL = directory.appendingPathComponent("compare-v1-320-\(appearanceName).png")
        try pngV1.write(to: v1URL)
        print("wrote \(v1URL.path) (\(pngV1.count) bytes, \(Int(v1View.bounds.width))×\(Int(v1View.bounds.height))pt)")

        let v2View = SummaryFixtureView(width: VelaDesign.Layout.summaryWidth,
                                        budget: liveBudget, breakdown: liveBreakdown,
                                        monthTop: worstCaseMonthModels())
        v2View.fixtureAppearance = appearance
        v2View.layoutContent()
        let pngV2 = try renderPNG(v2View, appearance: appearance)
        let v2URL = directory.appendingPathComponent("compare-v2-360-\(appearanceName).png")
        try pngV2.write(to: v2URL)
        print("wrote \(v2URL.path) (\(pngV2.count) bytes, \(Int(v2View.bounds.width))×\(Int(v2View.bounds.height))pt)")

        // Budget detail (caps + markers), light and dark.
        let detailBudget = overview(spent: 54.51, limit: 400,
                                    freshness: .fresh(receivedAt: now, maxAgeSeconds: 90),
                                    signals: capSignals(), reset: "resets at UTC midnight")
        let detail = BudgetDetailFixtureView(budget: detailBudget)
        detail.fixtureAppearance = appearance
        detail.layoutContent()
        let detailURL = directory.appendingPathComponent("budget-detail-\(appearanceName).png")
        try renderPNG(detail, appearance: appearance).write(to: detailURL)
        print("wrote \(detailURL.path) (\(Int(detail.bounds.width))×\(Int(detail.bounds.height))pt)")
    }

    // -- 05.3 state fixtures: every §5.3 state, light + dark. ---------------
    let states = ["loading", "cache", "stale", "auth", "error",
                  "unlimited", "missing-data", "no-spend", "invalid-response"]
    for (appearanceName, appearance) in appearances {
        for state in states {
            let (budget, breakdown) = stateFixture(state)
            let view = SummaryFixtureView(width: VelaDesign.Layout.summaryWidth,
                                          budget: budget, breakdown: breakdown,
                                          monthTop: [])
            view.fixtureAppearance = appearance
            view.layoutContent()
            let url = directory.appendingPathComponent("state-\(state)-\(appearanceName).png")
            try renderPNG(view, appearance: appearance).write(to: url)
            print("wrote \(url.path) (\(Int(view.bounds.width))×\(Int(view.bounds.height))pt)")
        }

        // -- §5.4 accessibility variants on the live fixture. ---------------
        // Increase Contrast: separators/captions lift (tokens' contrast flag).
        let contrastView = SummaryFixtureView(width: VelaDesign.Layout.summaryWidth,
                                              budget: liveBudget, breakdown: liveBreakdown,
                                              monthTop: worstCaseMonthModels())
        contrastView.increaseContrast = true
        contrastView.fixtureAppearance = appearance
        contrastView.layoutContent()
        let contrastURL = directory.appendingPathComponent("state-increase-contrast-\(appearanceName).png")
        try renderPNG(contrastView, appearance: appearance).write(to: contrastURL)
        print("wrote \(contrastURL.path)")

        // Reduce Transparency: the summary over a BUSY backdrop — the opaque
        // fallback must keep every element legible without the material.
        let opaqueView = SummaryFixtureView(width: VelaDesign.Layout.summaryWidth,
                                            budget: liveBudget, breakdown: liveBreakdown,
                                            monthTop: worstCaseMonthModels())
        opaqueView.reduceTransparency = true
        opaqueView.fixtureAppearance = appearance
        opaqueView.layoutContent()
        let opaqueURL = directory.appendingPathComponent("state-reduce-transparency-\(appearanceName).png")
        try renderPNG(opaqueView, appearance: appearance, busy: true).write(to: opaqueURL)
        print("wrote \(opaqueURL.path)")
    }

    // -- 05.2 measurement pass: print frozen-token measurements. -----------
    print("\n-- token measurements (fixtureNow font metrics) --")
    let samples: [(String, String, NSFont)] = [
        ("hero typical", "$54.51", VelaDesign.Typography.hero),
        ("hero worst", "$9,999.99", VelaDesign.Typography.hero),
        ("money worst", "$9,999.99", VelaDesign.Typography.money),
        ("body longest", "claude-opus-5-thinking-extended", VelaDesign.Typography.body),
    ]
    for (label, text, font) in samples {
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        print("\(label): \"\(text)\" = \(Int(width))pt @\(font.pointSize)pt")
    }
    print("summary width \(Int(VelaDesign.Layout.summaryWidth))pt · inset \(Int(VelaDesign.Layout.contentInset))pt · content \(Int(VelaDesign.Layout.contentWidth))pt")
    print("row stride \(Int(VelaDesign.Rows.dataRowStride))pt · control min \(Int(VelaDesign.Rows.controlMinHeight))pt · status slot \(Int(VelaDesign.Rows.statusSlotHeight))pt")
}

// The file compiles -parse-as-library (matching the other Tools/ targets), so
// the entry point is @main, not top-level code.
@main
struct DesignFixtureTool {
    static func main() async {
        do {
            try await renderAll(to: designDir())
        } catch {
            FileHandle.standardError.write("design fixture error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
