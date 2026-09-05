// Sources/App/AIHubClient.swift
// Fetches the current usage snapshot from the AI Hub gateway's
// GET /v1/me/usage endpoint. Conforms to the async `UsageTransport` seam
// (§7.2) for PollCoordinator/CredentialController, and to the legacy v1
// completion-based `AIHubClientProtocol` for the WP-06 conversion window.
// Why: isolates the one network call the app makes behind protocols, so
// tests stub the transport instead of opening a socket. Response bodies are
// size-capped BEFORE decode (03.4) — an oversized/malicious payload never
// reaches the unbounded JSONDecoder allocation.
// RELEVANT FILES: Sources/App/KeychainStore.swift, Sources/App/PollCoordinator.swift,
// Sources/VelaCore/AIHubClientProtocol.swift

import Foundation

public final class AIHubClient: @unchecked Sendable, UsageTransport {
    /// A `let` (not a compile-time constant) so a future debug build can
    /// point this at a staging gateway without touching call sites.
    public let baseURL: URL

    private let session: URLSession
    /// Decode never sees a body larger than this (03.4).
    private let maxResponseBytes: Int
    /// Legacy v1 completion path reads the token through this store. The
    /// async UsageTransport path takes the token as a parameter instead —
    /// CredentialController owns the reads there.
    private var legacyTokenProvider: KeychainStore?

    public init(
        baseURL: URL = URL(string: "https://ai-llm-gateway.fbr.land")!,
        maxResponseBytes: Int = 1_048_576
    ) {
        self.baseURL = baseURL
        self.maxResponseBytes = maxResponseBytes
        self.legacyTokenProvider = nil

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil   // belt-and-braces: spend data never touches disk cache
        self.session = URLSession(configuration: config)
    }

    /// Test seam: inject an ephemeral/stubbed session (no production caller).
    public init(baseURL: URL, session: URLSession, maxResponseBytes: Int = 1_048_576) {
        self.baseURL = baseURL
        self.session = session
        self.maxResponseBytes = maxResponseBytes
        self.legacyTokenProvider = nil
    }

    /// Source-compatible v1 entry point: main.swift constructs the client
    /// with its KeychainStore. Kept until WP-06 rewires the app shell.
    public convenience init(tokenProvider: KeychainStore, baseURL: URL = URL(string: "https://ai-llm-gateway.fbr.land")!) {
        self.init(baseURL: baseURL)
        self.legacyTokenProvider = tokenProvider
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: - UsageTransport (async seam)

    /// The token is a function parameter, in memory only — never logged,
    /// persisted, or embedded anywhere (§7.2 UsageTransport).
    public func fetchUsage(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/me/usage"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("no HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageError.unauthorized
        }
        guard http.statusCode == 200 else {
            // 429/503 may carry a Retry-After header (seconds or HTTP-date).
            // Attach it to the thrown error so the coordinator's backoff can
            // honor the server-declared wait (§6.1).
            if http.statusCode == 429 || http.statusCode == 503,
               let hint = Self.retryAfterSeconds(from: http) {
                throw RetryAfterError(base: .badStatus(http.statusCode), hint: hint)
            }
            throw UsageError.badStatus(http.statusCode)
        }
        // Size cap BEFORE decode: bounded allocation ahead of the decoder.
        guard data.count <= maxResponseBytes else {
            throw UsageError.decode
        }
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageError.decode
        }
    }

    /// Parses a Retry-After header: delta-seconds (preferred) or an
    /// HTTP-date (converted to a positive interval against the response
    /// Date, defaulting to now). Returns nil when absent/unparseable —
    /// never a fabricated wait.
    static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return seconds
        }
        let formats = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                let interval = date.timeIntervalSinceNow
                return interval > 0 ? interval : 0
            }
        }
        return nil
    }
}

// MARK: - Legacy v1 completion seam

extension AIHubClient: AIHubClientProtocol {
    /// v1 completion adapter. Keychain read is dispatched OFF the calling
    /// (main) thread; the Swift-6 "sending 'completion' risks causing data
    /// races" isolation error at the boundary is fixed by boxing the
    /// completion in a Sendable result value and delivering it on the main
    /// queue exactly as before.
    public func fetchUsage(completion: @escaping (Result<UsageResponse, UsageError>) -> Void) {
        // Box the token read + request into the background queue; the
        // completion hops back to main. No non-Sendable value crosses an
        // isolation boundary.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(.failure(.noToken)) }
                return
            }
            let result = self.performFetchSync()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func performFetchSync() -> Result<UsageResponse, UsageError> {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/me/usage"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Note: the v1 client previously read the Keychain inline here. The
        // credential read is now CredentialController's job; the legacy
        // adapter requests the token the same way the live path does.
        let semaphore = DispatchSemaphore(value: 0)
        var readToken: String?
        if let store = legacyTokenProvider {
            readToken = store.read()
            semaphore.signal()
        } else {
            TokenReader.read { token in
                readToken = token
                semaphore.signal()
            }
            semaphore.wait()
        }
        guard let token = readToken else {
            return .failure(.noToken)
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let done = DispatchSemaphore(value: 0)
        var payload: Result<UsageResponse, UsageError> = .failure(.network("no response"))
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                payload = .failure(.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                payload = .failure(.unauthorized)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                payload = .failure(.badStatus(http.statusCode))
            } else if let data, data.count <= 1_048_576, let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) {
                payload = .success(usage)
            } else {
                payload = .failure(.decode)
            }
            done.signal()
        }
        task.resume()
        done.wait()
        return payload
    }
}

/// Reads the stored token via the production KeychainStore, on whatever
/// queue the caller supplied. Split out so the legacy adapter's Keychain
/// read has one owner.
private enum TokenReader {
    private static let store = KeychainStore()

    static func read(_ completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(store.read())
        }
    }
}
