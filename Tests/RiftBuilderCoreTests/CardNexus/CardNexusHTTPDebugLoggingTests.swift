import Foundation
import XCTest
@testable import RiftBuilderCore

@MainActor
final class CardNexusHTTPDebugLoggingTests: XCTestCase {
    func testDisabledLoggerReceivesNoEvents() async throws {
        let logger = RecordingDebugLogger(isEnabled: false)
        let transport = DebugTransport(response: debugResponse("[]"))
        let client = CardNexusClient(
            baseURL: URL(string: "https://api.example/v1")!,
            transport: transport,
            credentialStore: DebugCredentialStore(),
            retryPolicy: CardNexusRetryPolicy(maximumAttempts: 1),
            debugLogger: logger
        )

        _ = try await client.fetchLocations()

        let events = await logger.recordedEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testEnabledLoggerReceivesRequestAndResponseWithoutHeaders() async throws {
        let logger = RecordingDebugLogger(isEnabled: true)
        let transport = DebugTransport(response: debugResponse(#"{"data":[],"pagination":{"nextCursor":null}}"#))
        let client = CardNexusClient(
            baseURL: URL(string: "https://api.example/v1")!,
            transport: transport,
            credentialStore: DebugCredentialStore(),
            retryPolicy: CardNexusRetryPolicy(maximumAttempts: 1),
            debugLogger: logger
        )

        _ = try await client.fetchAllInventoryLines(game: "riftbound")

        let events = await logger.recordedEvents()
        XCTAssertEqual(events.count, 2)
        guard case let .request(request) = events[0] else { return XCTFail("Expected request event") }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/inventory")
        XCTAssertEqual(request.queryItems, [
            CardNexusHTTPDebugQueryItem(name: "game", value: "riftbound"),
            CardNexusHTTPDebugQueryItem(name: "limit", value: "100"),
        ])
        XCTAssertNil(request.payload)
        guard case let .response(response) = events[1] else { return XCTFail("Expected response event") }
        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.payload.contains(#""pagination""#))
        XCTAssertFalse(String(describing: events).contains("cardnexus-test-credential"))
    }

    func testSanitizerRedactsCredentialsFromQueriesPayloadsAndResponses() throws {
        var request = URLRequest(url: URL(string: "https://api.example/v1/inventory?game=riftbound&access_token=query-secret")!)
        request.httpMethod = "POST"
        request.setValue("Bearer cardnexus-test-credential", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"apiKey":"payload-secret","location":"cardnexus-test-credential"}"#.utf8)

        let requestLog = CardNexusHTTPDebugSanitizer.request(request, id: UUID(), attempt: 1)
        XCTAssertEqual(requestLog.path, "/v1/inventory")
        XCTAssertEqual(requestLog.queryItems.first(where: { $0.name == "game" })?.value, "riftbound")
        XCTAssertEqual(requestLog.queryItems.first(where: { $0.name == "access_token" })?.value, "<redacted>")
        XCTAssertTrue(requestLog.payload?.contains(#""apiKey" : "<redacted>""#) == true)
        XCTAssertFalse(requestLog.payload?.contains("payload-secret") == true)
        XCTAssertFalse(requestLog.payload?.contains("cardnexus-test-credential") == true)

        let responseData = Data(#"{"token":"response-secret","echo":"cardnexus-test-credential"}"#.utf8)
        let responseLog = CardNexusHTTPDebugSanitizer.response(
            data: responseData,
            response: debugResponse("{}", status: 200).1,
            for: request,
            id: requestLog.id,
            attempt: 1
        )
        XCTAssertTrue(responseLog.payload.contains(#""token" : "<redacted>""#))
        XCTAssertFalse(responseLog.payload.contains("response-secret"))
        XCTAssertFalse(responseLog.payload.contains("cardnexus-test-credential"))
    }
}

private actor RecordingDebugLogger: CardNexusHTTPDebugLogging {
    private let enabled: Bool
    private var events: [CardNexusHTTPDebugEvent] = []

    init(isEnabled: Bool) {
        enabled = isEnabled
    }

    func isLoggingEnabled() async -> Bool {
        enabled
    }

    func record(_ event: CardNexusHTTPDebugEvent) async {
        events.append(event)
    }

    func recordedEvents() -> [CardNexusHTTPDebugEvent] {
        events
    }
}

private struct DebugCredentialStore: CredentialStoring {
    func loadAPIKey() throws -> String? { "cardnexus-test-credential" }
    func saveAPIKey(_ key: String) throws {}
    func deleteAPIKey() throws {}
}

private actor DebugTransport: HTTPTransport {
    private let response: (Data, HTTPURLResponse)

    init(response: (Data, HTTPURLResponse)) {
        self.response = response
    }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        response
    }
}

private func debugResponse(_ json: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (
        Data(json.utf8),
        HTTPURLResponse(
            url: URL(string: "https://api.example")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    )
}
