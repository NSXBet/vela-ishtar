// Sources/VelaCore/PollStateMachine.swift
// Pure state machine that turns a stream of fetch Results into a PollState,
// feeding BurnBuffer and HistoryStore on every success.
// Why: this is the one piece of poll logic that must be unit-testable without
// AppKit or a timer, so it lives here (not Sources/App) and stays pure
// Foundation -- the timer/wiring shell around it is UsagePoller.
// RELEVANT FILES: Sources/App/UsagePoller.swift, Sources/VelaCore/BurnBuffer.swift, Sources/VelaCore/HistoryStore.swift, Tests/VelaCoreTests/PollStateMachineTests.swift

import Foundation

/// What the UI should show right now, based on the most recent fetch(es).
public enum PollState: Equatable, Sendable {
    /// No fetch has ever succeeded.
    case neverFetched
    /// The most recent fetch succeeded; this is the live snapshot.
    case fresh(UsageResponse)
    /// The last `consecutiveFailures` fetches have failed, but we still have
    /// a good snapshot from before the failures started.
    case stale(UsageResponse, consecutiveFailures: Int)
}

/// Turns a stream of `Result<UsageResponse, UsageError>` fetches into a
/// `PollState`, feeding `BurnBuffer` and `HistoryStore` on every success.
///
/// This is a value type with no I/O of its own beyond what `HistoryStore`
/// does inside `record` (in-memory only -- `load`/`save` are the caller's
/// responsibility, since they're an app-lifecycle concern, not a
/// poll-transition concern).
public struct PollStateMachine: Sendable {
    public private(set) var state: PollState = .neverFetched
    public private(set) var burnBuffer = BurnBuffer()
    public private(set) var history: HistoryStore
    public private(set) var snapshots: ModelSnapshots

    /// The most recent Today-by-model split, recomputed on each successful
    /// ingest. Starts unavailable (no baseline until the second gateway day).
    /// The App layer renders `.split` as rows and `.unavailable` as a note.
    public private(set) var todayModelSplit: TodayModelSplitResult = .unavailable(.noBaseline)

    /// Loads persisted spend history AND model snapshots from disk
    /// (no-op-safe if either file is missing). Called once at app launch
    /// before polling starts.
    public mutating func loadHistory() {
        try? history.load()
        try? snapshots.load()
    }

    /// Persists spend history and model snapshots atomically (tmp + rename).
    /// Called after each successful poll and on quit — a few KB once a
    /// minute, battery cost nil.
    public func saveHistory() {
        try? history.save()
        try? snapshots.save()
    }

    /// The instant today's spend first crossed the limit, or nil if it
    /// hasn't (or we don't know yet). Mirrors `HistoryStore.DayRecord.exhaustedAt`
    /// for the day of the most recent successful fetch, so the App layer can
    /// pass it straight into `PaceEngine.verdict(...)`.
    public private(set) var exhaustedAt: Date?

    /// The instant of the most recent successful fetch, regardless of how
    /// many failures have piled up since. The App layer uses this to show
    /// "data is N minutes old" while stale.
    public private(set) var lastSuccessAt: Date?

    // The last successfully-fetched response, kept even while state is
    // .stale so a subsequent failure can keep referencing it.
    private var lastGood: UsageResponse?

    // Consecutive failures since the last success. Never reset except by a
    // success (per the brief: "Never resets the counter except on success").
    private var consecutiveFailures = 0

    /// `historyDirectory` is injectable so tests can point the internal
    /// HistoryStore at a throwaway temp directory instead of the app's real
    /// support directory. ModelSnapshots shares the same directory (a second
    /// file, snapshots.json, alongside history.json).
    public init(historyDirectory: URL = HistoryStore.defaultDirectory) {
        self.init(historyDirectory: historyDirectory, snapshotMaxKeys: ModelSnapshots.maxKeys)
    }

    /// Internal test seam for the retention-boundary regression. Production
    /// constructs the public initializer and always keeps seven snapshots.
    init(historyDirectory: URL, snapshotMaxKeys: Int) {
        self.history = HistoryStore(directory: historyDirectory)
        self.snapshots = ModelSnapshots(directory: historyDirectory, maxKeys: snapshotMaxKeys)
    }

