import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RiftBuilderCore

@MainActor
final class CardNexusInventoryWriteTests: XCTestCase {
    func testBulkMoveSendsCountLocationAndStableIdempotencyKeyAndMapsMixedResults() async throws {
        let transport = WriteTransport(responses: [writeResponse(#"{"results":[{"index":0,"status":"ok","inventoryId":"line-a"},{"index":1,"status":"error","code":"INVALID_COUNT","data":{"inventoryId":"line-b","available":1}}]}"#)])
        let client = makeWriteClient(transport)
        let response = try await client.bulkMoveInventoryLines(InventoryBulkMoveRequest(
            idempotencyKey: "assembly-plan-batch-0",
            moves: [
                InventoryBulkLocationMove(inventoryID: "line-a", quantity: 2, destinationLocationName: "Deck Ahri"),
                InventoryBulkLocationMove(inventoryID: "line-b", quantity: 3, destinationLocationName: "Deck Ahri"),
            ]
        ))

        XCTAssertEqual(response.results, [
            InventoryBulkMoveItemResult(index: 0, status: .succeeded(inventoryID: "line-a")),
            InventoryBulkMoveItemResult(index: 1, status: .rejected(code: "INVALID_COUNT", data: ["inventoryId": .string("line-b"), "available": .number(1)])),
        ])
        let captured = await transport.requests()
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/inventory/bulk/update")
        XCTAssertEqual(request.idempotencyKey, "assembly-plan-batch-0")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["inventoryId"] as? String, "line-a")
        XCTAssertEqual(items[0]["count"] as? Int, 2)
        XCTAssertEqual(items[0]["location"] as? String, "Deck Ahri")
    }

    func testBulkRetryReusesTheExactRequestAndKey() async throws {
        let transport = WriteTransport(responses: [
            writeResponse(#"{"code":"INTERNAL_SERVER_ERROR","status":503,"message":"retry","data":{}}"#, status: 503),
            writeResponse(#"{"results":[{"index":0,"status":"ok","inventoryId":"line-a"}]}"#),
        ])
        let client = makeWriteClient(transport, maximumAttempts: 2)
        _ = try await client.bulkMoveInventoryLines(InventoryBulkMoveRequest(
            idempotencyKey: "same-key",
            moves: [InventoryBulkLocationMove(inventoryID: "line-a", quantity: 1, destinationLocationName: "Deck")]
        ))
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.idempotencyKey), ["same-key", "same-key"])
        XCTAssertEqual(requests[0].body, requests[1].body)
    }

    func testLocationUpsertAlwaysSendsUpsertTrue() async throws {
        let transport = WriteTransport(responses: [writeResponse(#"{"name":"Deck Ahri","color":"purple","icon":null}"#)])
        let location = try await makeWriteClient(transport).upsertInventoryLocation(
            InventoryLocationUpsertRequest(name: " Deck Ahri ", color: "purple")
        )
        XCTAssertEqual(location, InventoryLocation(name: "Deck Ahri", color: "purple", icon: nil))
        let captured = await transport.requests()
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.path, "/v1/inventory/locations")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "Deck Ahri")
        XCTAssertEqual(json["upsert"] as? Bool, true)
    }

    func testBulkRejectsDuplicateSourceLineWithoutNetworkRequest() async {
        let transport = WriteTransport(responses: [])
        do {
            _ = try await makeWriteClient(transport).bulkMoveInventoryLines(InventoryBulkMoveRequest(
                idempotencyKey: "key",
                moves: [
                    InventoryBulkLocationMove(inventoryID: "same", quantity: 1, destinationLocationName: "Deck"),
                    InventoryBulkLocationMove(inventoryID: "same", quantity: 1, destinationLocationName: "Deck"),
                ]
            ))
            XCTFail("Expected validation failure")
        } catch let error as InventoryBulkMoveValidationError {
            XCTAssertEqual(error, .duplicateInventoryID("same"))
        } catch { XCTFail("Unexpected \(error)") }
        let captured = await transport.requests()
        XCTAssertTrue(captured.isEmpty)
    }

    private func makeWriteClient(_ transport: any HTTPTransport, maximumAttempts: Int = 1) -> CardNexusClient {
        CardNexusClient(
            baseURL: URL(string: "https://api.example/v1")!,
            transport: transport,
            credentialStore: WriteCredentialStore(),
            retryPolicy: CardNexusRetryPolicy(maximumAttempts: maximumAttempts, initialBackoff: .zero),
            sleep: { _ in }
        )
    }
}

private struct WriteCredentialStore: CredentialStoring {
    func loadAPIKey() throws -> String? { "secret" }
    func saveAPIKey(_ key: String) throws {}
    func deleteAPIKey() throws {}
}

private struct CapturedWriteRequest: Sendable {
    let method: String
    let path: String
    let idempotencyKey: String?
    let body: Data
}

private actor WriteTransport: HTTPTransport {
    private var responses: [(Data, HTTPURLResponse)]
    private var captured: [CapturedWriteRequest] = []

    init(responses: [(Data, HTTPURLResponse)]) { self.responses = responses }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(CapturedWriteRequest(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key"),
            body: request.httpBody ?? Data()
        ))
        guard !responses.isEmpty else { throw WriteTransportError.noResponse }
        return responses.removeFirst()
    }

    func requests() -> [CapturedWriteRequest] { captured }
}

private enum WriteTransportError: Error { case noResponse }

private func writeResponse(_ json: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: URL(string: "https://api.example")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
}
