// Tools/snapshot_main.swift
// Dev tool: renders the menu bar pill for a set of fabricated states and
// writes PNGs to /tmp/vela-snapshots/ so the design can be reviewed
// visually without running the whole app.
// Why: the pill is the app's signature visual — reviewers need to see it,
// not read about it. NOT compiled into the app (build.sh only takes Sources/).
//
// Build & run:
//   swiftc -O -target arm64-apple-macos14.0 \
//     Sources/VelaCore/*.swift Sources/App/KeychainStore.swift \
//     Sources/App/AIHubClient.swift Sources/App/UsagePoller.swift \
//     Sources/App/StatusItemController.swift Tools/snapshot_main.swift \
//     -o /tmp/vela-snapshot -framework Cocoa -framework Security -framework QuartzCore \
//   && /tmp/vela-snapshot
//
// RELEVANT FILES: Sources/App/StatusItemController.swift, Sources/VelaCore/PollStateMachine.swift, Sources/VelaCore/BurnBuffer.swift

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
    // Render the POPOVER (not the pill): fabricate a fresh usage state,
    // feed it through PollStateMachine so history is real, then snapshot
    // PopoverView in both appearances.
    let outDir = URL(fileURLWithPath: "/tmp/vela-snapshots")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

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
        // One fixture per band so the README shows the whole escalation.
        ("pill-dark", .fresh(makeUsage(spent: 140, limit: 400)), makeBurnBuffer(rising)),           // 35% - ink
        ("pill-notice-dark", .fresh(makeUsage(spent: 240, limit: 400)), makeBurnBuffer(rising)),    // 60% - yellow
        ("pill-amber-dark", .fresh(makeUsage(spent: 330, limit: 400)), makeBurnBuffer(rising)),     // 82.5% - amber
        ("pill-exhausted-dark", .fresh(makeUsage(spent: 380, limit: 400)), makeBurnBuffer(rising)), // 95% - red loop
        ("pill-stale-dark", .stale(makeUsage(spent: 180.40, limit: 400), consecutiveFailures: 3), makeBurnBuffer(rising)),
    ]
    for (name, state, buffer) in pillFixtures {
        let image = controller.makeImage(state: state, burnBuffer: buffer, appearance: NSAppearance(named: .darkAqua)!)
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let url = outDir.appendingPathComponent("\(name).png")
            try png.write(to: url)
            print("wrote \(url.path)")
        }
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
        let url = outDir.appendingPathComponent("popover-\(name).png")
        try tiff.write(to: url)
        print("wrote \(url.path) (\(tiff.count) bytes)")
    }
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
