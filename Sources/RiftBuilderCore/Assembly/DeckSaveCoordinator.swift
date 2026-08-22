import Foundation

public enum DeckSaveCoordinationError: Error, Hashable, Sendable {
    case executionFailed(String)
}

extension DeckSaveCoordinationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .executionFailed(message): return "The deck save could not execute its inventory movements: \(message)"
        }
    }
}

/// Applies an acknowledged, durable deck-save operation. Draft finalization is
/// deliberately last: CardNexus execution and authoritative reconciliation must
/// both succeed before the saved deck definition changes.
public struct DeckSaveCoordinator: Sendable {
    private let store: any DeckSaveOperationStoring
    private let executor: any DeckSavePlanExecuting
    private let reconciler: any DeckSaveInventoryReconciling
    private let executionJournal: any AssemblyExecutionJournaling
    private let now: @Sendable () -> Date

    public init(store: any DeckSaveOperationStoring, executor: any DeckSavePlanExecuting, reconciler: any DeckSaveInventoryReconciling, executionJournal: any AssemblyExecutionJournaling, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.executor = executor
        self.reconciler = reconciler
        self.executionJournal = executionJournal
        self.now = now
    }

    public func apply(_ operation: DeckSaveOperation) async throws -> DeckSaveApplicationOutcome {
        try await store.saveDeckSaveOperation(operation)

        if operation.plan.movements.isEmpty {
            let snapshot = try await store.finalizeDeckSaveOperation(deckID: operation.plan.deckID, operationID: operation.id, at: now())
            return DeckSaveApplicationOutcome(report: nil, reconciled: true, finalizedSnapshot: snapshot)
        }

        let report: AssemblyExecutionReport
        do {
            report = try await executor.execute(operation.plan.executablePlan)
        } catch {
            try? await reconciler.reconcileDeckSaveInventory()
            throw DeckSaveCoordinationError.executionFailed(error.localizedDescription)
        }

        do {
            try await reconciler.reconcileDeckSaveInventory()
        } catch {
            return DeckSaveApplicationOutcome(
                report: report,
                reconciled: false,
                finalizedSnapshot: nil,
                message: error.localizedDescription
            )
        }

        try await executionJournal.markAssemblyExecutionReconciled(planID: operation.id)
        guard report.isFullySuccessful else {
            return DeckSaveApplicationOutcome(
                report: report,
                reconciled: true,
                finalizedSnapshot: nil,
                message: "Some inventory movements did not succeed. The draft was retained."
            )
        }
        let snapshot = try await store.finalizeDeckSaveOperation(
            deckID: operation.plan.deckID,
            operationID: operation.id,
            at: now()
        )
        return DeckSaveApplicationOutcome(report: report, reconciled: true, finalizedSnapshot: snapshot)
    }
}

extension AssemblyExecutor: DeckSavePlanExecuting {}
