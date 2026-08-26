import Foundation
import LiteTermCore

public struct HealthProbeResult: Equatable, Sendable {
    public let generation: UInt64
    public let consecutiveSuccesses: Int
    public let healthExpiresAt: Date

    public init(generation: UInt64, consecutiveSuccesses: Int, healthExpiresAt: Date) {
        self.generation = generation
        self.consecutiveSuccesses = consecutiveSuccesses
        self.healthExpiresAt = healthExpiresAt
    }
}

public actor HealthProbe {
    private let budget: RuntimeResourceBudget

    public init(budget: RuntimeResourceBudget = .iPadCandidate) {
        self.budget = budget
    }

    public func verify(
        lease: LoopbackServerLease,
        relativePath: String
    ) async throws -> HealthProbeResult {
        let url = try lease.authenticatedHealthURL(relativePath: relativePath)
        let deadline = Date().addingTimeInterval(TimeInterval(budget.healthWindowSeconds))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(budget.healthWindowSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(budget.healthWindowSeconds)
        let delegate = LoopbackNoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var consecutiveSuccesses = 0
        var lastError: Error = PreviewRuntimeError.healthTimedOut
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue(lease.authenticationHeaderValue, forHTTPHeaderField: "X-LiteTerm-Run")
                request.setValue("1", forHTTPHeaderField: "X-LiteTerm-Health")
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.url?.host == lease.host,
                      httpResponse.url?.port == lease.port,
                      (200...399).contains(httpResponse.statusCode),
                      data.count <= budget.healthResponseByteLimit,
                      Self.redirectRemainsOnLease(httpResponse, lease: lease) else {
                    throw PreviewRuntimeError.unhealthyResponse
                }
                consecutiveSuccesses += 1
                if consecutiveSuccesses == budget.healthSuccessCount {
                    return HealthProbeResult(
                        generation: lease.generation,
                        consecutiveSuccesses: consecutiveSuccesses,
                        healthExpiresAt: Date().addingTimeInterval(
                            TimeInterval(budget.healthWindowSeconds)
                        )
                    )
                }
            } catch {
                lastError = error
                consecutiveSuccesses = 0
                if Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
        }
        throw lastError
    }

    private static func redirectRemainsOnLease(
        _ response: HTTPURLResponse,
        lease: LoopbackServerLease
    ) -> Bool {
        guard (300...399).contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location") else {
            return true
        }
        guard let baseURL = response.url,
              let redirectURL = URL(string: location, relativeTo: baseURL)?.absoluteURL else {
            return false
        }
        return redirectURL.scheme == "http"
            && redirectURL.host == lease.host
            && redirectURL.port == lease.port
    }
}

private final class LoopbackNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
