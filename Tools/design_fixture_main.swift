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
// Build & run (single-module compile; the fixture views live in
// Tools/FixtureViews/ and compile alongside):
//   swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
//     Sources/VelaCore/*.swift \
//     $(ls Sources/App/*.swift | grep -v '/main.swift$') \
//     Tools/FixtureViews/*.swift \
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
func fmt(_ amount: Double) -> String {
    amount.rounded() == amount
        ? String(format: "%.0f", amount)
        : String(format: "%.2f", amount)
}

// MARK: - Synthetic data (no network, no credentials, deterministic)

/// Deterministic reference instant — fixtures must not depend on when the
/// tool runs, or two renders of "the same" state never diff cleanly.
func fixtureNow() -> Date {
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
func fixtureHourly() -> [Double?] {
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
func resolveBuild(_ appearance: NSAppearance, _ build: () -> NSColor) -> NSColor {
    var resolved = NSColor.clear
    appearance.performAsCurrentDrawingAppearance {
        // Build the color INSIDE the scope: a dynamic NSColor caches its
        // cgColor on first resolution, so an instance resolved under one
        // appearance returns that variant forever after (probe-verified).
        resolved = build().usingColorSpace(.sRGB) ?? NSColor.clear
    }
    return resolved
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
