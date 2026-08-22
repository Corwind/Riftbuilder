import Foundation
import XCTest
@testable import RiftBuilderCore

final class SessionCredentialCardNexusIntegrationTests: XCTestCase {
    func testMultipleCardNexusRequestsPerformOneBackingCredentialLoad() async throws {
        let backing = CountingCredentialStore(key: "session-secret")
        let session = SessionCredentialStore(backingStore: backing)
        let transport = SuccessfulLocationsTransport()
        let client = CardNexusClient(
            baseURL: URL(string: "https://api.example/v1")!,
            transport: transport,
            credentialStore: session,
            retryPolicy: CardNexusRetryPolicy(maximumAttempts: 1),
            sleep: { _ in }
        )

        _ = try await client.fetchLocations()
        _ = try await client.fetchLocations()
        _ = try await client.fetchLocations()

        XCTAssertEqual(backing.loadCount, 1)
        let requestCount = await transport.requestCount()
        let authorizationValues = await transport.authorizationValues()
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(authorizationValues, [
            "Bearer session-secret",
            "Bearer session-secret",
            "Bearer session-secret",
        ])
    }
}

private final class CountingCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var count = 0

    init(key: String?) {
        self.key = key
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func loadAPIKey() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return key
    }

    func saveAPIKey(_ key: String) throws {
        lock.lock()
        self.key = key
        lock.unlock()
    }

    func deleteAPIKey() throws {
        lock.lock()
        key = nil
        lock.unlock()
    }
}

private actor SuccessfulLocationsTransport: HTTPTransport {
    private var authorizations: [String?] = []

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
        return (
            Data("[]".utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
        )
    }

    func requestCount() -> Int { authorizations.count }
    func authorizationValues() -> [String?] { authorizations }
}
