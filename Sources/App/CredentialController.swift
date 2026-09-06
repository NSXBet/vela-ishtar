// Sources/App/CredentialController.swift
// WP-03 item 03.1/03.2: credential lifecycle. Owns the distinct credential
// states (missing, available, denied, locked/unavailable, invalid,
// validation-in-progress), reads the Keychain OFF the interactive path, and
// performs transactional token replacement: a candidate token is validated
// through the same read-only usage endpoint BEFORE the working token is
// replaced, generation-guarded so a late old-generation response can never
// commit.
// Why: B02 (token A history polluted by token B, in-flight response landing
// after replacement) and B06 (Keychain error mistaken for first-run) both
// root-cause here. One owner for every Keychain read/write means the app
// layer never improvises credential policy.
// RELEVANT FILES: Sources/App/KeychainStore.swift, Sources/App/PollCoordinator.swift,
// Sources/VelaCore/UsageContracts.swift, Sources/VelaCore/AIHubClientProtocol.swift

import Foundation
import os

/// Credential lifecycle: what is known about the gateway token right now.
/// `KeychainStore.readStatus()` provides the raw OSStatus; this maps it to
/// safe user-facing facts without treating a Keychain ERROR as "no token"
/// (B06). Only genuine absence (`errSecItemNotFound`) is first-run.
public enum CredentialStatus: Equatable, Sendable {
    /// Nothing stored — the real first-run case.
    case missing
    /// A token is stored and readable.
    case available
    /// The user (or policy) denied the read — errSecUserCanceled,
    /// errSecAuthFailed, errSecInteractionNotAllowed, ACL mismatch.
    case denied(OSStatus)
    /// The item exists but is temporarily unreadable (device locked) or the
    /// Keychain is otherwise unavailable — recoverable without user action.
    case locked(OSStatus)
    /// A replacement candidate is being validated against the gateway
    /// (03.2 validation-in-progress).
    case validationInProgress
    /// The last replacement candidate failed validation — the CANDIDATE is
    /// invalid; the previously-saved credential is untouched.
    case invalid

    /// Map a raw Keychain read status + token presence into a state.
    /// `errSecItemNotFound` → `.missing`; everything else is a failure and
    /// never silently reads as first-run (B06).
    public static func from(token: String?, status: OSStatus) -> CredentialStatus {
        if status == errSecSuccess {
            return token == nil ? .missing : .available
        }
        if status == errSecItemNotFound { return .missing }
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            return .denied(status)
        case errSecInteractionNotAllowed:
            // The item exists but the keychain is locked / interaction not
            // permitted right now — recoverable without user re-entry.
            return .locked(status)
        default:
            // Unknown failure: conservatively "denied" — explain, don't
            // masquerade as absence.
            return .denied(status)
        }
    }
}

/// The credential seam. Production backs it with `KeychainStore`; tests
/// inject a fake (no real Keychain items in the suite — §9 WP-03).
public protocol CredentialStoring: Sendable {
    /// Read the token plus the raw OSStatus so absence and failure stay
    /// distinguishable.
    func readStatus() -> (token: String?, status: OSStatus)
    @discardableResult
    func write(_ token: String) -> Bool
    @discardableResult
    func delete() -> Bool
}

extension KeychainStore: CredentialStoring {}

/// Outcome of a replacement attempt — drives the UI's error line.
public enum CredentialReplacementResult: Equatable, Sendable {
    /// Candidate validated over the wire and committed to the Keychain.
    case accepted
    /// The candidate failed validation at the gateway (401/403/bad status).
    case rejected(CredentialValidationFailure)
    /// The Keychain write failed; the previous token is untouched.
    case storageFailed
    /// A replacement attempt is already running.
    case alreadyInProgress
}

/// Why a candidate token did not validate.
public enum CredentialValidationFailure: Equatable, Sendable {
    case unauthorized
    case badStatus(Int)
    case network(String)
    case decode
}

