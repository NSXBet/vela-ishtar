// Tools/snapshot_main.swift
// Dev tool: renders the menu bar pill for a set of fabricated states and
// writes the README's pill assets to docs/assets/, plus scratch popover
// renders to /tmp/vela-snapshots/ for eyeballing a layout change.
// Why: the pill is the app's signature visual — reviewers need to see it,
// not read about it. NOT compiled into the app (build.sh only takes Sources/).
//
// Two things this tool has to force, because it drives StatusItemController
// without ever installing a real NSStatusItem:
//   1. FULL pill size. `effectivePillSize` resolves `automatic` by asking
//      whether the status item's window is clipped, and a controller with no
//      window reports clipped (narrow is that property's safe failure). So an
//      un-forced snapshot silently renders the 26pt HAIRLINE — border only, no
//      sparkline and no amount — which is what shipped as the README's pill
//      assets until v1.0.0's doc pass caught it. Forcing `full` (calm level 1)
//      goes through UserDefaults' REGISTRATION domain, which is volatile: it
//      is never written to disk, so running this tool cannot change the pill
//      size of the installed app.
//   2. A 3x raster and a menu-bar-like backdrop. The pill's border is 1.5pt,
//      which is ~2 device pixels at 1x — GitHub renders that as a smudge, and
//      the notice band's yellow arc disappeared entirely. Rendering at 3x
//      keeps the border crisp, and compositing on an opaque dark panel makes
//      the asset read the same in GitHub's light AND dark themes (the pill's
//      own ink is near-white, so a transparent render vanishes on light).
//
// Build & run (the file list is build.sh's globs minus main.swift — the app's
// entry point, whose top-level code would collide with @main below):
//   swiftc -O -target arm64-apple-macos14.0 \
//     Sources/VelaCore/*.swift \
//     $(ls Sources/App/*.swift | grep -v '/main.swift$') \
//     Tools/snapshot_main.swift \
//     -o /tmp/vela-snapshot \
//     -framework Cocoa -framework ServiceManagement -framework Security -framework QuartzCore \
//   && /tmp/vela-snapshot
//
// RELEVANT FILES: Sources/App/StatusItemController.swift, Sources/VelaCore/BorderDash.swift, Sources/App/PopoverView.swift, build.sh

import Cocoa

// BurnBuffer.slots is `public private(set)`, so fixtures are built by
// recording an increasing cumulative series — each record appends the delta.
func makeBurnBuffer(_ cumulative: [Double]) -> BurnBuffer {
    var buffer = BurnBuffer()
    for (i, value) in cumulative.enumerated() {
        buffer.record(spentToday: value, at: Date().addingTimeInterval(Double(i) * 60))
    }
    return buffer
}

func makeUsage(spent: Double, limit: Double) -> UsageResponse {
    UsageResponse(
        tokenId: "snapshot",
        dailyBudget: DailyBudget(
            limitUSD: limit,
            spentUSD: spent,
            remainingUSD: max(limit - spent, 0),
            usedPercent: limit > 0 ? spent / limit * 100 : 0,
            limitEnabled: true,
            spendDate: "2026-08-04T00:00:00Z"
        ),
        currentMonth: MonthStats(totalCostUSD: spent, totalTokens: 8_560_000, requests: 73),
        topModels: [
            ModelUsage(model: "moonshotai/kimi-k3", totalCostUSD: 52.30, totalTokens: 68_013_553, requests: 426),
            ModelUsage(model: "anthropic/claude-haiku-4.5", totalCostUSD: 2.21, totalTokens: 4_959_265, requests: 99),
        ]
    )
}

