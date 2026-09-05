// Sources/App/PerformanceSignposts.swift
// WP-06 06.5: os_signpost instrumentation for the pipeline's hot intervals
// — fetch, decode, persist, presenter, render, and popover open — plus
// debug-build counters for redraws, windows, timers, and monitors.
// Why: §9 06.5 requires baseline-versus-new measurements; WP-12's release
// gate reads these intervals from Instruments or a log stream. All names
// are static strings: no token, no payload, no personal data ever reaches
// a signpost (§7.2 hygiene).
// RELEVANT FILES: Sources/App/AppCoordinator.swift, Sources/App/PopoverPanel.swift,
// Sources/App/StatusItemController.swift, docs/v2/BASELINE.md

import Foundation
import os

/// One signpost subsystem, six intervals, four debug counters.
/// Every call is a no-op-safe static: callers never guard on availability.
public enum Perf {

    static let signposter = OSSignposter(subsystem: "com.nsxbet.velaishtar", category: "perf")

    // MARK: - Intervals

    /// Wrap a synchronous interval (fetch/decode/persist/presenter/render).
    @discardableResult
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// Wrap an async interval (fetch, persist writes).
    @discardableResult
    public static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return try await body()
    }

    /// Interval names (static strings only — never interpolate payloads).
    public static let fetch = "fetch"
    public static let decode = "decode"
    public static let persist = "persist"
    public static let presenter = "presenter"
    public static let render = "render"
    public static let open = "open"

    // MARK: - Debug counters

    /// Counters are compiled in every configuration (cheap increments) but
    /// only DUMPED in debug builds — benchmark runs read them via
    /// `Perf.dumpCounters()` without Instruments.
    private static let counters: UnsafeMutablePointer<Int32> = {
        let p = UnsafeMutablePointer<Int32>.allocate(capacity: counterCount)
        p.initialize(repeating: 0, count: counterCount)
        return p
    }()
    private static let counterCount = 8

    private static let lock = NSLock()

    /// Named counter indexes (stable, for dump ordering).
    private enum Counter: Int {
        case redraws = 0, windowsCreated, timersArmed, monitorsInstalled
    }

    public static func count(_ counter: String) {
        lock.lock()
        defer { lock.unlock() }
        switch counter {
        case "redraws": counters[Counter.redraws.rawValue] &+= 1
        case "windows": counters[Counter.windowsCreated.rawValue] &+= 1
        case "timers": counters[Counter.timersArmed.rawValue] &+= 1
        case "monitors": counters[Counter.monitorsInstalled.rawValue] &+= 1
        default: break
        }
    }

    /// Prints and resets the counters. Debug/benchmark aid only.
    public static func dumpCounters() {
        #if DEBUG
        lock.lock()
        defer { lock.unlock() }
        print("Perf counters — redraws: \(counters[0]), windows: \(counters[1]), timers: \(counters[2]), monitors: \(counters[3])")
        for i in 0..<counterCount { counters[i] = 0 }
        #endif
    }
}
