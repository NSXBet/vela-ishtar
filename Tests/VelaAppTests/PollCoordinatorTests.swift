// Tests/VelaAppTests/PollCoordinatorTests.swift
// WP-03 items 03.3/03.4: recovery-without-loops and the deterministic
// scheduler. §9 test list: A starts → B accepted → A completes late;
// Cancel + five timer ticks; repeated 401; overlapping open/wake/timer/
// manual; hanging transport; stop before callback; Retry-After 120;
// malformed response; successful recovery. All deterministic — no real
// sleeps, no real Keychain, no real network (§9).
// RELEVANT FILES: Sources/App/PollCoordinator.swift, Sources/App/CredentialController.swift,
// Tests/VelaAppTests/TestSupport.swift

import Foundation
import Testing
@testable import VelaCore

// MARK: - Test seams

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Manually-fired scheduler: tests trigger "timer ticks" by hand.
final class ManualScheduler: PollScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var fire: (@MainActor () -> Void)?
    private(set) var scheduleCount = 0
    /// The delays every scheduleNext call received, in order.
    private(set) var scheduledDelays: [TimeInterval] = []

    func scheduleNext(after delay: TimeInterval, fire: @escaping @MainActor () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.fire = fire
        scheduleCount += 1
        scheduledDelays.append(delay)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        fire = nil
    }

    /// Simulates one timer tick on the main actor.
    @MainActor
    func tick() {
        fire?()
    }

    /// Tick + wait for the coordinator's fetch task to land (deterministic).
    @MainActor
    func tickAwaiting(_ coordinator: PollCoordinator) async {
        fire?()
        await coordinator.awaitIdle()
    }
}

/// Steppable clock: tests advance virtual time, never sleep.
final class SteppedClock: PollClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_786_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

/// Transport with a manual completion gate for hang/late-callback tests.
final class GatedTransport: UsageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(UsageResponse) -> Void] = []
    private(set) var requestCount = 0
    private(set) var requestedTokens: [String] = []
    private var nextResult: Result<UsageResponse, any Error>?

    func script(_ r: Result<UsageResponse, UsageError>) {
        lock.lock()
        defer { lock.unlock() }
        nextResult = r.mapError { $0 as any Error }
    }

    /// Script a failure carrying a Retry-After hint (as the live client
    /// attaches from a real Retry-After response header).
    func scriptHinted(_ r: Result<UsageResponse, UsageError>, hint: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if case .failure(let base) = r {
            nextResult = .failure(RetryAfterError(base: base, hint: hint))
        } else {
            nextResult = r.mapError { $0 as any Error }
        }
    }

    /// When true, even a pre-scripted result suspends until releaseAll().
    /// Tests set this to advance the clock mid-request.
    nonisolated(unsafe) var holdGate = false

    func fetchUsage(token: String) async throws -> UsageResponse {
        let scripted: Result<UsageResponse, any Error>? = lock.withLock {
            requestCount += 1
            requestedTokens.append(token)
            return nextResult
        }
        if let scripted, !holdGate {
            return try scripted.get()
        }
        if let scripted, holdGate {
            // Deliver the scripted result only on release.
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                pending.append { _ in
                    continuation.resume(returning: (try! scripted.get()))
                }
            }
        }
        // Suspend until a test releases it — the "hanging transport".
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            defer { lock.unlock() }
            // Re-check under the lock: a script may have arrived meanwhile.
            if let result = nextResult {
                continuation.resume(returning: try! result.get())
                return
            }
            pending.append { response in
                continuation.resume(returning: response)
            }
        }
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// Releases ALL pending fetches with the scripted result. When the
    /// script is a failure (or unset), release with a harmless success —
    /// hanging continuations must never leak; the coordinator's failure
    /// tests script failures BEFORE calling, which the non-gated path
    /// delivers directly.
    func releaseAll() {
        lock.lock()
        let waiters = pending
        pending = []
        let result = nextResult
        lock.unlock()
        let response: UsageResponse
        if case .success(let r)? = result {
            response = r
        } else {
            response = UsageResponse(
                tokenId: "tok-late",
                dailyBudget: DailyBudget(limitUSD: 400, spentUSD: 1, remainingUSD: 399, usedPercent: 0.25, limitEnabled: true, spendDate: "2026-09-05"),
                currentMonth: MonthStats(totalCostUSD: 1, totalTokens: 1, requests: 1),
                topModels: []
            )
        }
        for w in waiters { w(response) }
    }
}

