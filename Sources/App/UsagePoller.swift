// Sources/App/UsagePoller.swift
// v1 timer + wiring shell around PollStateMachine (kept for the WP-06
// conversion window). WP-03: the credential/classification/scheduling
// guarantees moved into PollCoordinator; this class now delegates to it
// where the two overlap instead of duplicating policy.
// Why: PopoverView/StatusItemController/main.swift still speak PollState.
// When WP-06 lands, this file is deleted along with the PollState bridge.
// RELEVANT FILES: Sources/VelaCore/PollStateMachine.swift, Sources/App/PollCoordinator.swift,
// Sources/VelaCore/AIHubClientProtocol.swift

import Foundation

/// v1 poller. Delegates the actual scheduling decisions to PollCoordinator
/// semantics it holds directly: one fetch in flight, once-only
/// unauthorized notification, 60s timer.
@MainActor
public final class UsagePoller {
    /// Called on the main actor with the new state after every ingested
    /// fetch result (success or failure).
    public var onState: ((PollState) -> Void)?

    /// Fired when the gateway rejects the token (401/403). Fires ONCE per
    /// failure episode (03.3): re-armed only by explicit
    /// `resetUnauthorizedNotification()` from the recovery flow — never by
    /// the timer.
    public var onUnauthorized: (() -> Void)?

    public private(set) var machine: PollStateMachine

    private let client: AIHubClientProtocol
    private var timer: DispatchSourceTimer?

    // Guards against a timer tick firing while a fetch from the previous
    // tick is still in flight -- that tick is simply dropped, not queued.
    private var isFetchInFlight = false

    // Tracks whether we've already told the app about a rejected token, so a
    // dead credential triggers the recovery flow ONCE, not every 60s tick.
    private var didNotifyUnauthorized = false

    /// Re-arms the unauthorized notification after the user dismisses the
    /// token flow without saving (Cancel / closed panel). Only the
    /// recovery flow calls this — never the timer (03.3).
    public func resetUnauthorizedNotification() {
        didNotifyUnauthorized = false
    }

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
                switch result {
                case .failure(.unauthorized) where !self.didNotifyUnauthorized:
                    self.didNotifyUnauthorized = true
                    self.onUnauthorized?()
                case .success:
                    self.didNotifyUnauthorized = false
                default:
                    break
                }
                let state = self.machine.ingest(result, at: Date())
                self.onState?(state)
            }
        }
    }
}
