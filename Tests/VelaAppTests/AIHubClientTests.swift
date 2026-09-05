// Tests/VelaAppTests/AIHubClientTests.swift
// WP-03: the live transport client. Exercises the async UsageTransport
// path (status mapping, size cap before decode, token header) against a
// stubbed URLProtocol — no real network (§9: no network in tests). Also
// proves the Retry-After/backoff arithmetic.
// RELEVANT FILES: Sources/App/AIHubClient.swift, Sources/App/PollCoordinator.swift,
// Tests/VelaAppTests/TestSupport.swift

import Foundation
import Testing
@testable import VelaCore

// MARK: - Stubbed URLProtocol

/// Intercepts URLSession traffic so AIHubClient's real request-building and
/// status-mapping code runs without a socket. Synthetic tokens only.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        lastRequest = nil
    }

    static func record(request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        lastRequest = request
    }

    static func currentLastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequest
    }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        StubURLProtocol.record(request: self.request)
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("WP-03 AIHubClient (stubbed URLProtocol)", .serialized)
struct AIHubClientTests {
    private func stubbedClient(handler: @escaping (URLRequest) -> (Int, Data)) -> AIHubClient {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return AIHubClient(baseURL: URL(string: "https://gateway.test")!, session: session)
    }

    private func validJSON() -> Data {
        """
        {"token_id":"tok-synth","daily_budget":{"spend_date":"2026-09-05","spent_usd":1.25,"limit_usd":400,"remaining_usd":398.75,"used_percent":0.3125,"limit_enabled":true},"current_month":{"period_start":"2026-09-01","period_end":"2026-09-30","total_cost_usd":10,"total_tokens":100,"requests":5},"top_models":[],"today":{"total_cost_usd":1.25,"total_tokens":10,"requests":2},"today_models":[]}
        """.data(using: .utf8)!
    }

    @Test func successMapsPayload() async throws {
        let client = stubbedClient { _ in (200, validJSON()) }

        let usage = try await client.fetchUsage(token: "gt-synthetic-token")
        #expect(usage.tokenId == "tok-synth")
        #expect(usage.dailyBudget.spentUSD == 1.25)
        let sent = StubURLProtocol.currentLastRequest()
        #expect(sent?.url?.host == "gateway.test")
        #expect(sent?.value(forHTTPHeaderField: "Authorization") == "Bearer gt-synthetic-token")
    }

    @Test func unauthorized401and403() async {
        for status in [401, 403] {
            let client = stubbedClient { _ in (status, Data()) }
            defer { URLProtocol.unregisterClass(StubURLProtocol.self) }
            await #expect(throws: UsageError.unauthorized) {
                try await client.fetchUsage(token: "gt-synthetic-token")
            }
        }
    }

    @Test func serverErrorBecomesBadStatus() async {
        let client = stubbedClient { _ in (503, Data()) }
        await #expect(throws: UsageError.badStatus(503)) {
            try await client.fetchUsage(token: "gt-synthetic-token")
        }
    }

    @Test func malformedBodyBecomesDecode() async {
        let client = stubbedClient { _ in (200, Data("not json".utf8)) }
        await #expect(throws: UsageError.decode) {
            try await client.fetchUsage(token: "gt-synthetic-token")
        }
    }

    @Test func oversizedBodyRejectedBeforeDecode() async {
        StubURLProtocol.reset()
        // 2 MiB of padding — beyond the 1 MiB cap. Must be refused BEFORE
        // the decoder ever sees it.
        let big = Data(repeating: 0x20, count: 2 * 1_048_576)
        let client = stubbedClient { _ in (200, big) }
        do {
            _ = try await client.fetchUsage(token: "gt-synthetic-token")
            Issue.record("oversized payload should fail")
        } catch let error as UsageError {
            #expect(error == .decode)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

@Suite("WP-03 Backoff arithmetic")
struct BackoffTests {
    @Test func ladderMatchesSpec() {
        // §6.1: network/5xx retries 60/120/240/300s capped.
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 0, retryAfter: nil) == 60)
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 1, retryAfter: nil) == 120)
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 2, retryAfter: nil) == 240)
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 3, retryAfter: nil) == 300)
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 9, retryAfter: nil) == 300)  // capped
    }

    @Test func retryAfterOnlyShortens() {
        // Server-declared wait WINS when larger than the ladder step
        // (respecting Retry-After, §6.1); capped at 300.
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 0, retryAfter: 120) == 120)  // hint larger -> hint wins
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 2, retryAfter: 90) == 240)   // hint smaller -> floor wins
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 0, retryAfter: 0) == 60)     // zero/absent -> ladder step
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 0, retryAfter: 10_000) == 300) // capped
    }

    @Test func retryAfter120Scenario() {
        // §9 test: "Retry-After 120" — the server's 120s wait is honored:
        // at base 60 it stretches to 120; at base >= 120 the ladder step
        // already covers it.
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 0, retryAfter: 120) == 120)
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 1, retryAfter: 120) == 120)
        #expect(PollCoordinator.effectiveBackoff(scheduleIndex: 3, retryAfter: 120) == 300)  // ladder capped at 300
    }
}
