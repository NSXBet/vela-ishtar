// Sources/VelaCore/AIHubClientProtocol.swift
// The closed set of usage-fetch errors, and the protocol UsagePoller depends
// on instead of the concrete network client.
// Why: PollStateMachine.ingest() must switch on the fetch result, and it
// lives in VelaCore (so `swift test` can exercise it without AppKit) --
// so the error type and protocol it's defined against have to live here
// too, not in Sources/App where the live AIHubClient class stays.
// RELEVANT FILES: Sources/App/AIHubClient.swift, Sources/VelaCore/PollStateMachine.swift, Sources/App/UsagePoller.swift

import Foundation

/// Everything that can go wrong fetching usage, mapped to a small closed set
/// so callers can switch on it instead of inspecting raw HTTP/URLError detail.
public enum UsageError: Error, Equatable, Sendable {
    case noToken
    case unauthorized
    case network(String)
    case badStatus(Int)
    case decode
}

/// The poller depends on this protocol, not the concrete client, so tests
/// can stub fetchUsage without making a real request.
public protocol AIHubClientProtocol {
    func fetchUsage(completion: @escaping (Result<UsageResponse, UsageError>) -> Void)
}
