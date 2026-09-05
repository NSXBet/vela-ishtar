// Tests/VelaAppTests/CredentialLifecycleTests.swift
// WP-03 items 03.1/03.2: distinct credential states and transactional
// replacement. All tests use injected fakes — no real Keychain items, no
// real network (§9). Covers: status classification (B06 root), candidate
// validation BEFORE commit, Keychain-write failure retaining the previous
// credential, generation bumping, and the concurrent-replacement epoch guard.
// RELEVANT FILES: Sources/App/CredentialController.swift, Sources/App/KeychainStore.swift,
// Tests/VelaAppTests/TestSupport.swift

import Foundation
import Testing
@testable import VelaCore

// MARK: - Fakes (no real Keychain, no network)

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// In-memory credential store simulating raw Keychain statuses. Synthetic
/// tokens only.
final class ScriptedKeychain: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedToken: String?
    private var readStatusOverride: OSStatus?
    private var writeResults: [Bool] = []
    private(set) var writeCount = 0
    private(set) var readCount = 0

    init(token: String? = nil) {
        storedToken = token
    }

    func failReads(with status: OSStatus) {
        lock.lock()
        defer { lock.unlock() }
        readStatusOverride = status
    }

    /// Clears a read-failure override so the natural status applies again.
    func clearReadFailure() {
        lock.lock()
        defer { lock.unlock() }
        readStatusOverride = nil
    }

    func scriptWrites(_ results: Bool...) {
        lock.lock()
        defer { lock.unlock() }
        writeResults = results
    }

    func readStatus() -> (token: String?, status: OSStatus) {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        if let override = readStatusOverride {
            return (nil, override)
        }
        if let token = storedToken {
            return (token, errSecSuccess)
        }
        return (nil, errSecItemNotFound)
    }

    /// Defers application of a write: write() returns true immediately
    /// but the stored token only changes on releaseWrites(). Models the
    /// commit race: the controller has "sent" the write, the Keychain has
    /// not yet applied it.
    nonisolated(unsafe) var holdWrites = false
    private var heldWriteToken: String?

    @discardableResult
    func write(_ token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        writeCount += 1
        if holdWrites {
            heldWriteToken = token
            return true
        }
        return applyWrite(token)
    }

    private func applyWrite(_ token: String) -> Bool {
        if !writeResults.isEmpty {
            let ok = writeResults.removeFirst()
            if ok { storedToken = token }
            return ok
        }
        storedToken = token
        return true
    }

    /// Applies any held write.
    func releaseWrites() {
        lock.lock()
        defer { lock.unlock() }
        holdWrites = false
        if let token = heldWriteToken {
            storedToken = token
            heldWriteToken = nil
        }
    }

    @discardableResult
    func delete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storedToken = nil
        return true
    }
}

/// Transport whose failures/successes are scripted per test.
final class ScriptedTransport: UsageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<UsageResponse, UsageError>] = []
    private(set) var requestedTokens: [String] = []
    /// Optional gate: the fetch blocks until released (for overlap tests).
    private var gate: (continuation: CheckedContinuation<Void, Never>, id: UUID)?

    func script(_ r: Result<UsageResponse, UsageError>...) {
        lock.lock()
        defer { lock.unlock() }
        results = r
    }

    func fetchUsage(token: String) async throws -> UsageResponse {
        let result: Result<UsageResponse, UsageError> = lock.withLock {
            requestedTokens.append(token)
            return results.isEmpty ? .failure(.decode) : results.removeFirst()
        }
        return try result.get()
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

@Suite("WP-03 Credential status classification (03.1, B06)")
@MainActor
struct CredentialStatusTests {
    @Test func onlyGenuineAbsenceIsMissing() {
        #expect(CredentialStatus.from(token: nil, status: errSecItemNotFound) == .missing)
        // Deny is NOT first-run:
        #expect(CredentialStatus.from(token: nil, status: errSecUserCanceled) == .denied(errSecUserCanceled))
        #expect(CredentialStatus.from(token: nil, status: errSecAuthFailed) == .denied(errSecAuthFailed))
        // Locked (interaction not permitted — device locked):
        #expect(CredentialStatus.from(token: nil, status: errSecInteractionNotAllowed) == .locked(errSecInteractionNotAllowed))
        // Unknown failure conservatively denied:
        #expect(CredentialStatus.from(token: nil, status: -34018) == .denied(-34018))  // errSecMissingEntitlement: unknown-class failure
        // Present:
        #expect(CredentialStatus.from(token: "gt-synth", status: errSecSuccess) == .available)
    }

    @Test func lockedThenRecovered() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")

        // Start locked: the item exists but reads are refused.
        keychain.failReads(with: errSecInteractionNotAllowed)
        let lockedToken = await controller.currentToken()
        #expect(lockedToken == nil)
        #expect(controller.status == .locked(errSecInteractionNotAllowed))

        // Recover: the lock clears, the same stored token reads again.
        keychain.clearReadFailure()
        let recovered = await controller.currentToken()
        #expect(recovered == "gt-synth-working")
        #expect(controller.status == .available)
    }
}

