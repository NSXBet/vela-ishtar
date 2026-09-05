// Sources/App/PollCoordinator.swift
// WP-03 items 03.3/03.4: the main-actor polling coordinator. Implements §6.2
// scheduling (60s ordinary cadence, launch/open/wake coalescing, five-second
// manual debounce, one request in flight, stop semantics, wake handling) and
// request generation: every fetch captures the credential generation and only
// a matching result commits (B02). 401/403 transitions ONCE to
// authenticationRequired and pauses retries until explicit user action (B06);
// no-token, unauthorized, network/5xx, and schema failures stay distinct (B05).
//
// Real backoff scheduling (§6.1/§6.2): the next fire is computed from the
// completed attempt's outcome — success → ordinary 60s cadence; transient
// failure → escalating ladder 60/120/240/300s (capped); Retry-After honored
// when LARGER than the ladder step (server-declared wait wins), capped at
// 300s. One-shot deadline scheduling: each completed attempt schedules the
// next fire; no permanent repeating timer.
// Why: UsagePoller (v1) had a bare timer with none of these guarantees. This
// coordinator is the single scheduler so "max one ordinary request in
// flight" and "deterministic under overlapping open/wake/timer/manual" are
// structural, not aspirational. Fully injectable clock + scheduler →
// deterministic tests, no real sleeps.
// RELEVANT FILES: Sources/App/CredentialController.swift, Sources/App/AIHubClient.swift,
// Sources/VelaCore/PollStateMachine.swift, Sources/VelaCore/AIHubClientProtocol.swift

import Foundation

/// Deterministic scheduler seam: one-shot next-deadline scheduling.
/// Production: a non-repeating DispatchSourceTimer re-armed after every
/// attempt. Tests: fire manually and record the scheduled delays.
public protocol PollScheduling: AnyObject {
    /// Arms a ONE-SHOT fire after `delay` seconds (replaces any prior fire).
    /// The fire closure is MainActor-isolated: the production scheduler
    /// hops it onto the main actor via a Task; a test scheduler can invoke
    /// it synchronously from a @MainActor context, making ticks
    /// deterministic.
    func scheduleNext(after delay: TimeInterval, fire: @escaping @MainActor () -> Void)
    func cancel()
}

/// Production one-shot timer over a serial utility queue.
public final class OneShotPollScheduler: PollScheduling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nsxbet.velaishtar.poll", qos: .utility)
    private var timer: DispatchSourceTimer?

    public init() {}

    public func scheduleNext(after delay: TimeInterval, fire: @escaping @MainActor () -> Void) {
        cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [fire] in
            Task { @MainActor in fire() }
        }
        source.resume()
        timer = source
    }

    public func cancel() {
        timer?.cancel()
        timer = nil
    }

    deinit { timer?.cancel() }
}

/// Clock seam so tests freeze/step time without sleeping.
public protocol PollClock: Sendable {
    var now: Date { get }
}

/// The wall clock the coordinator uses in production.
public struct SystemPollClock: PollClock {
    public init() {}
    public var now: Date { Date() }
}

/// Why the last commit path did not commit — surfaced for the UI to explain
/// honestly instead of collapsing every failure into "unreachable" (B05).
public enum PollFailureKind: Equatable, Sendable {
    /// Nothing stored, or Keychain denied — user action territory.
    case credentialUnavailable
    /// 401/403: the gateway rejected the token.
    case unauthorized
    /// Transient: network error, 5xx, timeout.
    case transient
    /// Response arrived but was not a valid usage payload.
    case schema
}

/// What the coordinator did with a fetch result — the bridge the app layer
/// consumes during the WP-06 conversion window. Committed successes carry a
/// VALIDATED `UsageSnapshot` (WP-01's `UsageValidation.snapshot`), scoped to
/// the credential that produced them — the raw `UsageResponse` never leaks
/// to consumers.
public struct PollOutcome: Equatable, Sendable {
    public let state: ConnectionState
    /// The committed validated snapshot, when a result committed this time.
    public let snapshot: UsageSnapshot?
    public let failureKind: PollFailureKind?
    /// True the FIRST time this failure episode moved to
    /// `.authenticationRequired` — the app may surface the recovery flow
    /// once. Subsequent 401s never re-fire it (03.3).
    public let authJustRequired: Bool

