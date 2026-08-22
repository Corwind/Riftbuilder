import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A deliberately small HTTP boundary that lets the CardNexus client run against a
/// scripted transport in tests without installing a global `URLProtocol`.
public protocol HTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CardNexusClientError.invalidResponse
        }
        return (data, httpResponse)
    }
}

public struct CardNexusRetryPolicy: Hashable, Sendable {
    public var maximumAttempts: Int
    public var initialBackoff: Duration
    public var maximumRetryAfter: Duration

    public init(maximumAttempts: Int = 4, initialBackoff: Duration = .milliseconds(250), maximumRetryAfter: Duration = .seconds(60)) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialBackoff = initialBackoff
        self.maximumRetryAfter = maximumRetryAfter
    }

    public static let `default` = CardNexusRetryPolicy()
}

public typealias CardNexusSleep = @Sendable (Duration) async throws -> Void

public enum CardNexusSleeps {
    public static let continuousClock: CardNexusSleep = { duration in
        try await ContinuousClock().sleep(for: duration)
    }
}
