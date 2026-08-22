import Foundation
import XCTest
@testable import RiftBuilderCore

final class DeckSaveCoordinatorBehaviorTests: XCTestCase {
    func testSuccessfulMovesAndReconciliationFinalizeTheReviewedDraft() async throws {
        let fixture = CoordinatorFixture(reportStatus: .succeeded(remoteInventoryID: "remote-line"))

        let outcome = try await fixture.coordinator.apply(fixture.operation)

        XCTAssertTrue(outcome.isFinalized)
        XCTAssertTrue(outcome.reconciled)
        let saved = await fixture.store.savedOperationIDs()
        let finalized = await fixture.store.finalizedOperationIDs()
        let reconciliationCalls = await fixture.reconciler.callCount()
        let reconciledPlans = await fixture.executionJournal.reconciledPlanIDs()
        XCTAssertEqual(saved, [fixture.operation.id])
        XCTAssertEqual(finalized, [fixture.operation.id])
        XCTAssertEqual(reconciliationCalls, 1)
        XCTAssertEqual(reconciledPlans, [fixture.operation.id])
    }

    func testRejectedMovementReconcilesButRetainsDraftForCorrectionOrRetry() async throws {
        let fixture = CoordinatorFixture(reportStatus: .rejected(code: "INVALID", data: [:]))

        let outcome = try await fixture.coordinator.apply(fixture.operation)

        XCTAssertFalse(outcome.isFinalized)
        XCTAssertTrue(outcome.reconciled)
        let finalized = await fixture.store.finalizedOperationIDs()
        let reconciliationCalls = await fixture.reconciler.callCount()
        let reconciledPlans = await fixture.executionJournal.reconciledPlanIDs()
        XCTAssertTrue(finalized.isEmpty)
        XCTAssertEqual(reconciliationCalls, 1)
        XCTAssertEqual(reconciledPlans, [fixture.operation.id])
    }

    func testReconciliationFailureNeverFinalizesEvenWhenEveryMoveSucceeded() async throws {
        let fixture = CoordinatorFixture(reportStatus: .succeeded(remoteInventoryID: "remote-line"), reconciliationError: TestFailure.sync)

        let outcome = try await fixture.coordinator.apply(fixture.operation)

        XCTAssertFalse(outcome.isFinalized)
        XCTAssertFalse(outcome.reconciled)
        XCTAssertNotNil(outcome.message)
        let finalized = await fixture.store.finalizedOperationIDs()
        let reconciledPlans = await fixture.executionJournal.reconciledPlanIDs()
        XCTAssertTrue(finalized.isEmpty)
        XCTAssertTrue(reconciledPlans.isEmpty)
    }

    func testExecutionFailureRetainsOperationAndAttemptsSafetyReconciliation() async throws {
        let fixture = CoordinatorFixture(executionError: TestFailure.execution)

        do {
            _ = try await fixture.coordinator.apply(fixture.operation)
            XCTFail("Expected execution failure")
        } catch let error as DeckSaveCoordinationError {
            guard case .executionFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let saved = await fixture.store.savedOperationIDs()
        let finalized = await fixture.store.finalizedOperationIDs()
        let reconciliationCalls = await fixture.reconciler.callCount()
        XCTAssertEqual(saved, [fixture.operation.id])
        XCTAssertTrue(finalized.isEmpty)
        XCTAssertEqual(reconciliationCalls, 1)
    }

    func testDefinitionOnlyChangeFinalizesWithoutCallingCardNexusOrSync() async throws {
        let fixture = CoordinatorFixture(hasMovements: false)

        let outcome = try await fixture.coordinator.apply(fixture.operation)

        XCTAssertTrue(outcome.isFinalized)
        XCTAssertNil(outcome.report)
        let executionCalls = await fixture.executor.callCount()
        let reconciliationCalls = await fixture.reconciler.callCount()
        XCTAssertEqual(executionCalls, 0)
        XCTAssertEqual(reconciliationCalls, 0)
    }
}

private enum TestFailure: LocalizedError {
    case execution
    case sync