    /// A snapshot of today's last known reading, rehydrated from history for
    /// the cold-open path. Why: on a cold start the popover's first paint has
    /// no fetch result yet (state is `.neverFetched`), and the loading branch
    /// blanks the hero for 0.5–1s until the network lands. If history already
    /// holds a reading keyed to TODAY's UTC day, we can show it immediately —
    /// dimmed and labeled "Last reading" — so the user sees a number, not a
    /// spinner.
    ///
    /// The hard invariant: NEVER show yesterday as today. The record's day
    /// key must BE today's UTC day key, else this returns nil and the spinner
    /// stays. Around the midnight seam the gateway's `spendDate` lags the
    /// local clock, so a reading recorded late yesterday carries yesterday's
    /// key and is correctly refused.
    ///
    /// - Returns: `(spentUSD, limitUSD, ageMinutes)` of the most recent
    ///   observed hour today, or nil when there's no today-keyed record.
    public func coldOpenSnapshot(now: Date) -> (spentUSD: Double, limitUSD: Double, ageMinutes: Int)? {
        Self.coldOpenSnapshot(in: history, now: now)
    }

    /// The history-only form, for the App layer's loading path which holds a
    /// `HistoryStore` but shouldn't need a whole machine to ask this.
    public static func coldOpenSnapshot(in history: HistoryStore, now: Date) -> (spentUSD: Double, limitUSD: Double, ageMinutes: Int)? {
        guard let today = history.day(utcDate: now) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let nowHour = calendar.component(.hour, from: now)

        // The freshest reading is the last non-nil slot AT OR BEFORE the
        // current hour. Normally a future slot can't exist for a today-keyed
        // record — but a clock correction or a hand-edited history file could
        // leave one, and the naive last-non-nil search would then read it and
        // clamp its negative age to "just now". Capping at nowHour refuses
        // future data: a reading from later "today" is never shown as current.
        guard let lastHour = today.hourly.indices.reversed().first(where: { $0 <= nowHour && today.hourly[$0] != nil }),
              let spent = today.hourly[lastHour] else { return nil }

        // Age = whole minutes between the recorded hour-slot START and now.
        // Slot times are hour-granular, so use the START of each hour; the
        // cap above guarantees nowHour >= lastHour, so the value is honest.
        let ageMinutes = (nowHour - lastHour) * 60 + calendar.component(.minute, from: now)
        return (spentUSD: spent, limitUSD: today.limit, ageMinutes: ageMinutes)
    }

    /// Feeds one fetch result into the machine and returns the resulting
    /// state (also available afterwards as `self.state`).
    ///
    /// Success: resets the failure counter, records into burnBuffer and
    /// history, and emits `.fresh`.
    ///
    /// Failure: increments the failure counter. Once the counter reaches 2
    /// AND we have a last-good response, emits `.stale(lastGood, n)`. Before
    /// that threshold (or with no last-good response yet), the state is left
    /// unchanged -- a single blip doesn't flip the UI, and with nothing good
    /// to fall back on we simply keep counting from `.neverFetched`.
    @discardableResult
    public mutating func ingest(_ result: Result<UsageResponse, UsageError>, at date: Date) -> PollState {
        switch result {
        case .success(let usage):
            consecutiveFailures = 0
            lastGood = usage
            lastSuccessAt = date
            burnBuffer.record(spentToday: usage.dailyBudget.spentUSD, at: date)
            history.record(spentToday: usage.dailyBudget.spentUSD, limit: usage.dailyBudget.limitUSD, limitEnabled: usage.dailyBudget.limitEnabled, at: date, spendDate: usage.dailyBudget.spendDate)
            // exhaustedAt must come from the GATEWAY's day, not the local
            // clock's -- the two disagree around the UTC-midnight seam (the
            // whole point of the spendDate keying above).
            exhaustedAt = history.day(spendDate: usage.dailyBudget.spendDate)?.exhaustedAt
            // Compute the Today-by-model split before recording this response.
            // `baseline(before:)` always reads the prior gateway day, never
            // today's key. In ordinary chronological polling either statement
            // order sees that baseline, but at a full retention window an
            // out-of-order day can otherwise prune its own prior-day baseline
            // before the split reads it.
            todayModelSplit = TodayModelSplitEngine.split(
                current: usage,
                baseline: snapshots.baseline(before: usage.dailyBudget.spendDate)
            )
            snapshots.record(usage, at: date)
            state = .fresh(usage)

        case .failure:
            consecutiveFailures += 1
            if consecutiveFailures >= 2, let lastGood {
                state = .stale(lastGood, consecutiveFailures: consecutiveFailures)
            }
            // else: no last-good yet, or only 1 failure so far -- leave
            // state as-is (stays .neverFetched, or holds the existing
            // .fresh/.stale reading).
        }
        return state
    }
}

extension HistoryStore {
    /// The app's real on-disk history location. Not used by tests (which
    /// always inject a throwaway temp directory), only by production code
    /// that constructs a `PollStateMachine` with its default init.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("VelaIshtar", isDirectory: true)
    }
}
