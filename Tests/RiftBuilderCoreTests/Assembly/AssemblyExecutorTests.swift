import Foundation
import XCTest
@testable import RiftBuilderCore

final class AssemblyExecutorTests: XCTestCase {
    func testExecutorChunksAtTwoHundredPersistsIndexedResultsAndMarksAmbiguousFailure() async throws {
        let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let deckID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let movements = (0 ..< 201).map { index in
            PlannedInventoryMovement(
                operationID: "op-\(index)",
                inventoryID: "line-\(index)",
                productID: Int64(index),
                nameSlug: "card-\(index)",
                quantity: 1,
                sourceLocationName: "Box",
                destinationLocationName: "Deck"
            )
        }
        let plan = AssemblyPlan(planID: planID, deckID: deckID, destinationLocationName: "Deck", movements: movements, requirements: [])
        let writer = ExecutorWriter()
        let journal = ExecutorJournal()
        let report = try await AssemblyExecutor(writer: writer, journal: journal, now: { Date(timeIntervalSince1970: 10) }).execute(plan)

        let requests = await writer.requests()
        XCTAssertEqual(requests.map { $0.moves.count }, [200, 1])
        XCTAssertEqual(requests.map(\.idempotencyKey), [
            AssemblyExecutor.idempotencyKey(planID: planID, batchIndex: 0),
            AssemblyExecutor.idempotencyKey(planID: planID, batchIndex: 1),
        ])
        XCTAssertEqual(report.results.count, 201)
        XCTAssertEqual(report.results.filter { if case .succeeded = $0.status { true } else { false } }.count, 199)
        XCTAssertEqual(report.results.filter { if case .rejected = $0.status { true } else { false } }.count, 1)
        XCTAssertEqual(report.results.filter { if case .indeterminate = $0.status { true } else { false } }.count, 1)
        XCTAssertFalse(report.isFullySuccessful)
        let retained = try await journal.assemblyExecution(planID: planID)
        XCTAssertEqual(retained, report)
    }

    func testExecutorNeverSendsTheSameSourceInventoryLineTwiceInOneBatch() async throws {
        let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let movements = [
            PlannedInventoryMovement(operationID: "from-origin-a", inventoryID: "merged-deck-line", productID: 1, nameSlug: "ahri", quantity: 1, sourceLocationName: "Deck", destinationLocationName: "Box A"),
            PlannedInventoryMovement(operationID: "from-origin-b", inventoryID: "merged-deck-line", productID: 1, nameSlug: "ahri", quantity: 1, sourceLocationName: "Deck", destinationLocationName: "Box B"),
        ]
        let plan = AssemblyPlan(planID: planID, deckID: UUID(), destinationLocationName: "Deck", movements: movements, requirements: [])
        let writer = SuccessfulExecutorWriter()
        let journal = ExecutorJournal()

        let report = try await AssemblyExecutor(writer: writer, journal: journal).execute(plan)

        let requests = await writer.requests()
        XCTAssertEqual(requests.map { $0.moves.count }, [1, 1])
        XCTAssertEqual(requests.map(\.idempotencyKey), [
            AssemblyExecutor.idempotencyKey(planID: planID, batchIndex: 0),
            AssemblyExecutor.idempotencyKey(planID: planID, batchIndex: 1),
        ])
        XCTAssertEqual(requests.map { $0.moves[0].destinationLocationName }, ["Box A", "Box B"])
        XCTAssertTrue(report.isFullySuccessful)
    }
}

private actor ExecutorWriter: CardNexusInventoryWriting {
    private var captured: [InventoryBulkMoveRequest] = []

    func upsertInventoryLocation(_ request: InventoryLocationUpsertRequest) async throws -> InventoryLocation {
        InventoryLocation(name: request.name, color: request.color, icon: request.icon)
    }

    func bulkMoveInventoryLines(_ request: InventoryBulkMoveRequest) async throws -> InventoryBulkMoveResponse {
        captured.append(request)
        if captured.count == 2 { throw URLError(.timedOut) }
        return InventoryBulkMoveResponse(results: request.moves.indices.map { index in
            if index == 1 {
                return InventoryBulkMoveItemResult(index: index, status: .rejected(code: "INVALID_COUNT", data: [:]))
            }
            return InventoryBulkMoveItemResult(index: index, status: .succeeded(inventoryID: request.moves[index].inventoryID))
        })
    }

    func requests() -> [InventoryBulkMoveRequest] { captured }
}

private actor ExecutorJournal: AssemblyExecutionJournaling {
    private var reports: [UUID: AssemblyExecutionReport] = [:]
    func saveAssemblyExecution(_ report: AssemblyExecutionReport) async throws { reports[report.planID] = report }
    func assemblyExecution(planID: UUID) async throws -> AssemblyExecutionReport? { reports[planID] }
    func markAssemblyExecutionReconciled(planID: UUID) async throws { reports[planID] = nil }
}

private actor SuccessfulExecutorWriter: CardNexusInventoryWriting {
    private var captured: [InventoryBulkMoveRequest] = []

    func upsertInventoryLocation(_ request: InventoryLocationUpsertRequest) async throws -> InventoryLocation {
        InventoryLocation(name: request.name, color: request.color, icon: request.icon)
    }

    func bulkMoveInventoryLines(_ request: InventoryBulkMoveRequest) async throws -> InventoryBulkMoveResponse {
        captured.append(request)
        return InventoryBulkMoveResponse(results: request.moves.indices.map { index in
            InventoryBulkMoveItemResult(index: index, status: .succeeded(inventoryID: request.moves[index].inventoryID))
        })
    }

    func requests() -> [InventoryBulkMoveRequest] { captured }
}