    public init(state: ConnectionState, snapshot: UsageSnapshot?, failureKind: PollFailureKind?, authJustRequired: Bool) {
        self.state = state
        self.snapshot = snapshot
        self.failureKind = failureKind
        self.authJustRequired = authJustRequired
    }
}

/// Main-actor polling coordinator (§7.2 contract surface):
/// `start()`, `stop()`, `refresh(reason:)`, `setCredentialGeneration(_:)`.
///
/// Every request captures the credential generation; only matching results
/// commit (B02). At most one ordinary request in flight; new triggers while
/// one is pending are coalesced, not queued (§6.2).
@MainActor
public final class PollCoordinator {
    // MARK: Configuration (§6.1/§6.2 constants)
    public nonisolated static let pollInterval: TimeInterval = 60
    public nonisolated static let manualDebounce: TimeInterval = 5
    /// Bounded backoff ladder for transient failures (§6.1).
    public nonisolated static let backoffSchedule: [TimeInterval] = [60, 120, 240, 300]
    public nonisolated static let maxBackoff: TimeInterval = 300
    /// Response size cap: decode never sees a payload larger than this
    /// (bounded before unbounded decode/allocation, 03.4).
    public nonisolated static let maxResponseBytes = 1_048_576
    /// Bounded per-request timeout (§03.4). A hung transport must not hold
    /// the single request slot forever; on timeout the request is cancelled
    /// and classified as a transient failure driving backoff.
    public nonisolated static let requestTimeout: TimeInterval = 30

    // MARK: Published state
    public private(set) var connection: ConnectionState = .noCredential
    /// The last good snapshot, retained SEPARATELY from the connection
    /// state so a stale reading still renders (§7.2 ConnectionState).
    public private(set) var lastGoodResponse: UsageResponse?
    public private(set) var lastGoodReceivedAt: Date?

    /// Bridge to the v1 app layer (WP-06 will consume richer state).
    public var onOutcome: ((PollOutcome) -> Void)?

    // MARK: Dependencies
    private let transport: any UsageTransport
    private let credentials: CredentialController
    private let scheduler: any PollScheduling
    private let clock: any PollClock
    /// The timeout race's sleeper: suspends until the request deadline.
    /// Production: real Task.sleep. Tests inject a deterministic manual
    /// fire (no real sleeps) — see `ManualTimeoutSleeper` in the tests.
    private let timeoutSleeper: @Sendable (TimeInterval) async throws -> Void

    // MARK: Scheduling state
    private var running = false
    /// Credential generation captured at request start; only matching
    /// results commit.
    private var credentialGeneration: UInt64 = 0
    private var requestInFlight = false
    private var inFlightGeneration: UInt64 = 0
    /// Identity of the ACTIVE request. A completion may only clear
    /// `requestInFlight` when its ID still matches — otherwise a stale
    /// request's completion path would release a NEWER request's slot
    /// (stop→start race) and let a third concurrent request through.
    private var inFlightRequestID = 0
    private var nextRequestID = 0
    /// The unstructured Task running the current fetch. Tests await it via
    /// `awaitIdle()` so results land deterministically — no sleeps.
    private var fetchTask: Task<Void, Never>?
    /// Results that arrived with a stale generation and were dropped
    /// (B02 guard). Surfaced for deterministic tests.
    public private(set) var droppedLateResults = 0
    private var transientFailureCount = 0
    /// 401 recovery latch: once authenticationRequired fires, normal polls
    /// PAUSE until explicit user action (03.3).
    private var awaitingCredentialRecovery = false
    /// Cancel dismissed the recovery flow — stays dismissed until the user
    /// explicitly requests the flow again (03.3). No timer re-opens it.
    private var recoveryDismissed = false
    /// Last manual refresh commit time for the five-second debounce.
    private var lastManualRefreshAt: Date?

    public init(
        transport: any UsageTransport,
        credentials: CredentialController,
        scheduler: any PollScheduling = OneShotPollScheduler(),
        clock: any PollClock = SystemPollClock(),
        timeoutSleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.transport = transport
        self.credentials = credentials
        self.scheduler = scheduler
        self.clock = clock
        self.timeoutSleeper = timeoutSleeper
    }

    // MARK: - Lifecycle

