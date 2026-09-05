// Sources/VelaCore/PollStateMachine.swift
// Pure Foundation state machine for the v2 polling pipeline: turns a stream
// of transport results into a ConnectionState (WP-03, §7.2) plus the last
// good snapshot, feeding history on every accepted success.
// Why: the poll transition rules (auth-vs-network classification, once-only
// auth notification, generation guard, scope partitioning) must be
// unit-testable without AppKit, timers, Keychain, or the network — this file
// is the whole decision layer and does no I/O of its own.
// WP-03: ConnectionState moved here from UsageContracts.swift (producer
// ownership, identical names/cases/semantics).
// RELEVANT FILES: Sources/App/PollCoordinator.swift, Sources/App/UsagePoller.swift,
// Sources/VelaCore/HistoryStore.swift, Sources/VelaCore/HistoryRepository.swift

import Foundation

// MARK: - ConnectionState

/// The credential/connection lifecycle state.
///
/// §7.2: "`noCredential`, `keychainBlocked`, `connecting`, `live`,
/// `retrying`, `stale`, `authenticationRequired`, `invalidResponse`;
/// retains last good snapshot separately" — the last good snapshot lives
/// OUTSIDE this enum, alongside it, so a stale reading still renders.
public enum ConnectionState: Equatable, Sendable {
    /// No credential has been provided yet.
    case noCredential
    /// The Keychain blocked the read (locked, denied, or unavailable).
    case keychainBlocked
    /// A fetch is in flight; no result yet.
    case connecting
    /// The latest fetch succeeded; the attached snapshot is current.
    case live
    /// Retrying after a transient failure; backoff in progress.
    case retrying(attempt: Int)
    /// Trust expired (receipt age beyond the freshness window) without a
    /// hard error.
    case stale
    /// The gateway rejected the credential (401-class).
    case authenticationRequired
    /// A response arrived but could not be validated (decode/shape).
    case invalidResponse
}

// MARK: - PollState (legacy v1 presentation shape)

/// What the v1 UI shows right now, based on the most recent fetch(es).
/// Retained verbatim so the current PopoverView/StatusItemController keep
/// rendering while WP-06 converts them to ConnectionState display states.
public enum PollState: Equatable, Sendable {
    /// No fetch has ever succeeded.
    case neverFetched
    /// The most recent fetch succeeded; this is the live snapshot.
    case fresh(UsageResponse)
    /// The last `consecutiveFailures` fetches have failed, but we still have
    /// a good snapshot from before the failures started.
    case stale(UsageResponse, consecutiveFailures: Int)
}

/// Turns a stream of `Result<UsageResponse, UsageError>` fetches into the
/// connection lifecycle, feeding the legacy `PollState` view shape and the
/// v1 history on every success.
///
/// Still a value type with no I/O beyond HistoryStore's in-memory `record`
/// (load/save remain the caller's responsibility).
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
    /// hasn't (or we don't know yet).
    public private(set) var exhaustedAt: Date?

    /// The instant of the most recent successful fetch, regardless of how
    /// many failures have piled up since.
    public private(set) var lastSuccessAt: Date?

    // The last successfully-fetched response, kept even while state is
    // .stale so a subsequent failure can keep referencing it.
    private var lastGood: UsageResponse?

    // Consecutive failures since the last success. Never reset except by a
    // success.
    private var consecutiveFailures = 0

    /// `historyDirectory` is injectable so tests can point the internal
    /// HistoryStore at a throwaway temp directory.
    public init(historyDirectory: URL = HistoryStore.defaultDirectory) {
        self.history = HistoryStore(directory: historyDirectory)
    }

    /// A snapshot of today's last known reading, rehydrated from history for
    /// the cold-open path. NEVER shows yesterday as today: the record's day
    /// key must BE today's UTC day key.
    public func coldOpenSnapshot(now: Date) -> (spentUSD: Double, limitUSD: Double, ageMinutes: Int)? {
        Self.coldOpenSnapshot(in: history, now: now)
    }

    /// The history-only form, for the App layer's loading path.
    public static func coldOpenSnapshot(in history: HistoryStore, now: Date) -> (spentUSD: Double, limitUSD: Double, ageMinutes: Int)? {
        guard let today = history.day(utcDate: now) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let nowHour = calendar.component(.hour, from: now)

        // Capping at nowHour refuses future data: a reading from later
        // "today" (clock correction, hand-edited file) is never current.
        guard let lastHour = today.hourly.indices.reversed().first(where: { $0 <= nowHour && today.hourly[$0] != nil }),
              let spent = today.hourly[lastHour] else { return nil }

        let ageMinutes = (nowHour - lastHour) * 60 + calendar.component(.minute, from: now)
        return (spentUSD: spent, limitUSD: today.limit, ageMinutes: ageMinutes)
    }

    /// Feeds one fetch result into the machine and returns the resulting
    /// state (also available afterwards as `self.state`).
    @discardableResult
    public mutating func ingest(_ result: Result<UsageResponse, UsageError>, at date: Date) -> PollState {
        switch result {
        case .success(let usage):
            consecutiveFailures = 0
            lastGood = usage
            lastSuccessAt = date
            burnBuffer.record(spentToday: usage.dailyBudget.spentUSD, at: date)
            history.record(spentToday: usage.dailyBudget.spentUSD, limit: usage.dailyBudget.limitUSD, limitEnabled: usage.dailyBudget.limitEnabled, at: date, spendDate: usage.dailyBudget.spendDate)
            exhaustedAt = history.day(spendDate: usage.dailyBudget.spendDate)?.exhaustedAt
            state = .fresh(usage)

        case .failure:
            consecutiveFailures += 1
            if consecutiveFailures >= 2, let lastGood {
                state = .stale(lastGood, consecutiveFailures: consecutiveFailures)
            }
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