/// Owns the Keychain-backed credential: current status, opaque scope
/// mapping, and transactional replacement.
///
/// Main-actor. Keychain reads/writes are dispatched to a background queue —
/// never on the interactive path (§6.1: zero synchronous Keychain I/O on
/// the interaction path).
@MainActor
private let mappingLog = Logger(subsystem: "com.nsxbet.velaishtar", category: "CredentialController")

public final class CredentialController {
    /// The last observed credential status (raw status preserved for the UI).
    public private(set) var status: CredentialStatus = .missing
    /// Monotonic generation. Bumped on every accepted replacement; captured
    /// by every fetch so only the current generation's results commit (B02).
    public private(set) var generation: UInt64 = 0
    /// Opaque, non-secret scope identity of the CURRENT credential. A new
    /// UUID per accepted token: the token itself never becomes identity
    /// (§7.2 UsageScope).
    public private(set) var scope: UsageScope?

    /// The transport used to VALIDATE candidate tokens before committing
    /// them. Same read-only endpoint the poller uses — no write API.
    private let transport: any UsageTransport
    private let store: any CredentialStoring
    private let keychainQueue = DispatchQueue(label: "com.nsxbet.velaishtar.keychain", qos: .utility)
    private let gatewayOrigin: String
    /// Stable scope mapping: gateway-returned `token_id` string → locally
    /// minted opaque UUID. §7.2: "isolate by returned token ID through an
    /// opaque mapping" — the mapping must be STABLE so persisted history
    /// keyed to a scope's UUID survives restarts. The SECRET token is never
    /// a key here, never stored in the mapping, never persisted by this
    /// type; only the gateway's public token_id string.
    /// Production: the mapping persists as JSON in the history directory —
    /// NOT UserDefaults: an unbundled debug binary's defaults domain proved
    /// unreliable here (writes silently lost across launches, splitting
    /// history across per-launch scope UUIDs). Tests may instead inject a
    /// UserDefaults suite (scopeMappingDefaults) for isolation. Same public
    /// token_id keys; the secret token never touches either store.
    private let scopeMappingURL: URL?
    private let scopeMappingDefaults: UserDefaults?

    private let scopeMappingLock = NSLock()

    /// Bumps on each replacement attempt so a user who types token B while
    /// token A's validation is still in flight gets only B's verdict.
    private var replacementEpoch = 0
    /// Serializes the commit sequence (epoch-check → store.write → scope
    /// mint). While true, concurrent replacement attempts are refused with
    /// `.alreadyInProgress` BEFORE touching validation or the Keychain —
    /// two commits can never interleave, so a rejected newer candidate can
    /// never leave an older write half-installed.
    private var isCommitting = false

    public init(
        transport: any UsageTransport,
        store: any CredentialStoring,
        gatewayOrigin: String = "https://ai-llm-gateway.fbr.land",
        mappingDirectory: URL? = HistoryStore.defaultDirectory,
        scopeMappingDefaults: UserDefaults? = nil
    ) {
        self.transport = transport
        self.store = store
        self.gatewayOrigin = gatewayOrigin
        if let scopeMappingDefaults {
            self.scopeMappingDefaults = scopeMappingDefaults
            self.scopeMappingURL = nil
        } else {
            self.scopeMappingDefaults = nil
            if let mappingDirectory {
                self.scopeMappingURL = mappingDirectory
                    .appendingPathComponent("scope-mapping.json")
            } else {
                self.scopeMappingURL = nil
            }
        }
        // Initial status comes from the background read; start pessimistic
        // so no caller ever blocks on Keychain I/O.
        self.status = .missing
    }

    private static let scopeMappingFileKey = "scopeMapping"

    private func loadMapping() -> [String: String] {
        if let defaults = scopeMappingDefaults {
            return defaults.dictionary(forKey: Self.scopeMappingKey) as? [String: String] ?? [:]
        }
        guard let url = scopeMappingURL,
              let data = try? Data(contentsOf: url),
              let wrapped = try? JSONDecoder().decode([String: [String: String]].self, from: data),
              let mapping = wrapped[Self.scopeMappingFileKey] else { return [:] }
        return mapping
    }

