import Foundation
import XCTest
@testable import RiftBuilderCore

@MainActor
final class CardNexusClientTests: XCTestCase {
    func testInventoryTraversesEveryCursorAndPreservesLocations() async throws {
        let transport = ScriptedTransport(responses: [
            response(#"{"data":[{"id":"line-1","customId":"scan-1","productId":101,"finish":"Standard","condition":"NM","language":"en","quantity":3,"graded":null,"location":"Box A","tags":["owned"],"comment":"first","notes":"private","forSale":false,"listing":null,"updatedAt":"2026-08-20T10:11:12.123Z"}],"pagination":{"nextCursor":"cursor two/+"}}"#),
            response(#"{"data":[{"id":"line-2","productId":101,"finish":"Foil","quantity":2,"location":"Deck: Ahri","updatedAt":"2026-08-21T10:11:12Z"}],"pagination":{"nextCursor":null}}"#),
        ])
        let lines = try await makeClient(transport).fetchAllInventoryLines(game: "riftbound")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].inventoryID, "line-1")
        XCTAssertEqual(lines[0].locationName, "Box A")
        XCTAssertEqual(lines[0].tags, ["owned"])
        XCTAssertEqual(lines[0].notes, "private")
        XCTAssertEqual(lines[1].locationName, "Deck: Ahri")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].query["game"], "riftbound")
        XCTAssertEqual(requests[0].query["limit"], "100")
        XCTAssertNil(requests[0].query["cursor"])
        XCTAssertEqual(requests[1].query["cursor"], "cursor two/+")
        XCTAssertEqual(requests[0].authorization, "Bearer test-cardnexus-key")
    }

    func testLocationsAndVerificationUseInventoryReadEndpoint() async throws {
        let payload = ##"[{"name":"Trade Binder","color":"#22c55e","icon":"star"}]"##
        let transport = ScriptedTransport(responses: [response(payload), response(payload)])
        let client = makeClient(transport)
        try await client.verifyCredential()
        let locations = try await client.fetchLocations()
        XCTAssertEqual(locations, [InventoryLocation(name: "Trade Binder", color: "#22c55e", icon: "star")])
        let paths = await transport.recordedRequests().map(\.path)
        XCTAssertEqual(paths, ["/v1/inventory/locations", "/v1/inventory/locations"])
    }

    func testCatalogueMetadataMapsDocumentedResponse() async throws {
        let transport = ScriptedTransport(responses: [response(#"{"feedType":"catalog","url":"https://feeds.example/riftbound/catalog.ndjson.gz","checksum":"sha256:abc","recordCount":42,"encoding":"gzip","generatedAt":"2026-08-21T09:00:00.000Z"}"#)])
        let metadata = try await makeClient(transport).fetchCatalogueMetadata(game: "riftbound")
        XCTAssertEqual(metadata.url.absoluteString, "https://feeds.example/riftbound/catalog.ndjson.gz")
        XCTAssertEqual(metadata.checksum, "sha256:abc")
        XCTAssertEqual(metadata.recordCount, 42)
        let path = await transport.recordedRequests().first?.path
        XCTAssertEqual(path, "/v1/feeds/riftbound/catalog")
    }

    func testAPIErrorHasEnvelopeAndRequestIDWithoutCredential() async {
        let transport = ScriptedTransport(responses: [response(#"{"code":"FORBIDDEN","status":403,"message":"Missing scope","data":{"required":["inventory:read"]}}"#, status: 403, headers: ["X-Request-Id": "req-123"])])
        do {
            _ = try await makeClient(transport).fetchLocations()
            XCTFail("Expected error")
        } catch let error as CardNexusClientError {
            guard case let .response(status, requestID, envelope) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(status, 403)
            XCTAssertEqual(requestID, "req-123")
            XCTAssertEqual(envelope?.code, "FORBIDDEN")
            XCTAssertFalse((error.errorDescription ?? "").contains("test-cardnexus-key"))
        } catch { XCTFail("Unexpected \(error)") }
    }

    func test429UsesRetryAfterAnd5xxRetriesAreBounded() async throws {
        let delays = DelayRecorder()
        let rateLimited = ScriptedTransport(responses: [
            response(#"{"code":"TOO_MANY_REQUESTS","status":429,"message":"Slow down","data":{}}"#, status: 429, headers: ["Retry-After": "2"]),
            response("[]"),
        ])
        _ = try await makeClient(rateLimited, sleep: { duration in await delays.append(duration) }).fetchLocations()
        let recordedDelays = await delays.values()
        let rateLimitCount = await rateLimited.requestCount()
        XCTAssertEqual(recordedDelays, [.seconds(2)])
        XCTAssertEqual(rateLimitCount, 2)

        let unavailable = #"{"code":"INTERNAL_SERVER_ERROR","status":503,"message":"Unavailable","data":{}}"#
        let failing = ScriptedTransport(responses: [response(unavailable, status: 503), response(unavailable, status: 503), response(unavailable, status: 503)])
        do {
            _ = try await makeClient(failing, maximumAttempts: 3).fetchLocations()
            XCTFail("Expected error")
        } catch let error as CardNexusClientError {
            guard case let .response(status, _, _) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(status, 503)
        } catch { XCTFail("Unexpected \(error)") }
        let failureCount = await failing.requestCount()
        XCTAssertEqual(failureCount, 3)
    }

    func testCancellationIsNeverRetried() async {
        let transport = CancellingTransport()
        do {
            _ = try await makeClient(transport, maximumAttempts: 4).fetchLocations()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected \(error)") }
        let count = await transport.requestCount()
        XCTAssertEqual(count, 1)
    }

    private func makeClient(_ transport: any HTTPTransport, maximumAttempts: Int = 4, sleep: @escaping CardNexusSleep = { _ in }) -> CardNexusClient {
        CardNexusClient(baseURL: URL(string: "https://api.example/v1")!, transport: transport, credentialStore: FixedCredentialStore(key: "test-cardnexus-key"), retryPolicy: CardNexusRetryPolicy(maximumAttempts: maximumAttempts, initialBackoff: .milliseconds(10)), sleep: sleep)
    }
}

private struct FixedCredentialStore: CredentialStoring {
    let key: String?
    func loadAPIKey() throws -> String? { key }
    func saveAPIKey(_ key: String) throws {}
    func deleteAPIKey() throws {}
}

private struct RecordedRequest: Sendable {
    let path: String
    let query: [String: String]
    let authorization: String?
}

private actor ScriptedTransport: HTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private var requests: [RecordedRequest] = []
    init(responses: [(Data, HTTPURLResponse)]) { self.responses = responses }
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        requests.append(RecordedRequest(path: request.url!.path, query: Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }), authorization: request.value(forHTTPHeaderField: "Authorization")))
        guard !responses.isEmpty else { throw TestTransportError.noResponse }
        return responses.removeFirst()
    }
    func recordedRequests() -> [RecordedRequest] { requests }
    func requestCount() -> Int { requests.count }
}

private actor CancellingTransport: HTTPTransport {
    private var count = 0
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { count += 1; throw CancellationError() }
    func requestCount() -> Int { count }
}

private actor DelayRecorder {
    private var recorded: [Duration] = []
    func append(_ duration: Duration) { recorded.append(duration) }
    func values() -> [Duration] { recorded }
}

private enum TestTransportError: Error { case noResponse }

private func response(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: URL(string: "https://api.example")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
}