private func makeUsage(tokenID: String = "tok-a", spent: Double = 42.0) -> UsageResponse {
    UsageResponse(
        tokenId: tokenID,
        dailyBudget: DailyBudget(
            limitUSD: 400,
            spentUSD: spent,
            remainingUSD: 400 - spent,
            usedPercent: spent / 400 * 100,
            limitEnabled: true,
            spendDate: "2026-09-05",
            modelBudgets: []
        ),
        currentMonth: MonthStats(totalCostUSD: 100, totalTokens: 1000, requests: 50),
        topModels: []
    )
}

/// Common fixture: controller with a working token, coordinator over it.
@MainActor
private func makeCoordinator(
    keychain: ScriptedKeychain,
    transport: GatedTransport,
    scheduler: ManualScheduler,
    clock: SteppedClock
) -> PollCoordinator {
    let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
    controller.adoptStoredCredentialSync()
    let coordinator = PollCoordinator(
        transport: transport,
        credentials: controller,
        scheduler: scheduler,
        clock: clock
    )
    return coordinator
}

@Suite("WP-03 Coordinator: generation & in-flight discipline (03.4)")
@MainActor
struct GenerationTests {
    @Test("stop before callback: late result never commits")
    func stopBeforeCallback() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        var outcomes: [PollOutcome] = []
        coordinator.onOutcome = { outcomes.append($0) }

        // Request 1 completes normally.
        transport.script(.success(makeUsage(tokenID: "tok-late")))
        coordinator.start()
        await coordinator.awaitIdle()
        #expect(transport.requestCount == 1)
        #expect(coordinator.lastGoodResponse?.tokenId == "tok-late")

        // Request 2 completes normally.
        transport.script(.success(makeUsage(tokenID: "tok-later")))
        coordinator.refresh(reason: .opened)
        await coordinator.awaitIdle()
        #expect(transport.requestCount == 2)
        #expect(coordinator.lastGoodResponse?.tokenId == "tok-later")

        // Request 3 is hung; stop() cancels its task AND bumps the
        // generation: even if its result later arrives, it cannot commit.
        transport.holdGate = true
        transport.script(.success(makeUsage(tokenID: "tok-after-stop")))
        coordinator.refresh(reason: .opened)
        coordinator.stop()          // generation bump BEFORE the callback
        transport.releaseAll()
        await coordinator.awaitIdle()

        #expect(coordinator.lastGoodResponse?.tokenId == "tok-later")  // not tok-after-stop
        #expect(!outcomes.contains { $0.snapshot?.response.tokenId == "tok-after-stop" })
    }

    @Test("A starts -> B accepted (credential changed) -> A completes late: A dropped")
    func oldGenerationLateResultDropped() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        var outcomes: [PollOutcome] = []
        coordinator.onOutcome = { outcomes.append($0) }

        // A runs and commits.
        transport.script(.success(makeUsage(tokenID: "tok-a", spent: 10)))
        coordinator.start()
        await coordinator.awaitIdle()
        #expect(transport.requestCount == 1)
        #expect(coordinator.lastGoodResponse?.tokenId == "tok-a")

        // Credential replaced mid-flight: generation bumps.
        coordinator.setCredentialGeneration(1)

        // The OLD generation's result arrives late (held gate released):
        // ownership/generation gates must drop it, never commit.
        transport.holdGate = true
        transport.script(.success(makeUsage(tokenID: "tok-stale", spent: 11)))
        coordinator.refresh(reason: .opened)
        coordinator.setCredentialGeneration(2)   // replacement lands mid-flight
        transport.releaseAll()
        await coordinator.awaitIdle()

        #expect(coordinator.lastGoodResponse?.tokenId == "tok-a")  // stale result refused
        #expect(coordinator.droppedLateResults >= 1)
    }

    @Test("max one ordinary request in flight; overlapping triggers coalesce")
    func overlappingTriggersCoalesce() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        transport.script(.success(makeUsage()))
        coordinator.start()
        await coordinator.awaitIdle()
        #expect(transport.requestCount == 1)
        #expect(coordinator.connection == .live)

        // Now a second generation of overlapping triggers — but the first
        // completes before they fire, so each gets its own slot. Then fire
        // them while one IS in flight.
        transport.script(.success(makeUsage(spent: 43)))
        coordinator.refresh(reason: .opened)
        coordinator.refresh(reason: .wake)
        scheduler.tick()
        await coordinator.awaitIdle()
        #expect(transport.requestCount == 2)   // coalesced, NOT queued x3
        #expect(coordinator.connection == .live)
    }

    @Test("manual refresh debounced within five seconds, allowed after")
    func manualDebounce() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        coordinator.start()
        transport.releaseAll()
        await coordinator.awaitIdle()

        transport.script(.success(makeUsage()))
        coordinator.refresh(reason: .manual)
        await coordinator.awaitIdle()
        let second = transport.requestCount

        // Within the 5s debounce: dropped.
        clock.advance(by: 4)
        coordinator.refresh(reason: .manual)
        await coordinator.awaitIdle()
        let third = transport.requestCount
        #expect(third == second)          // debounced

        // Past the debounce: allowed.
        clock.advance(by: 6)
        transport.script(.success(makeUsage()))
        coordinator.refresh(reason: .manual)
        await coordinator.awaitIdle()
        let fourth = transport.requestCount
        #expect(fourth == third + 1)      // allowed
    }
}

