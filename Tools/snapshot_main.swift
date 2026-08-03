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
        topModels: []
    )
}

@MainActor
func writeSnapshots() throws {
    let rising: [Double] = [0, 0.4, 0.9, 1.1, 1.8, 2.6, 2.9, 3.8, 4.4, 5.1, 5.4, 6.2, 6.79]
    let controller = StatusItemController()
    let outDir = URL(fileURLWithPath: "/tmp/vela-snapshots")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let fixtures: [(String, PollState, BurnBuffer)] = [
        ("fresh-13pct", .fresh(makeUsage(spent: 54.51, limit: 400)), makeBurnBuffer(rising)),
        ("fresh-50pct", .fresh(makeUsage(spent: 200, limit: 400)), makeBurnBuffer(rising)),
        ("fresh-90pct-amber", .fresh(makeUsage(spent: 360, limit: 400)), makeBurnBuffer(rising)),
        ("full-100pct-red", .fresh(makeUsage(spent: 400, limit: 400)), makeBurnBuffer(rising)),
        ("stale-45pct", .stale(makeUsage(spent: 180.40, limit: 400), consecutiveFailures: 3), makeBurnBuffer(rising)),
        ("never-fetched", .neverFetched, BurnBuffer()),
        ("no-burn-yet", .fresh(makeUsage(spent: 0, limit: 400)), BurnBuffer()),
    ]

    let appearances: [(String, NSAppearance)] = [
        ("light", NSAppearance(named: .aqua)!),
        ("dark", NSAppearance(named: .darkAqua)!),
    ]

    for (name, state, buffer) in fixtures {
        for (appearanceName, appearance) in appearances {
            let image = controller.makeImage(state: state, burnBuffer: buffer, appearance: appearance)
            guard
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write("snapshot failed for \(name)-\(appearanceName)\n".data(using: .utf8)!)
                continue
            }
            let url = outDir.appendingPathComponent("\(name)-\(appearanceName).png")
            try png.write(to: url)
            print("wrote \(url.path) (\(png.count) bytes)")
        }
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
