// Sources/App/AIHubClient.swift
// Fetches the current usage snapshot from the AI Hub gateway's
// GET /v1/me/usage endpoint and decodes it into a UsageResponse.
// Why: isolates the one network call the app makes behind a protocol, so
// UsagePoller can be unit-tested against a stub instead of a real socket.
// UsageError/AIHubClientProtocol live in VelaCore (see AIHubClientProtocol.swift)
// so PollStateMachine can reference them without depending on this target.
// RELEVANT FILES: Sources/App/KeychainStore.swift, Sources/App/UsagePoller.swift, Sources/VelaCore/AIHubClientProtocol.swift

import Foundation
import VelaCore

/// Live implementation backed by URLSession.
public final class AIHubClient: AIHubClientProtocol {
    /// A `let` (not a compile-time constant) so a future debug build can
    /// point this at a staging gateway without touching call sites.
    public let baseURL: URL

    private let tokenProvider: KeychainStore
    private let session: URLSession

    public init(tokenProvider: KeychainStore, baseURL: URL = URL(string: "https://ai-llm-gateway.fbr.land")!) {
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    public func fetchUsage(completion: @escaping (Result<UsageResponse, UsageError>) -> Void) {
        guard let token = tokenProvider.read() else {
            deliver(.failure(.noToken), completion)
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/me/usage"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                self.deliver(.failure(.network(error.localizedDescription)), completion)
                return
            }

            guard let http = response as? HTTPURLResponse else {
                self.deliver(.failure(.network("no HTTP response")), completion)
                return
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                self.deliver(.failure(.unauthorized), completion)
                return
            }
            guard http.statusCode == 200 else {
                self.deliver(.failure(.badStatus(http.statusCode)), completion)
                return
            }

            guard let data = data, let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
                self.deliver(.failure(.decode), completion)
                return
            }

            self.deliver(.success(usage), completion)
        }.resume()
    }

    private func deliver(_ result: Result<UsageResponse, UsageError>, _ completion: @escaping (Result<UsageResponse, UsageError>) -> Void) {
        DispatchQueue.main.async {
            completion(result)
        }
    }
}