    /// Starts the poll cadence: an immediate launch refresh, whose outcome
    /// schedules the next one-shot fire. Re-starting a running coordinator
    /// is a no-op (idempotent).
    public func start() {
        guard !running else { return }
        running = true
        awaitableRefresh(.launch)
    }

    /// Stops the schedule and cancels any in-flight request's ability to
    /// commit (generation bump). Safe to call when not started. Called
    /// before callback delivery is fine: the late callback finds its
    /// generation stale and is dropped (test: "stop before callback").
    public func stop() {
        running = false
        scheduler.cancel()
        credentialGeneration &+= 1
        // Invalidate the active request's identity: its late completion
        // will fail the ownership gate and can neither commit nor release
        // the slot of a newer request. The slot itself is freed so a
        // subsequent start() can issue fresh work.
        inFlightRequestID += 1
        requestInFlight = false
        // Cancel the in-flight fetch (bounded cancellation, 03.4): the
        // transport's cooperative cancellation unwinds it; even a transport
        // that ignores cancellation cannot commit past the ownership gate.
        fetchTask?.cancel()
        fetchTask = nil
    }

    private func timerFired() {
        guard running, !awaitingCredentialRecovery else { return }
        awaitableRefresh(.scheduled)
    }

    // MARK: - Trigger entry points (§6.2)

    /// User-triggered refresh. `manual` is debounced to five seconds;
    /// other reasons coalesce onto the in-flight request instead of
    /// queueing a second one.
    public func refresh(reason: RefreshReason) {
        if reason == .manual, let last = lastManualRefreshAt,
           clock.now.timeIntervalSince(last) < Self.manualDebounce {
            return   // five-second action debounce
        }
        if reason == .manual { lastManualRefreshAt = clock.now }
        awaitableRefresh(reason)
    }

    /// Sync core trigger. When a request is already in flight the new
    /// trigger is DROPPED (coalesced onto the pending result), never queued
    /// — this preserves "max one ordinary request in flight" under
    /// overlapping open/wake/timer/manual.
    private func awaitableRefresh(_ reason: RefreshReason) {
        guard !awaitingCredentialRecovery || reason == .credentialChanged else { return }
        guard !requestInFlight else { return }
        requestInFlight = true
        inFlightGeneration = credentialGeneration
        nextRequestID += 1
        inFlightRequestID = nextRequestID

        if reason == .credentialChanged || lastGoodResponse == nil {
            connection = .connecting
        }

        let generation = inFlightGeneration
        let requestID = inFlightRequestID
        fetchTask = Task { @MainActor [weak self] in
            await self?.performFetch(generation: generation, requestID: requestID)
        }
    }

    /// Awaits the completion of the current fetch task (if any). Test seam
    /// for determinism: after `awaitIdle()`, every effect of the last
    /// trigger (outcome, state transition, next-fire schedule) has landed.
    public func awaitIdle() async {
        await fetchTask?.value
    }

    /// Bridge method so legacy call sites (`poller.pollNow()`) keep working
    /// through the WP-06 window.
    public func pollNow() {
        awaitableRefresh(.manual)
    }

    // MARK: - Credential generation

    /// §7.2: every request captures the generation; only matching results
    /// commit. Called by CredentialController-driven flow after an accepted
    /// replacement.
    public func setCredentialGeneration(_ generation: UInt64) {
        credentialGeneration = generation
        awaitingCredentialRecovery = false
        recoveryDismissed = false
    }

    /// Releases the in-flight slot ONLY if the completing request still
    /// owns it. Called from the token-unavailable early exit.
    private func clearInFlight(ownedBy requestID: Int) {
        guard requestID == inFlightRequestID else { return }
        requestInFlight = false
    }

    // MARK: - The fetch