    private func persistMapping(_ mapping: [String: String]) {
        if let defaults = scopeMappingDefaults {
            defaults.set(mapping, forKey: Self.scopeMappingKey)
            return
        }
        guard let url = scopeMappingURL else { return }
        // The history directory may not exist on first launch (it is
        // created lazily by the first history save) — create it or the
        // mapping write silently fails and history splits per launch.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrapped = [Self.scopeMappingFileKey: mapping]
        if let data = try? JSONEncoder().encode(wrapped) {
            try? data.write(to: url, options: .atomic)
        } else {
            mappingLog.error("scope mapping write failed — history would split per launch")
        }
    }

    // MARK: - Stable scope mapping (§7.2)

    private static let scopeMappingKey = "velaishtar.scope-mapping.v1"

    /// Returns the STABLE opaque UUID for a gateway token_id: the existing
    /// mapped UUID, or a freshly minted one persisted for every later
    /// launch. Keys are the gateway's PUBLIC token_id strings — the secret
    /// token never appears in this mapping or in the defaults domain.
    func opaqueID(forTokenID tokenID: String) -> UUID {
        scopeMappingLock.lock()
        defer { scopeMappingLock.unlock() }
        var mapping = loadMapping()
        if let existing = mapping[tokenID], let uuid = UUID(uuidString: existing) {
            return uuid
        }
        let fresh = UUID()
        mapping[tokenID] = fresh.uuidString
        persistMapping(mapping)
        return fresh
    }

    /// Reads the Keychain OFF the main actor and publishes the mapped
    /// status through `onChange`. Called once at startup, never on the
    /// interactive path (03.1).
    public func refreshStatus() async {
        status = await Self.readStatus(from: store, on: keychainQueue)
    }

