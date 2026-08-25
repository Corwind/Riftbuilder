import Foundation
import XCTest
@testable import RiftBuilderCore

final class DeckDeletionFinalizationPolicyTests: XCTestCase {
    func testAllowsDeletionOnlyAfterEveryMoveSucceedsAndInventoryIsReconciled() {
        XCTAssertTrue(DeckDeletionFinalizationPolicy.canDeleteDefinition(after: report(statuses: [.succeeded(remoteInventoryID: "remote-1")]), inventoryWasReconciled: true))
    }

    func testRetainsDefinitionWhenAnyMovementIsRejectedOrIndeterminate() {
        XCTAssertFalse(DeckDeletionFinalizationPolicy.canDeleteDefinition(after: report(statuses: [
            .succeeded(remoteInventoryID: "remote-1"),
            .rejected(code: "INVALID", data: [:]),
        ]), inventoryWasReconciled: true))
        XCTAssertFalse(DeckDeletionFinalizationPolicy.canDeleteDefinition(after: report(statuses: [
            .indeterminate(message: "Timed out", requestID: "request-1"),
        ]), inventoryWasReconciled: true))
    }

    func testRetainsDefinitionWhenReconciliationFails() {
        XCTAssertFalse(DeckDeletionFinalizationPolicy.canDeleteDefinition(after: report(statuses: [.succeeded(remoteInventoryID: "remote-1")]), inventoryWasReconciled: false))
    }

    func testEmptyExecutionReportCannotAuthorizeDeletion() {
        XCTAssertFalse(DeckDeletionFinalizationPolicy.canDeleteDefinition(after: report(statuses: []), inventoryWasReconciled: true))
    }

    private func report(statuses: [AssemblyMovementStatus]) -> AssemblyExecutionReport {
        let planID = UUID()
        let deckID = UUID()
        let results = statuses.enumerated().map { index, status in
            AssemblyMovementResult(
                movement: PlannedInventoryMovement(
                    operationID: "move-\(index)",
                    inventoryID: "line-\(index)",
                    productID: Int64(index + 1),
                    nameSlug: "card-\(index)",
                    quantity: 1,
                    sourceLocationName: "Deck",
                    destinationLocationName: "Box"
                ),
                status: status,
                batchIndex: 0,
                idempotencyKey: "batch"
            )
        }
        return AssemblyExecutionReport(
            planID: planID,
            deckID: deckID,
            destinationLocationName: "Box",
            startedAt: .distantPast,
            updatedAt: .distantPast,
            results: results
        )
    }
}