    private func performFetch(generation: UInt64, requestID: Int) async {
        // Read the token off the interactive path via the controller.
        guard let token = await credentials.currentToken() else {
            clearInFlight(ownedBy: requestID)
            finish(kind: .credentialUnavailable)
            return
        }

        // Race the fetch against the deadline. The clock seam keeps this
        // deterministic: tests either complete the transport first or fire
        // the timeout continuation explicitly.
        let response: UsageResponse?
        let fetchError: Error?
        do {
            let transport = self.transport
            let timeout = Self.requestTimeout
            let sleeper = self.timeoutSleeper
            response = try await withThrowingTaskGroup(of: UsageResponse.self) { group in
                group.addTask { try await transport.fetchUsage(token: token) }
                group.addTask {
                    try await sleeper(timeout)
                    throw TimeoutError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            fetchError = nil
        } catch is TimeoutError {
            response = nil
            fetchError = UsageError.network("request timed out after \(Self.requestTimeout)s")
        } catch {
            response = nil
            fetchError = error
        }

        // Generation check FIRST: stop()/replacement/newer request means
        // this late result must not commit (B02; test: "stop before
        // callback", "A starts → B accepted → A completes late").
        // Ownership gate: a stale request (superseded by stop→start) may
        // neither commit NOR release the newer request's in-flight slot.
        guard requestID == inFlightRequestID else {
            droppedLateResults += 1
            return
        }
        guard generation == credentialGeneration, generation == inFlightGeneration else {
            requestInFlight = false
            droppedLateResults += 1
            return
        }
        requestInFlight = false
        guard running else { return }

        // receivedAt is the RESPONSE RECEIPT time — captured here, after
        // the transport await, never at request start. Stamping the start
        // would dilute burn intervals by the transport latency and could
        // land a fresh response already-90s-stale.
        let receivedAt = clock.now

        if let response {
            accept(response, receivedAt: receivedAt)
        } else if let fetchError {
            fail(with: fetchError)
        }
    }

    private func accept(_ response: UsageResponse, receivedAt: Date) {
        // Validate into the domain BEFORE committing (§7.2): the snapshot
        // carries the credential scope, so observations derived from it are
        // partitioned per credential. A domain-invalid payload (malformed,
        // non-finite) must NOT commit as .live.
        if Self.domainValidationError(in: response) != nil {
            connection = lastGoodResponse == nil ? .invalidResponse : connection
            onOutcome?(PollOutcome(
                state: connection,
                snapshot: nil,
                failureKind: .schema,
                authJustRequired: false
            ))
            // Schema failure retries on the ordinary cadence, not backoff.
            scheduleOrdinaryPoll()
            return
        }

        guard let scope = credentials.scope else {
            // No scoped credential installed yet — cannot attribute the
            // reading; refuse to commit rather than inventing a scope.
            connection = lastGoodResponse == nil ? .invalidResponse : connection
            onOutcome?(PollOutcome(state: connection, snapshot: nil, failureKind: .schema, authJustRequired: false))
            scheduleOrdinaryPoll()
            return
        }
        let snapshot = UsageValidation.snapshot(from: response, scope: scope, receivedAt: receivedAt)
        lastGoodResponse = response
        lastGoodReceivedAt = receivedAt
        transientFailureCount = 0
        awaitingCredentialRecovery = false
        connection = .live

        // Success → ordinary cadence.
        scheduler.scheduleNext(after: Self.pollInterval) { [weak self] in
            self?.timerFired()
        }

        onOutcome?(PollOutcome(state: .live, snapshot: snapshot, failureKind: nil, authJustRequired: false))
    }

    private func fail(with error: Error) {
        var retryAfterHint: TimeInterval?
        let kind: PollFailureKind
        // Unwrap a Retry-After carrier FIRST so its seconds reach the
        // backoff computation; the wrapped base error then classifies
        // normally.
        let unwrapped = (error as? RetryAfterError)?.base ?? error
        retryAfterHint = error.retryAfterHint
        switch unwrapped as? UsageError {
        case .unauthorized:
            kind = .unauthorized
        case .noToken, .keychainBlocked:
            kind = .credentialUnavailable
        case .decode:
            kind = .schema
        case .badStatus:
            kind = .transient
        case .network, .none:
            kind = .transient
        }

        switch kind {
        case .unauthorized:
            // 03.3: transition ONCE to authenticationRequired, then PAUSE
            // retries until explicit user action. No repeated modal theft,
            // and NO next-fire scheduling while paused.
            let justRequired = !awaitingCredentialRecovery
            awaitingCredentialRecovery = true
            connection = .authenticationRequired
            scheduler.cancel()
            onOutcome?(PollOutcome(
                state: .authenticationRequired,
                snapshot: nil,
                failureKind: .unauthorized,
                authJustRequired: justRequired && !recoveryDismissed
            ))

        case .credentialUnavailable:
            connection = lastGoodResponse == nil ? .noCredential : .stale
            scheduleOrdinaryPoll()
            onOutcome?(PollOutcome(
                state: connection,
                snapshot: nil,
                failureKind: .credentialUnavailable,
                authJustRequired: false
            ))

        case .schema:
            connection = lastGoodResponse == nil ? .invalidResponse : connection
            scheduleOrdinaryPoll()
            onOutcome?(PollOutcome(
                state: connection,
                snapshot: nil,
                failureKind: .schema,
                authJustRequired: false
            ))

        case .transient:
            transientFailureCount += 1
            let attempt = transientFailureCount
            connection = lastGoodResponse == nil ? .retrying(attempt: attempt) : .stale
            // Escalating backoff, Retry-After honored when larger, capped.
            let delay = Self.effectiveBackoff(scheduleIndex: attempt - 1, retryAfter: retryAfterHint)
            scheduler.scheduleNext(after: delay) { [weak self] in
                self?.timerFired()
            }
            onOutcome?(PollOutcome(
                state: connection,
                snapshot: nil,
                failureKind: .transient,
                authJustRequired: false
            ))
        }
    }

    private func finish(kind: PollFailureKind) {
        switch kind {
        case .credentialUnavailable:
            connection = lastGoodResponse == nil ? .noCredential : .stale
            scheduleOrdinaryPoll()
            onOutcome?(PollOutcome(state: connection, snapshot: nil, failureKind: kind, authJustRequired: false))
        default:
            break
        }
    }

    /// Non-backoff outcomes retry on the ordinary cadence.
    private func scheduleOrdinaryPoll() {
        scheduler.scheduleNext(after: Self.pollInterval) { [weak self] in
            self?.timerFired()
        }
    }

    // MARK: - Domain validation (WP-01 seam)

    /// Domain-level payload rejection: a malformed spend_date, a
    /// negative/non-finite monetary value, or a negative count is a schema
    /// failure — the response must NOT commit as .live. Mirrors WP-01's
    /// `UsageValidation.money`/`count` gates; coordinator's own seam until
    /// a shared `UsageValidation.domainError(in:)` lands (coordinator
    /// proposal to WP-01).
    nonisolated static func domainValidationError(in response: UsageResponse) -> UsageError? {
        let b = response.dailyBudget
        guard UsageValidation.money(b.spentUSD) != nil,
              UsageValidation.money(b.limitUSD) != nil,
              UsageValidation.money(b.remainingUSD) != nil else {
            return .decode
        }
        guard UsageValidation.count(response.currentMonth.requests) != nil else {
            return .decode
        }
        return nil
    }

    // MARK: - Backoff arithmetic (§6.1)

    /// Next-fire delay for a transient failure. Ladder 60/120/240/300
    /// (capped at `maxBackoff`). A Retry-After hint is honored when LARGER
    /// than the ladder step (the server-declared wait wins), still capped.
    public nonisolated static func effectiveBackoff(scheduleIndex: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let ladder: [TimeInterval] = [60, 120, 240, 300]
        let index = max(scheduleIndex, 0)
        let base = ladder[min(index, ladder.count - 1)]
        guard let hint = retryAfter, hint > 0 else { return base }
        return min(max(base, hint), maxBackoff)
    }

    // MARK: - Recovery flow interaction (03.3)

    /// Called by the app after the user acknowledged recovery (opened the
    /// token flow deliberately) so a subsequent 401 fires authJustRequired
    /// again. Distinct from automatic re-prompting: only explicit user
    /// action re-arms.
    public func acknowledgeRecoveryFlow() {
        recoveryDismissed = false
    }

    /// User dismissed the recovery flow (Cancel). The latch stays latched —
    /// the UI shows a stable actionable status; nothing re-activates the
    /// token panel until the user requests it (03.3).
    public func dismissRecovery() {
        recoveryDismissed = true
    }
}

/// A fetch exceeded its bounded timeout (03.4).
public struct TimeoutError: Error {}

extension Error {
    /// The Retry-After hint carried by this error, if any.
    var retryAfterHint: TimeInterval? {
        (self as? RetryAfterError)?.hint
    }
}

public struct RetryAfterError: Error {
    public let base: UsageError
    public let hint: TimeInterval
    public init(base: UsageError, hint: TimeInterval) {
        self.base = base
        self.hint = hint
    }
}