    private static func readStatus(from store: any CredentialStoring, on queue: DispatchQueue) async -> CredentialStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                let (token, status) = store.readStatus()
                continuation.resume(returning: CredentialStatus.from(token: token, status: status))
            }
        }
    }

    /// The stored token, read off the main actor. Returns nil when the
    /// Keychain denies/locks — callers see `.status` for the WHY.
    public func currentToken() async -> String? {
        let (token, status) = await withCheckedContinuation { (continuation: CheckedContinuation<(String?, OSStatus), Never>) in
            keychainQueue.async {
                continuation.resume(returning: self.store.readStatus())
            }
        }
        self.status = CredentialStatus.from(token: token, status: status)
        return status == errSecSuccess ? token : nil
    }

    /// Synchronous convenience for tests and the boot path only.
    func currentTokenSync() -> String? {
        let (token, status) = store.readStatus()
        self.status = CredentialStatus.from(token: token, status: status)
        return status == errSecSuccess ? token : nil
    }

    /// Transactional replacement (03.2):
    ///
    /// 1. Validate the candidate through the same read-only usage endpoint
    ///    the poller uses. An invalid candidate NEVER touches the Keychain.
    /// 2. Only after validation succeeds: write to the Keychain. A write
    ///    failure retains the previous credential and reports `storageFailed`.
    /// 3. On commit: bump the generation (older requests' results are then
    ///    stale by epoch and will not commit), mint a fresh opaque scope.
    ///
    /// `epoch` is captured at entry; if another replacement started meanwhile
    /// (user pasted token B while A was validating), this attempt is abandoned.
    public func replaceToken(_ candidate: String) async -> CredentialReplacementResult {
        // Non-overlappable commits: a replacement attempt that arrives
        // while another commit is mid-flight is refused cleanly.
        guard !isCommitting else { return .alreadyInProgress }
        isCommitting = true
        defer { isCommitting = false }

        replacementEpoch += 1
        let epoch = replacementEpoch

        // 1. Validate the candidate against the live gateway. The state
        // publishes validation-in-progress so the UI can show an honest
        // "checking…" instead of a dead panel.
        status = .validationInProgress
        let validation: Result<UsageResponse, UsageError>
        do {
            let response = try await transport.fetchUsage(token: candidate)
            validation = .success(response)
        } catch let error as UsageError {
            validation = .failure(error)
        } catch {
            validation = .failure(.network(error.localizedDescription))
        }
        guard epoch == replacementEpoch else { return .alreadyInProgress }

        switch validation {
        case .failure(let error):
            // Previous credential fully retained: nothing was written. The
            // CANDIDATE is what failed — publish .invalid (03.2).
            status = .invalid
            switch error {
            case .unauthorized:
                return .rejected(.unauthorized)
            case .badStatus(let code):
                return .rejected(.badStatus(code))
            case .network(let detail):
                return .rejected(.network(detail))
            case .decode:
                return .rejected(.decode)
            case .noToken, .keychainBlocked:
                // A validation request cannot hit these (token passed inline);
                // classify defensively as a network-class failure.
                return .rejected(.network("validation transport error"))
            }

        case .success:
            // 2. Commit: Keychain write on the background queue.
            let written: Bool = await withCheckedContinuation { continuation in
                keychainQueue.async {
                    continuation.resume(returning: self.store.write(candidate))
                }
            }
            guard epoch == replacementEpoch else { return .alreadyInProgress }
            guard written else {
                // The candidate validated but the Keychain refused the
                // write — NOT an invalid candidate: restore the available
                // status of the retained previous credential.
                status = .available
                return .storageFailed
            }

            // 3. Accepted replacement: new generation, scope derived from
            // the VALIDATED response's token_id through the stable mapping
            // (§7.2) — the same credential always maps to the same opaque
            // UUID, across replacements and restarts. If the candidate is
            // the SAME credential as before, the scope is REUSED, not
            // replaced.
            let tokenID = (try? validation.get())?.tokenId
            generation &+= 1
            if let tokenID {
                pinValidatedTokenID(tokenID)
                scope = UsageScope(kind: .credential, opaqueID: opaqueID(forTokenID: tokenID), gatewayOrigin: gatewayOrigin)
            } else {
                scope = UsageScope(kind: .credential, opaqueID: UUID(), gatewayOrigin: gatewayOrigin)
            }
            status = .available
            return .accepted
        }
    }

    /// Installs the initially-loaded token's scope at startup (no
    /// validation needed — the stored token is the working credential).
    /// The scope reuses the STABLE mapping entry of the last validated
    /// tokenId, so the same credential yields the same opaque UUID across
    /// restarts and persisted history is never orphaned. A fresh UUID is
    /// minted only for a credential never validated before; the first
    /// validated response then pins its tokenId mapping.
    public func adoptStoredCredential() async {
        guard (await currentToken()) != nil else { return }
        if scope == nil {
            scope = UsageScope(kind: .credential, opaqueID: adoptOpaqueID(), gatewayOrigin: gatewayOrigin)
        }
        status = .available
    }

    /// Test seam: synchronous variant of adoptStoredCredential.
    func adoptStoredCredentialSync() {
        guard currentTokenSync() != nil else { return }
        if scope == nil {
            scope = UsageScope(kind: .credential, opaqueID: adoptOpaqueID(), gatewayOrigin: gatewayOrigin)
        }
        status = .available
    }

    private static let lastValidatedTokenIDKey = "velaishtar.last-validated-token-id"

    /// The mapping UUID for the last validated credential, if known.
    private func adoptOpaqueID() -> UUID {
        if let last = loadMapping()[Self.lastValidatedTokenIDKey] {
            return opaqueID(forTokenID: last)
        }
        // Unknown credential: mint a session UUID; replaceToken's validated
        // response refines it through the stable mapping.
        return UUID()
    }

    private func pinValidatedTokenID(_ tokenID: String) {
        // The token_id itself is the persisted value inside the mapping
        // (opaqueID(forTokenID:) writes it); pinning the LAST VALIDATED id
        // separately lets adopt reuse it before any validation response.
        scopeMappingLock.lock()
        defer { scopeMappingLock.unlock() }
        var mapping = loadMapping()
        mapping[Self.lastValidatedTokenIDKey] = tokenID
        persistMapping(mapping)
    }
}