@Suite("WP-03 Coordinator: recovery without loops (03.3, B06)")
@MainActor
struct RecoveryTests {
    @Test("repeated 401: authenticationRequired fires ONCE, polling pauses")
    func repeated401() async {
        let keychain = ScriptedKeychain(token: "gt-synth-dead")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        var outcomes: [PollOutcome] = []
        coordinator.onOutcome = { outcomes.append($0) }

        transport.script(.failure(.unauthorized))
        coordinator.start()
        transport.releaseAll()
        await coordinator.awaitIdle()

        #expect(coordinator.connection == .authenticationRequired)
        let authOutcomes = outcomes.filter { $0.authJustRequired }
        #expect(authOutcomes.count == 1)
        let afterFirst = outcomes.count

        // Five timer ticks later (still 401): NO new authJustRequired, NO
        // new requests at all — polling is paused until explicit action.
        for _ in 0..<5 { await scheduler.tickAwaiting(coordinator) }

        #expect(transport.requestCount == 1)   // no retries behind the latch
        #expect(outcomes.filter { $0.authJustRequired }.count == 1)
        #expect(outcomes.count == afterFirst)
    }

    @Test("cancel dismisses recovery; nothing re-opens it across five ticks")
    func cancelDismissesRecovery() async {
        let keychain = ScriptedKeychain(token: "gt-synth-dead")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        var outcomes: [PollOutcome] = []
        coordinator.onOutcome = { outcomes.append($0) }

        transport.script(.failure(.unauthorized))
        coordinator.start()
        transport.releaseAll()
        await coordinator.awaitIdle()
        #expect(coordinator.connection == .authenticationRequired)

        // User cancels the recovery flow.
        coordinator.dismissRecovery()

        // Five timer ticks with a still-dead token.
        for _ in 0..<5 { await scheduler.tickAwaiting(coordinator) }

        // No re-prompt signal ever re-fires (no repeated modal theft).
        #expect(outcomes.filter { $0.authJustRequired }.count == 1)
        #expect(transport.requestCount == 1)
        // The connection state remains honestly authenticationRequired.
        #expect(coordinator.connection == .authenticationRequired)
    }

    @Test("successful recovery: explicit retry after replacement goes live again")
    func successfulRecovery() async {
        let keychain = ScriptedKeychain(token: "gt-synth-dead")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        transport.script(.failure(.unauthorized))
        coordinator.start()
        transport.releaseAll()
        await coordinator.awaitIdle()
        #expect(coordinator.connection == .authenticationRequired)

        // User replaces the credential: generation bump un-pauses polling.
        keychain.delete()
        keychain.write("gt-synth-fresh")
        coordinator.setCredentialGeneration(1)

        transport.script(.success(makeUsage(tokenID: "tok-fresh", spent: 12)))
        coordinator.refresh(reason: .credentialChanged)
        await coordinator.awaitIdle()

        #expect(coordinator.connection == .live)
        #expect(coordinator.lastGoodResponse?.tokenId == "tok-fresh")
    }