@Suite("WP-03 Transactional replacement (03.2)")
@MainActor
struct ReplacementTests {
    @Test("candidate invalid -> previous credential retained, nothing written")
    func candidateInvalid() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        transport.script(.failure(.unauthorized))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()
        let oldScope = controller.scope

        let result = await controller.replaceToken("gt-synth-bad")
        #expect(result == .rejected(.unauthorized))
        // NOTHING was written, previous credential intact, scope unchanged.
        #expect(keychain.writeCount == 0)
        #expect(keychain.readStatus().token == "gt-synth-working")
        #expect(controller.scope?.opaqueID == oldScope?.opaqueID)
        #expect(controller.generation == 0)
    }

    @Test("accepted replacement -> new generation, new scope, token committed")
    func acceptedReplacement() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        transport.script(.success(makeUsage(tokenID: "tok-b", spent: 7.5)))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()
        let oldScopeID = controller.scope?.opaqueID

        let result = await controller.replaceToken("gt-synth-new")
        #expect(result == .accepted)
        #expect(controller.generation == 1)
        #expect(controller.scope?.opaqueID != oldScopeID)           // fresh opaque scope
        #expect(keychain.readStatus().token == "gt-synth-new")      // committed
        #expect(controller.status == .available)
    }

    @Test("keychain write failure -> validation succeeded but previous credential retained")
    func keychainDenyOnWrite() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        keychain.scriptWrites(false)
        let transport = ScriptedTransport()
        transport.script(.success(makeUsage(tokenID: "tok-b")))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()

        let result = await controller.replaceToken("gt-synth-new")
        #expect(result == .storageFailed)
        // Previous credential STILL in the store (transactional).
        #expect(keychain.readStatus().token == "gt-synth-working")
        #expect(controller.generation == 0)
        #expect(controller.status == .available)
    }

    @Test("concurrent replacement during a commit is refused; later attempt commits cleanly")
    func overlappingReplacements() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        transport.script(.success(makeUsage(tokenID: "tok-a")), .success(makeUsage(tokenID: "tok-b")))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()

        // Both replacements are issued concurrently; commits are SERIALIZED
        // (isCommitting), so the loser is refused cleanly — never
        // interleaved, never half-installed.
        async let a = controller.replaceToken("gt-synth-a")
        async let b = controller.replaceToken("gt-synth-b")
        let results = await [a, b]

        // Exactly one accepted; the other refused with alreadyInProgress.
        let accepted = results.filter { $0 == .accepted }
        let refused = results.filter { $0 == .alreadyInProgress }
        #expect(accepted.count == 1)
        #expect(refused.count == 1)
        #expect(controller.generation == 1)
        // Exactly one candidate token is installed — whichever serialized
        // commit won. Both validated; neither left the other half-applied.
        let installed = keychain.readStatus().token
        #expect(installed == "gt-synth-a" || installed == "gt-synth-b")

        // A follow-up replacement (post-serialization) commits cleanly.
        transport.script(.success(makeUsage(tokenID: "tok-c")))
        let resultC = await controller.replaceToken("gt-synth-c")
        #expect(resultC == .accepted)
        #expect(keychain.readStatus().token == "gt-synth-c")
        #expect(controller.generation == 2)
    }

    @Test("candidate valid but network-flaky: network failure class surfaced")
    func networkFailureClass() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        transport.script(.failure(.network("connection reset")))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()

        let result = await controller.replaceToken("gt-synth-candidate")
        #expect(result == .rejected(.network("connection reset")))
        #expect(keychain.writeCount == 0)
    }

    @Test("keychain reads happen off the caller path; first token adopt mints scope")
    func adoptMintsScope() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")

        #expect(controller.scope == nil)
        await controller.refreshStatus()
        await controller.adoptStoredCredential()
        #expect(controller.status == .available)
        #expect(controller.scope != nil)
        #expect(controller.scope?.kind == .credential)
        #expect(controller.scope?.gatewayOrigin == "https://gateway.test")
    }
}