@MainActor
func writeSnapshots() throws {
    // Pill assets are COMMITTED (the README embeds them); popover renders are
    // scratch, for eyeballing a layout change.
    let repoRoot = URL(fileURLWithPath: #filePath)          // Tools/snapshot_main.swift
        .deletingLastPathComponent()                        // Tools/
        .deletingLastPathComponent()                        // repo root
    let assetsDir = repoRoot.appendingPathComponent("docs/assets")
    let scratchDir = URL(fileURLWithPath: "/tmp/vela-snapshots")
    try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

    // Force the FULL pill (calm level 1). See the header note: an uninstalled
    // controller reads as notch-clipped and would render the hairline. The
    // registration domain is volatile — nothing is written to disk, so the
    // installed app's own pill size is untouched by running this tool.
    UserDefaults.standard.register(defaults: ["vela.calmLevel": 1])

    var machine = PollStateMachine()
    // Build an hour-by-hour history for today by ingesting rising spend.
    let now = Date()
    var utcCal = Calendar(identifier: .gregorian)
    utcCal.timeZone = TimeZone(identifier: "UTC")!
    let midnight = utcCal.startOfDay(for: now)
    let currentHour = utcCal.component(.hour, from: now)
    for hour in 0...currentHour {
        let spent = 2.0 + Double(hour) * Double(hour) * 0.35   // accelerating burn
        let usage = makeUsage(spent: spent, limit: 400)
        _ = machine.ingest(.success(usage), at: midnight.addingTimeInterval(Double(hour) * 3600 + 1800))
    }
    // Final state at "now" with the fixture totals.
    _ = machine.ingest(.success(makeUsage(spent: 54.51, limit: 400)), at: now)

    // Pill states first (the menu bar item itself).
    let rising: [Double] = [0, 0.4, 0.9, 1.1, 1.8, 2.6, 2.9, 3.8, 4.4, 5.1, 5.4, 6.2, 6.79]
    let controller = StatusItemController()
    let pillFixtures: [(String, PollState, BurnBuffer)] = [
        // v1.0.0 ramp: ink < 50%, yellow >= 50%, amber >= 75%, red loop >= 90%.
        // One fixture per band so the README shows the whole escalation. The
        // percentages are picked to sit clearly INSIDE each band, not on a
        // threshold, so a reader can't mistake a boundary case for the rule.
        ("pill-dark", .fresh(makeUsage(spent: 140, limit: 400)), makeBurnBuffer(rising)),           // 35% - ink
        ("pill-notice-dark", .fresh(makeUsage(spent: 240, limit: 400)), makeBurnBuffer(rising)),    // 60% - yellow
        ("pill-amber-dark", .fresh(makeUsage(spent: 330, limit: 400)), makeBurnBuffer(rising)),     // 82.5% - amber
        ("pill-exhausted-dark", .fresh(makeUsage(spent: 380, limit: 400)), makeBurnBuffer(rising)), // 95% - red loop
        ("pill-stale-dark", .stale(makeUsage(spent: 180.40, limit: 400), consecutiveFailures: 3), makeBurnBuffer(rising)),
    ]
    for (name, state, buffer) in pillFixtures {
        let pill = controller.makeImage(state: state, burnBuffer: buffer, appearance: NSAppearance(named: .darkAqua)!)
        guard pill.size.width > 30 else {
            // The hairline slipped through — the calm-level force above failed,
            // and shipping a border-only thumbnail as "sparkline + amount +
            // border" is exactly the bug this guard exists to catch. Fail loud
            // rather than overwrite a good asset with a wrong one.
            throw SnapshotError.hairlineRendered(name: name, width: pill.size.width)
        }
        let png = try renderPillAsset(pill)
        let url = assetsDir.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("wrote \(url.path) (\(png.count) bytes, \(Int(pill.size.width))×\(Int(pill.size.height))pt @\(Int(assetScale))x)")
    }

    let view = PopoverView()
    view.update(state: machine.state, history: machine.history,
                exhaustedAt: machine.exhaustedAt, lastSuccessAt: machine.lastSuccessAt, now: now)
    view.frame = NSRect(x: 0, y: 0, width: 320, height: view.fittingSize.height > 0 ? view.fittingSize.height : 480)

    let appearances: [(String, NSAppearance)] = [
        ("light", NSAppearance(named: .aqua)!),
        ("dark", NSAppearance(named: .darkAqua)!),
    ]
    for (name, appearance) in appearances {
        appearance.performAsCurrentDrawingAppearance {
            view.display()
        }
        guard
            let tiff = view.bitmapImageRepForCachingDisplay(in: view.bounds).map({ rep -> Data? in
                view.cacheDisplay(in: view.bounds, to: rep)
                return rep.representation(using: .png, properties: [:])
            }) ?? nil
        else {
            FileHandle.standardError.write("popover snapshot failed for \(name)\n".data(using: .utf8)!)
            continue
        }
        let url = scratchDir.appendingPathComponent("popover-\(name).png")
        try tiff.write(to: url)
        print("wrote \(url.path) (\(tiff.count) bytes)")
    }
}

enum SnapshotError: Error, CustomStringConvertible {
    case hairlineRendered(name: String, width: CGFloat)
    case rasterFailed(String)

    var description: String {
        switch self {
        case .hairlineRendered(let name, let width):
            return "\(name): rendered \(Int(width))pt wide — that's the hairline pill (border only). "
                 + "The calm-level force in writeSnapshots() is not taking effect; refusing to overwrite the asset."
        case .rasterFailed(let detail):
            return "raster failed: \(detail)"
        }
    }
}

/// Points-to-pixels multiplier for the committed pill assets. The border is
/// 1.5pt, so at 1x it lands on ~2 device pixels and GitHub's downscale turns it
/// into a smudge — the yellow notice arc vanished outright at 26×22. 3x keeps
/// every band's colour and the pill's corner radius unambiguous while the files
/// stay a few KB.
let assetScale: CGFloat = 3

/// GitHub's dark canvas (#0d1117), used as an OPAQUE backdrop plus a little
/// breathing room around the pill.
///
/// Why opaque rather than a transparent PNG: the pill draws in `labelColor`
/// under darkAqua, which is near-white, so a transparent asset is invisible
/// against GitHub's LIGHT theme — and the interior ink is what makes the shape
/// read at all. Baking the dark panel in means one asset that reads identically
/// in both themes, and it's still an honest screenshot: these are the real
/// pixels StatusItemController draws, on the background a dark menu bar gives
/// them.
let assetBackdrop = NSColor(srgbRed: 0x0d / 255.0, green: 0x11 / 255.0, blue: 0x17 / 255.0, alpha: 1)
let assetPadding: CGFloat = 6

/// Composites a rendered pill onto the dark backdrop at `assetScale` and
/// returns PNG bytes.
///
/// The bitmap is allocated in PIXELS and given a POINT-sized frame, which is
/// what makes `NSGraphicsContext` scale every drawing operation up — the pill is
/// re-rasterized at 3x rather than upscaled, so its border stays a clean edge
/// instead of a blurred one.
@MainActor
func renderPillAsset(_ pill: NSImage) throws -> Data {
    let pointSize = NSSize(width: pill.size.width + 2 * assetPadding,
                           height: pill.size.height + 2 * assetPadding)
    let pixelWidth = Int((pointSize.width * assetScale).rounded())
    let pixelHeight = Int((pointSize.height * assetScale).rounded())

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw SnapshotError.rasterFailed("could not allocate a \(pixelWidth)×\(pixelHeight) bitmap")
    }
    // Declaring the point size is the scale hop: 3 device pixels per point.
    bitmap.size = pointSize

    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw SnapshotError.rasterFailed("could not bind a graphics context to the bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    // Draw under darkAqua so the pill's semantic colours resolve to the same
    // values the backdrop was chosen for.
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        assetBackdrop.setFill()
        NSRect(origin: .zero, size: pointSize).fill()
        pill.draw(in: NSRect(x: assetPadding, y: assetPadding,
                             width: pill.size.width, height: pill.size.height))
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw SnapshotError.rasterFailed("could not encode PNG")
    }
    return png
}

// The file is compiled with -parse-as-library, so top-level statements are
// not allowed; this @main struct is the entry point instead.
@main
struct SnapshotTool {
    static func main() async {
        // StatusItemController is @MainActor; `await` hops us there.
        do {
            try await writeSnapshots()
        } catch {
            FileHandle.standardError.write("snapshot error: \(error)\n".data(using: .utf8)!)
        }
    }
}