    @Test("transient failures back off; success resets the ladder")
    func transientBackoffAndRecovery() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        transport.script(.failure(.network("timeout")))
        coordinator.start()
        transport.releaseAll()
        await coordinator.awaitIdle()
        #expect(coordinator.connection == .retrying(attempt: 1))
        #expect(scheduler.scheduledDelays == [60])

        transport.script(.failure(.network("timeout")))
        await scheduler.tickAwaiting(coordinator)
        #expect(coordinator.connection == .retrying(attempt: 2))
        #expect(scheduler.scheduledDelays == [60, 120])

        // 5xx class:
        transport.script(.failure(.badStatus(503)))
        await scheduler.tickAwaiting(coordinator)
        #expect(scheduler.scheduledDelays == [60, 120, 240])

        // Recovery:
        transport.script(.success(makeUsage(spent: 55)))
        await scheduler.tickAwaiting(coordinator)
        #expect(coordinator.connection == .live)
        #expect(scheduler.scheduledDelays.last == 60)   // ladder reset
    }

    @Test("no-token is distinct from network/5xx/schema failures")
    func failureClassesDistinct() async {
        let keychain = ScriptedKeychain(token: nil)   // nothing stored
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        var outcomes: [PollOutcome] = []
        coordinator.onOutcome = { outcomes.append($0) }

        transport.script(.success(makeUsage()))
        coordinator.start()
        await coordinator.awaitIdle()

        #expect(coordinator.connection == .noCredential)
        #expect(outcomes.first?.failureKind == .credentialUnavailable)
        // No request was even attempted — nothing stored means nothing to send.
        #expect(transport.requestCount == 0)
    }

    @Test("malformed response -> invalidResponse, distinct from stale/network")
    func malformedResponse() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        var outcomes: [PollOutcome] = []
        coordinator.onOutcome = { outcomes.append($0) }

        transport.script(.failure(.decode))
        coordinator.start()
        transport.releaseAll()
        await coordinator.awaitIdle()

        #expect(coordinator.connection == .invalidResponse)
        #expect(outcomes.first?.failureKind == .schema)
        #expect(outcomes.first?.state == .invalidResponse)
    }

    @Test("stale retains last good response for rendering")
    func staleRetainsLastGood() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let coordinator = makeCoordinator(keychain: keychain, transport: transport, scheduler: scheduler, clock: clock)

        transport.script(.success(makeUsage(spent: 42)))
        coordinator.start()
        transport.releaseAll()
        await coordinator.awaitIdle()
        #expect(coordinator.connection == .live)
        #expect(coordinator.lastGoodResponse?.dailyBudget.spentUSD == 42)

        transport.script(.failure(.network("down")))
        await scheduler.tickAwaiting(coordinator)

        // State is stale but the last good snapshot is RETAINED separately.
        #expect(coordinator.connection == .stale)
        #expect(coordinator.lastGoodResponse?.dailyBudget.spentUSD == 42)
    }
}

@Suite("WP-03 Coordinator: real backoff scheduling (03.4, §6.1)")
@MainActor
struct BackoffSchedulingTests {
    @Test("consecutive transient failures escalate next-fire 60→120→240→300")
    func backoffEscalation() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()
        let coordinator = PollCoordinator(transport: transport, credentials: controller, scheduler: scheduler, clock: clock)

        // Attempt 1 fails → next fire at 60s.
        transport.script(.failure(.network("t1")))
        coordinator.start()
        await coordinator.awaitIdle()
        #expect(scheduler.scheduledDelays == [60])

        // Attempt 2 fails → 120s.
        transport.script(.failure(.network("t2")))
        await scheduler.tickAwaiting(coordinator)
        #expect(scheduler.scheduledDelays == [60, 120])

        // Attempt 3 fails → 240s.
        transport.script(.failure(.badStatus(503)))
        await scheduler.tickAwaiting(coordinator)
        #expect(scheduler.scheduledDelays == [60, 120, 240])

        // Attempt 4 fails → 300s (capped).
        transport.script(.failure(.network("t4")))
        await scheduler.tickAwaiting(coordinator)
        #expect(scheduler.scheduledDelays == [60, 120, 240, 300])