    var errorDescription: String? {
        switch self {
        case .execution: "Execution failed"
        case .sync: "Sync failed"
        }
    }
}

private struct CoordinatorFixture {
    let operation: DeckSaveOperation
    let store: CoordinatorStore
    let executor: CoordinatorExecutor
    let reconciler: CoordinatorReconciler
    let executionJournal: CoordinatorExecutionJournal
    let coordinator: DeckSaveCoordinator

    init(reportStatus: AssemblyMovementStatus = .succeeded(remoteInventoryID: "remote"), executionError: TestFailure? = nil, reconciliationError: TestFailure? = nil, hasMovements: Bool = true) {
        let deckID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let movement = PlannedInventoryMovement(operationID: "move", inventoryID: "line", productID: 1, nameSlug: "ahri", quantity: 1, sourceLocationName: "Box", destinationLocationName: "Deck")
        let movements = hasMovements ? [movement] : []
        let plan = DeckSavePlan(planID: planID, deckID: deckID, deckLocationName: "Deck", movements: movements, requirements: [], unresolvedRemovalDestinations: [])
        operation = DeckSaveOperation(plan: plan, draftUpdatedAt: Date(timeIntervalSince1970: 10), createdAt: Date(timeIntervalSince1970: 11))
        store = CoordinatorStore(deckID: deckID)
        executor = CoordinatorExecutor(planID: planID, deckID: deckID, movement: movement, status: reportStatus, failure: executionError)
        reconciler = CoordinatorReconciler(failure: reconciliationError)
        executionJournal = CoordinatorExecutionJournal()
        coordinator = DeckSaveCoordinator(store: store, executor: executor, reconciler: reconciler, executionJournal: executionJournal, now: { Date(timeIntervalSince1970: 20) })
    }
}

private actor CoordinatorStore: DeckSaveOperationStoring {
    private let deckID: UUID
    private var saved: [UUID] = []
    private var finalized: [UUID] = []

    init(deckID: UUID) { self.deckID = deckID }

    func saveDeckSaveOperation(_ operation: DeckSaveOperation) async throws { saved.append(operation.id) }
    func deckSaveOperation(deckID: UUID) async throws -> DeckSaveOperation? { nil }
    func finalizeDeckSaveOperation(deckID: UUID, operationID: UUID, at date: Date) async throws -> DeckSnapshot? {
        finalized.append(operationID)
        return DeckSnapshot(deck: Deck(id: self.deckID, name: "Deck", updatedAt: date), entries: [], identities: [:])
    }
    func savedOperationIDs() -> [UUID] { saved }
    func finalizedOperationIDs() -> [UUID] { finalized }
}

private actor CoordinatorExecutor: DeckSavePlanExecuting {
    private let report: AssemblyExecutionReport
    private let failure: TestFailure?
    private var calls = 0

    init(planID: UUID, deckID: UUID, movement: PlannedInventoryMovement, status: AssemblyMovementStatus, failure: TestFailure?) {
        report = AssemblyExecutionReport(
            planID: planID,
            deckID: deckID,
            destinationLocationName: "Deck",
            startedAt: .distantPast,
            updatedAt: .distantPast,
            results: [AssemblyMovementResult(movement: movement, status: status, batchIndex: 0, idempotencyKey: "key")]
        )
        self.failure = failure
    }

    func execute(_ plan: AssemblyPlan) async throws -> AssemblyExecutionReport {
        calls += 1
        if let failure { throw failure }
        return report
    }
    func callCount() -> Int { calls }
}

private actor CoordinatorReconciler: DeckSaveInventoryReconciling {
    private let failure: TestFailure?
    private var calls = 0

    init(failure: TestFailure?) { self.failure = failure }
    func reconcileDeckSaveInventory() async throws {
        calls += 1
        if let failure { throw failure }
    }
    func callCount() -> Int { calls }
}

private actor CoordinatorExecutionJournal: AssemblyExecutionJournaling {
    private var reconciled: [UUID] = []
    func saveAssemblyExecution(_ report: AssemblyExecutionReport) async throws {}
    func assemblyExecution(planID: UUID) async throws -> AssemblyExecutionReport? { nil }
    func markAssemblyExecutionReconciled(planID: UUID) async throws { reconciled.append(planID) }
    func reconciledPlanIDs() -> [UUID] { reconciled }
}
