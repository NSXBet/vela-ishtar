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

    /// Loads persisted spend history from disk (no-op-safe if the file is
    /// missing). Called once at app launch before polling starts.
    public mutating func loadHistory() {
        try? history.load()
    }

    /// Persists spend history atomically (tmp + rename). Called after each
    /// successful poll and on quit — a few KB once a minute, battery cost nil.
    public func saveHistory() {
        try? history.save()
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
    /// support directory.
    public init(historyDirectory: URL = HistoryStore.defaultDirectory) {
        self.history = HistoryStore(directory: historyDirectory)
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
            history.record(spentToday: usage.dailyBudget.spentUSD, limit: usage.dailyBudget.limitUSD, at: date)
            exhaustedAt = history.day(utcDate: date)?.exhaustedAt
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
