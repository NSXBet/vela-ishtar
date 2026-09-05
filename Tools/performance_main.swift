// Tools/performance_main.swift
// WP-00 (item 00.1): a small Foundation benchmark harness for the pure core
// paths — no AppKit, no network, no Keychain. Prints cold/warm loop timings
// for the operations later work packages are asked to keep fast, so WP-12's
// release-gate measurements have a reproducible starting point. Run with:
//
//   swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
//     Sources/VelaCore/*.swift Tools/performance_main.swift \
//     -o /tmp/vela-perf && /tmp/vela-perf
//
// The file is compiled WITH -parse-as-library disabled and carries its own
// @main entry point (same convention as Tools/snapshot_main.swift: a
// multi-file compile where main.swift is absent needs @main, not top-level
// code). Timings are wall-clock medians over repeated loops after a warmup,
// honest enough for regression spotting on one machine (the plan's §6
// targets are proposed release gates, not claims about this machine).
// RELEVANT FILES: Sources/VelaCore/HistoryStore.swift,
// Sources/VelaCore/PaceEngine.swift, Sources/VelaCore/BurnBuffer.swift,
// docs/v2/BASELINE.md

import Foundation

/// Runs `body` `iterations` times, prints the median wall-clock duration.
func measure(_ label: String, iterations: Int = 200, _ body: () -> Void) {
    guard iterations > 0 else { return }
    // Warmup: let caches/calloc settle so the printed number is steady state.
    for _ in 0..<max(1, iterations / 10) { body() }
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = DispatchTime.now()
        body()
        let end = DispatchTime.now()
        samples.append(Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
    samples.sort()
    let median = samples[samples.count / 2]
    print(String(format: "%-42s %10.4f ms/iter", (label as NSString).utf8String!, median))
}

/// Records a rising cumulative series through a real HistoryStore in a
/// temporary directory, then saves — the cold path exercises encode + write.
func seedHistory(in directory: URL, days: Int) -> HistoryStore {
    var store = HistoryStore(directory: directory)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    for dayOffset in 0..<days {
        guard let day = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
        for hour in stride(from: 0, to: 24, by: 2) {
            let at = day.addingTimeInterval(Double(hour) * 3600)
            let spent = Double(dayOffset * 10) + Double(hour) * 1.5
            store.record(spentToday: spent, limit: 400,
                         at: at,
                         spendDate: formatter.string(from: day))
        }
    }
    return store
}

// MARK: - Entry point

@main
struct PerformanceTool {
    static func main() {
        // Temp workspace the harness owns end-to-end.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-perf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        print("Vela Ishtar core performance (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        print("")

        // History save (cold: fresh store each iteration, encode + atomic write).
        measure("history.save 90 days × 12 slots (cold)") {
            let dir = scratch.appendingPathComponent("cold-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var store = seedHistory(in: dir, days: 90)
            try? store.save()
            try? FileManager.default.removeItem(at: dir)
        }

        // History load (cold: real file read + decode + clean).
        let seeded = scratch.appendingPathComponent("seeded")
        try? FileManager.default.createDirectory(at: seeded, withIntermediateDirectories: true)
        var seededStore = seedHistory(in: seeded, days: 90)
        try? seededStore.save()
        measure("history.load 90 days × 12 slots (cold)") {
            var store = HistoryStore(directory: seeded)
            try? store.load()
        }

        // History record (warm: in-memory slot write).
        var warmStore = HistoryStore(directory: seeded)
        try? warmStore.load()
        let now = Date()
        measure("history.record single observation (warm)", iterations: 2000) {
            warmStore.record(spentToday: 100, limit: 400, at: now, spendDate: "2026-09-05")
        }

        // BurnBuffer ingest (warm).
        var buffer = BurnBuffer()
        measure("burnbuffer.record 1 sample (warm)", iterations: 2000) {
            buffer.record(spentToday: Double.random(in: 0...400), at: now)
        }

        // PaceEngine verdict (warm).
        measure("paceEngine.verdict (warm)", iterations: 2000) {
            _ = PaceEngine.verdict(spent: 120, limit: 400, limitEnabled: true, now: now)
        }

        // JSON decode of the usage payload (warm: full decode).
        let fixtureData = Data("""
        {"token_id":"00000000-0000-4000-8000-000000000000","daily_budget":{"limit_usd":400,"spent_usd":54.51,"remaining_usd":345.49,"used_percent":13.6,"limit_enabled":true,"spend_date":"2026-09-01"},"current_month":{"total_cost_usd":128.4,"total_tokens":24000000,"requests":310},"top_models":[{"model":"example/alpha","total_cost_usd":80.1,"total_tokens":12000000,"requests":150}]}
        """.utf8)
        measure("usage JSON decode (warm)", iterations: 2000) {
            _ = try? JSONDecoder().decode(UsageResponse.self, from: fixtureData)
        }

        print("")
        print("done (scratch: \(scratch.path))")
    }
}