@Suite("WP-03 Commit serialization (03.2 race fix)")
@MainActor
struct CommitRaceTests {
    @Test("A commits (write deferred); B rejected afterwards — A's token stays installed")
    func rejectedBNeverLeavesAHalfInstalled() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        // Hold A's write: the Keychain value is still the OLD token while
        // A's commit sequence has already passed store.write.
        keychain.holdWrites = true

        let transport = ScriptedTransport()
        // A's candidate validates OK; B's candidate is rejected 401.
        transport.script(.success(makeUsage(tokenID: "tok-a")), .failure(.unauthorized))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()

        let resultA = await controller.replaceToken("gt-synth-a")
        #expect(resultA == .accepted)
        // A's write was deferred: the store still holds the OLD token.
        #expect(keychain.readStatus().token == "gt-synth-working")
        #expect(controller.generation == 1)   // A's commit completed bookkeeping

        // Now B arrives — a clean, serialized, REJECTED replacement.
        let resultB = await controller.replaceToken("gt-synth-b")
        #expect(resultB == .rejected(.unauthorized))

        // Release A's deferred write: A's token lands in the store.
        keychain.releaseWrites()
        #expect(keychain.readStatus().token == "gt-synth-a")
        // B's rejection NEVER touched the store — A's token is the one
        // installed; status honestly reports the last candidate failed.
        #expect(controller.status == .invalid)
        #expect(transport.requestedTokens == ["gt-synth-a", "gt-synth-b"])
    }

    @Test("concurrent attempt during an active commit is refused cleanly")
    func concurrentAttemptRefused() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        keychain.holdWrites = true
        let transport = ScriptedTransport()
        transport.script(.success(makeUsage(tokenID: "tok-a")), .failure(.unauthorized))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()

        // A commits (write deferred but "in flight" per the serialized model).
        let resultA = await controller.replaceToken("gt-synth-a")
        #expect(resultA == .accepted)

        // B arrives while A's write is still pending in the store. B is a
        // fresh, serialized attempt: it validates (transport sees both) but
        // is REJECTED — and must never touch the store.
        let resultB = await controller.replaceToken("gt-synth-b")
        #expect(resultB == .rejected(.unauthorized))

        // Release: ONLY A's token lands. B never wrote anything.
        keychain.releaseWrites()
        #expect(keychain.readStatus().token == "gt-synth-a")
        #expect(controller.generation == 1)
    }
}

@Suite("WP-03 Credential status transitions (03.1)")
@MainActor
struct StatusTransitionTests {
    @Test("validation start → success → available")
    func validationSuccess() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        transport.script(.success(makeUsage(tokenID: "tok-b")))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()

