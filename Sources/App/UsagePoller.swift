// Sources/App/UsagePoller.swift
// Timer + wiring shell around PollStateMachine: owns a repeating
// DispatchSourceTimer, fetches via AIHubClientProtocol, and feeds each
// result into the state machine.
// Why: PollStateMachine is pure Foundation so it can be unit-tested; this
// class is the thin, untestable-by-design AppKit-adjacent layer that
// actually schedules fetches and hands results to it.
// RELEVANT FILES: Sources/VelaCore/PollStateMachine.swift, Sources/App/AIHubClient.swift, Sources/VelaCore/AIHubClientProtocol.swift

import Foundation

/// Polls the usage endpoint every 60 seconds and republishes the resulting
/// `PollState` via `onState`.
///
/// Owns no UI. `machine` is exposed read-only so the app layer can read
/// `burnBuffer` / `history` / `exhaustedAt` off it between ticks.
@MainActor
public final class UsagePoller {
    /// Called on the main actor with the new state after every ingested
    /// fetch result (success or failure).
    public var onState: ((PollState) -> Void)?

    public private(set) var machine: PollStateMachine

    private let client: AIHubClientProtocol
    private var timer: DispatchSourceTimer?

    // Guards against a timer tick firing while a fetch from the previous
    // tick is still in flight -- that tick is simply dropped, not queued.
    private var isFetchInFlight = false

    public init(client: AIHubClientProtocol, machine: PollStateMachine) {
        self.client = client
        self.machine = machine
    }

    /// Starts a repeating 60s timer (5s leeway, `.utility` QoS) that fires
    /// immediately on start, then every 60 seconds after.
    public func start() {
        stop()

        let newTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        newTimer.schedule(deadline: .now(), repeating: .seconds(60), leeway: .seconds(5))
        newTimer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.pollNow()
            }
        }
        newTimer.resume()
        timer = newTimer
    }

    /// Cancels the timer, if any. Safe to call when not started.
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Fetches usage once and ingests the result into `machine`, unless a
    /// previous fetch is still in flight (in which case this tick is
    /// dropped rather than queued).
    public func pollNow() {
        guard !isFetchInFlight else { return }
        isFetchInFlight = true

        client.fetchUsage { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isFetchInFlight = false
                let state = self.machine.ingest(result, at: Date())
                self.onState?(state)
            }
        }
    }
}
