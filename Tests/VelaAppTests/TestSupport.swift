// Tests/VelaAppTests/TestSupport.swift
// WP-00 item 00.3: the app-integration test harness. Gives test code an
// injected clock, a fake UsageTransport, a fake credential store, an
// isolated UserDefaults domain, and a temporary directory — the five seams
// later work packages (WP-01/02/03/04) drive the app's domain code through
// without AppKit windows, real networking, Keychain, or the user's defaults.
// Also includes a smoke suite proving the harness compiles and the fake
// transport round-trips a checked-in fixture from Tests/Fixtures/usage/.
// RELEVANT FILES: Sources/VelaCore/UsageContracts.swift, Tests/Fixtures/usage/*.json,
// Tests/VelaCoreTests/ModelsTests.swift

import Foundation
import Testing

@testable import VelaCore

// MARK: - ClosureClock

/// Injectable clock: every `now` read goes through the closure, so tests
/// control time exactly (freeze, step, jump across midnight) without
/// sleeping.
public final class ClosureClock: Sendable {
    private let lock = NSLock()
    private let reader: @Sendable () -> Date

    /// Build from any date-producing closure. Not thread-mutable; freeze
    /// with `ClosureClock(at:)`, or wrap your own mutable storage in the
    /// closure if stepping is needed.
    public init(reader: @escaping @Sendable () -> Date) {
        self.reader = reader
    }

    /// A clock frozen at one instant — the most common test case.
    public convenience init(at date: Date) {
        self.init(reader: { date })
    }

    /// The current time. Named `now` so call sites read like the domain
    /// concept they replace (`Date.now`).
    public var now: Date { reader() }
}

// MARK: - FakeUsageTransport

/// In-memory UsageTransport. Scripts a queue of results (success or error)
/// and records every requested token so tests can assert on what was sent.
/// Tokens are synthetic strings in tests — never real credentials.
public final class FakeUsageTransport: UsageTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<UsageResponse, TransportFailure>] = []
    private(set) var requestedTokens: [String] = []

    /// The failure set the transport can throw, mirroring the error space
    /// the live client maps onto (network, HTTP status, decode, auth).
    public enum TransportFailure: Error, Equatable {
        case unauthorized
        case network(String)
        case badStatus(Int)
        case decode
    }

    public init() {}

    /// Queue the next results in order. An empty queue throws `.decode`
    /// (a safe conservative failure) rather than crashing.
    public func enqueue(_ results: Result<UsageResponse, TransportFailure>...) {
        lock.lock()
        defer { lock.unlock() }
        queue.append(contentsOf: results)
    }

    public func fetchUsage(token: String) async throws -> UsageResponse {
        lock.lock()
        defer { lock.unlock() }
        requestedTokens.append(token)
        guard !queue.isEmpty else { throw TransportFailure.decode }
        return try queue.removeFirst().get()
    }

    /// True when exactly `tokens` were requested, in order.
    public func didRequestTokens(_ tokens: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestedTokens == tokens
    }
}

// MARK: - CredentialStore

/// The credential seam the app reads its token through. Lives in the app
/// module (not VelaCore) so the concrete Keychain-backed implementation
/// stays an app concern while tests inject fakes.
public protocol CredentialStore: Sendable {
    func read() -> String?
}

/// A fake credential store with a settable token (nil = no credential).
public final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func setToken(_ newToken: String?) {
        lock.lock()
        defer { lock.unlock() }
        token = newToken
    }
}

// MARK: - IsolatedDefaults

/// UserDefaults isolated from the user's real defaults: a suite with a
/// unique name backed by a temp plist, removed on deinit. Tests must never
/// read or write `UserDefaults.standard` — the pill-size registration-domain
/// trick in the snapshot tool is the one sanctioned exception, and only
/// there because the domain is volatile.
public final class IsolatedDefaults {
    public let defaults: UserDefaults
    private let suiteName: String

    public init() {
        suiteName = "vela.tests.isolated.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

// MARK: - TemporaryDirectory

/// A unique temporary directory, removed on deinit. HistoryStore tests and
/// any future file-backed WP-02 work build on this.
public final class TemporaryDirectory {
    public let url: URL

    public init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Fixture loading

/// Loads a JSON fixture from Tests/Fixtures/usage/ (bundled into the test
/// target by Package.swift as a resource, landing at `usage/<name>.json`
/// inside the bundle) and decodes it as a UsageResponse.
public enum UsageFixture {
    public static func load(_ name: String) throws -> UsageResponse {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "usage") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }
}
/// Proves the harness itself compiles and the fake transport round-trips a
/// real fixture. Not a feature test — a canary for the test target's setup.
@Suite("WP-00 TestSupport harness")
struct TestSupportTests {
    @Test("fake transport round-trips a fixture")
    func transportRoundTrip() async throws {
        let usage = try UsageFixture.load("usage_valid")
        let transport = FakeUsageTransport()
        transport.enqueue(.success(usage))

        let received = try await transport.fetchUsage(token: "synthetic-test-token")

        #expect(received == usage)
        #expect(transport.didRequestTokens(["synthetic-test-token"]))
    }

    @Test("fake transport surfaces scripted failures")
    func transportFailure() async throws {
        let transport = FakeUsageTransport()
        transport.enqueue(.failure(.unauthorized))

        await #expect(throws: FakeUsageTransport.TransportFailure.unauthorized) {
            try await transport.fetchUsage(token: "synthetic-test-token")
        }
    }

    @Test("closure clock is injectable")
    func clockInjectable() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ClosureClock(at: instant)
        #expect(clock.now == instant)
    }

    @Test("isolated defaults and temp directory are self-contained")
    func isolatedStores() throws {
        let defaults = IsolatedDefaults()
        defaults.defaults.set(42, forKey: "vela.test.key")
        #expect(defaults.defaults.integer(forKey: "vela.test.key") == 42)

        let dir = TemporaryDirectory()
        let file = dir.url.appendingPathComponent("probe.txt")
        try "ok".write(to: file, atomically: true, encoding: .utf8)
        #expect((try String(contentsOf: file, encoding: .utf8)) == "ok")
    }
}