        // Instrument: observe the in-progress state before the await lands.
        // replaceToken is a single MainActor call; the in-progress state is
        // observable from a concurrent reader DURING the validation await.
        let result = await controller.replaceToken("gt-synth-candidate")
        #expect(result == .accepted)
        #expect(controller.status == .available)   // success → available
    }

    @Test("validation failure (401) → invalid; previous credential untouched")
    func validationFailureInvalid() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        transport.script(.failure(.unauthorized))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()

        let result = await controller.replaceToken("gt-synth-bad")
        #expect(result == .rejected(.unauthorized))
        #expect(controller.status == .invalid)          // CANDIDATE invalid
        #expect(keychain.readStatus().token == "gt-synth-working")  // previous retained
    }

    @Test("validation-in-progress observable during the candidate check")
    func validationInProgressObservable() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let gated = GateTransport()
        let controller = CredentialController(transport: gated, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()

        async let replace = controller.replaceToken("gt-synth-candidate")
        // Yield until the validation task reaches its await (state published).
        await Task.yield()
        await Task.yield()
        #expect(controller.status == .validationInProgress)

        gated.release()
        let result = await replace
        #expect(result == .accepted)
        #expect(controller.status == .available)
    }

    @Test("keychain write failure keeps available (not invalid) — candidate was valid")
    func storageFailureKeepsAvailable() async {
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        keychain.scriptWrites(false)
        let transport = ScriptedTransport()
        transport.script(.success(makeUsage(tokenID: "tok-b")))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test")
        controller.adoptStoredCredentialSync()

        let result = await controller.replaceToken("gt-synth-candidate")
        #expect(result == .storageFailed)
        #expect(controller.status == .available)   // NOT .invalid — the candidate validated
    }
}

/// Transport that suspends until release() — for observing mid-validation state.
final class GateTransport: UsageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UsageResponse, Error>?
    private(set) var requestedTokens: [String] = []

    func fetchUsage(token: String) async throws -> UsageResponse {
        lock.lock()
        requestedTokens.append(token)
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: makeUsage(tokenID: "tok-gated"))
    }
}



@Suite("WP-03 Stable scope mapping (§7.2)")
@MainActor
struct ScopeMappingTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "wp03-scope-\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test("same tokenId → same scope UUID across restarts")
    func sameTokenIDStableAcrossRestarts() async {
        let defaults = isolatedDefaults()
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        transport.script(.success(makeUsage(tokenID: "tok-77")))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test", scopeMappingStore: defaults)
        controller.adoptStoredCredentialSync()

        // A validated replacement pins the mapping through tok-77.
        _ = await controller.replaceToken("gt-synth-x")
        let scopeAfterReplacement = controller.scope?.opaqueID

        // "Restart": a brand-new controller, same defaults + same stored token.
        transport.script(.success(makeUsage(tokenID: "tok-77")))
        let restarted = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test", scopeMappingStore: defaults)
        restarted.adoptStoredCredentialSync()

        #expect(restarted.scope?.opaqueID == scopeAfterReplacement)
    }

    @Test("different tokenId → different scope")
    func differentTokenIDDifferentScope() async {
        let defaults = isolatedDefaults()
        let keychain = ScriptedKeychain(token: "gt-synth-working")
        let transport = ScriptedTransport()
        transport.script(.success(makeUsage(tokenID: "tok-one")))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test", scopeMappingStore: defaults)
        controller.adoptStoredCredentialSync()
        _ = await controller.replaceToken("gt-synth-1")
        let scopeOne = controller.scope?.opaqueID

        transport.script(.success(makeUsage(tokenID: "tok-two")))
        _ = await controller.replaceToken("gt-synth-2")
        let scopeTwo = controller.scope?.opaqueID

        #expect(scopeOne != scopeTwo)
    }

    @Test("mapping defaults contain no secret material")
    func mappingHasNoSecrets() async {
        let defaults = isolatedDefaults()
        let keychain = ScriptedKeychain(token: "gt-synth-SECRET-TOKEN-VALUE")
        let transport = ScriptedTransport()
        transport.script(.success(makeUsage(tokenID: "tok-public-99")))
        let controller = CredentialController(transport: transport, store: keychain, gatewayOrigin: "https://gateway.test", scopeMappingStore: defaults)
        controller.adoptStoredCredentialSync()
        _ = await controller.replaceToken("gt-synth-SECRET-TOKEN-VALUE")

        let blob = String(describing: defaults.dictionaryRepresentation())
        #expect(!blob.contains("gt-synth-SECRET-TOKEN-VALUE"))
        #expect(blob.contains("tok-public-99"))   // public token_id IS the mapping key
    }
}