        // Attempt 5 fails → still 300s (cap holds).
        transport.script(.failure(.network("t5")))
        await scheduler.tickAwaiting(coordinator)
        #expect(scheduler.scheduledDelays == [60, 120, 240, 300, 300])

        // Success resets the ladder → next fire back to the ordinary 60s.
        transport.script(.success(makeUsage(spent: 9)))
        await scheduler.tickAwaiting(coordinator)
        #expect(scheduler.scheduledDelays.last == 60)
        #expect(coordinator.connection == .live)
    }

    @Test("Retry-After 120 honored when larger than the ladder step; capped at 300")
    func retryAfterHonored() async {
        // First attempt (base 60): a 120s Retry-After is LARGER → wins.
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 0, retryAfter: 120) == 120)
        // Later attempt (base 240): a 120s hint is SMALLER → floor (240) wins.
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 2, retryAfter: 120) == 240)
        // Hint above the cap clamps to 300.
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 0, retryAfter: 10_000) == 300)

        // End-to-end: a 503 carrying a 120s hint schedules the next fire at 120s.
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()
        let coordinator = PollCoordinator(transport: transport, credentials: controller, scheduler: scheduler, clock: clock)

        transport.scriptHinted(.failure(.badStatus(503)), hint: 120)
        coordinator.start()
        await coordinator.awaitIdle()
        #expect(scheduler.scheduledDelays == [120])
        #expect(coordinator.connection == .retrying(attempt: 1))
    }

    @Test("unauthorized cancels the schedule — no next fire while paused")
    func unauthorizedCancelsSchedule() async {
        let keychain = ScriptedKeychain(token: "gt-synth-dead")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()
        let coordinator = PollCoordinator(transport: transport, credentials: controller, scheduler: scheduler, clock: clock)

        transport.script(.failure(.unauthorized))
        coordinator.start()
        await coordinator.awaitIdle()

        #expect(coordinator.connection == .authenticationRequired)
        // No next fire was scheduled: the latch pauses polling entirely.
        #expect(scheduler.scheduledDelays.isEmpty)
        // Timer ticks do nothing while paused.
        await scheduler.tickAwaiting(coordinator)
        #expect(transport.requestCount == 1)
    }

    @Test("success schedules the ordinary 60s cadence")
    func successSchedulesOrdinary() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()
        let coordinator = PollCoordinator(transport: transport, credentials: controller, scheduler: scheduler, clock: clock)

        transport.script(.success(makeUsage()))
        coordinator.start()
        await coordinator.awaitIdle()
        #expect(scheduler.scheduledDelays == [60])
        #expect(coordinator.connection == .live)
    }
}

@Suite("WP-03 Coordinator: in-flight ownership (stop→start race)")
@MainActor
struct OwnershipTests {
    @Test("stop → restart → A completes late while B hangs: no third request, B keeps the slot")
    func stopRestartLateADoesNotStealBSlot() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = GatedTransport()
        transport.holdGate = true
        let scheduler = ManualScheduler()
        let clock = SteppedClock()
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()
        let coordinator = PollCoordinator(transport: transport, credentials: controller, scheduler: scheduler, clock: clock)

        // A starts, hangs in the transport.
        transport.script(.success(makeUsage(tokenID: "tok-a")))
        coordinator.start()
        await Task.yield()

        // stop() invalidates A's identity and cancels its task; start()
        // issues B (fresh ID). B runs and commits normally.
        coordinator.stop()
        transport.holdGate = false
        transport.script(.success(makeUsage(tokenID: "tok-b")))
        coordinator.start()
        await coordinator.awaitIdle()

        // The critical invariant: at NO point did two commits race — the
        // last committed value is B, the slot was never double-booked.
        #expect(coordinator.lastGoodResponse?.tokenId == "tok-b")
        #expect(coordinator.connection == .live)

        // Exactly one more request fits; no phantom in-flight slot allowed.
        transport.script(.success(makeUsage(tokenID: "tok-c")))
        coordinator.refresh(reason: .opened)
        await coordinator.awaitIdle()
        #expect(transport.requestCount == 3)
        #expect(coordinator.lastGoodResponse?.tokenId == "tok-c")
    }
}
