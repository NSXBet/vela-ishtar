// Sources/VelaCore/AIHubClientProtocol.swift
// The v2 transport seam and error taxonomy for usage fetches, plus the
// v1 completion-based client protocol the legacy UsagePoller still depends
// on during the WP-06 conversion window.
// Why: PollCoordinator and CredentialController live behind these seams, so
// tests stub fetchUsage without a socket. UsageTransport/RefreshReason moved
// here in WP-03 (producer ownership, identical names/cases/semantics to the
// frozen §7.2 declarations in UsageContracts.swift).
// RELEVANT FILES: Sources/App/AIHubClient.swift, Sources/App/PollCoordinator.swift,
// Sources/App/CredentialController.swift, Sources/VelaCore/PollStateMachine.swift

import Foundation

// MARK: - UsageError

/// Everything that can go wrong fetching usage, mapped to a small closed set
/// so callers can classify failures without inspecting raw HTTP/URLError
/// detail. The classification drives recovery policy (§6.2): `unauthorized`
/// pauses polling until explicit user action; `network`/`badStatus(5xx)`
/// back off; `decode` is a schema failure; `noToken`/`keychainBlocked` are
/// credential states, not network states.
public enum UsageError: Error, Equatable, Sendable {
    case noToken
    /// The Keychain itself failed before a request could even be built
    /// (denied, locked, ACL mismatch). Distinct from `noToken` (nothing
    /// stored) — B06: errors must not masquerade as first-run absence.
    case keychainBlocked(OSStatus)
    case unauthorized
    case network(String)
    case badStatus(Int)
    case decode
}

// MARK: - UsageTransport (moved from UsageContracts.swift)

/// The async transport seam every usage fetch goes through.
///
/// §7.2 suggested shape. The live client implements this over URLSession;
/// tests inject a fake. Token parameters remain in memory only — no
/// conforming type may log, persist, or embed the token.
public protocol UsageTransport: Sendable {
    func fetchUsage(token: String) async throws -> UsageResponse
}

// MARK: - RefreshReason (moved from UsageContracts.swift)

/// Why a refresh was requested; drives backoff and scheduling policy.
///
/// §7.2: `launch, scheduled, opened, manual, wake, credentialChanged`.
public enum RefreshReason: Sendable, Equatable {
    case launch
    case scheduled
    case opened
    case manual
    case wake
    case credentialChanged
}

// MARK: - AIHubClientProtocol (legacy v1 completion seam)

/// The v1 poller depends on this protocol, not the concrete client, so
/// tests can stub fetchUsage without making a real request. Kept until
/// WP-06 moves the app layer onto PollCoordinator/UsageTransport.
public protocol AIHubClientProtocol {
    func fetchUsage(completion: @escaping (Result<UsageResponse, UsageError>) -> Void)
}
