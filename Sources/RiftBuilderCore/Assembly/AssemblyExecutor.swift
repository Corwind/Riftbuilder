import Foundation

public enum AssemblyExecutionError: Error, Hashable, Sendable {
    case persistedPlanDoesNotMatch(UUID)
}

extension AssemblyExecutionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .persistedPlanDoesNotMatch(planID):
            return "The retained assembly operation for \(planID.uuidString) does not match this proposal. Create a new plan ID."
        }
    }
}

/// Executes a proposal through CardNexus bulk-update calls. A batch has at most
/// 200 distinct source lines and one stable idempotency key. A 200 response can
/// contain both successful and rejected items; an HTTP 409 rejects the full batch.
/// Other transport failures are deliberately marked indeterminate.
public struct AssemblyExecutor: Sendable {
    private let writer: any CardNexusInventoryWriting
    private let journal: any AssemblyExecutionJournaling
    private let now: @Sendable () -> Date

    public init(writer: any CardNexusInventoryWriting, journal: any AssemblyExecutionJournaling, now: @escaping @Sendable () -> Date = Date.init) {
        self.writer = writer
        self.journal = journal
        self.now = now
    }

    public func execute(_ plan: AssemblyPlan) async throws -> AssemblyExecutionReport {
        let batches = plan.movements.chunkedForCardNexus(maximumCount: 200)
        let initialResults = batches.enumerated().flatMap { batchIndex, movements in
            let key = Self.idempotencyKey(planID: plan.planID, batchIndex: batchIndex)
            return movements.map {
                AssemblyMovementResult(movement: $0, status: .pending, batchIndex: batchIndex, idempotencyKey: key)
            }
        }
        let timestamp = now()
        var report: AssemblyExecutionReport
        if let retained = try await journal.assemblyExecution(planID: plan.planID) {
            guard retained.deckID == plan.deckID,
                  retained.destinationLocationName == plan.destinationLocationName,
                  retained.results.map(\.movement) == initialResults.map(\.movement)
            else { throw AssemblyExecutionError.persistedPlanDoesNotMatch(plan.planID) }
            report = retained
        } else {
            report = AssemblyExecutionReport(
                planID: plan.planID,
                deckID: plan.deckID,
                destinationLocationName: plan.destinationLocationName,
                startedAt: timestamp,
                updatedAt: timestamp,
                results: initialResults
            )
            try await journal.saveAssemblyExecution(report)
        }

        for (batchIndex, movements) in batches.enumerated() {
            if Task.isCancelled {
                markNotAttempted(fromBatch: batchIndex, reason: "Assembly was cancelled before this batch was sent.", report: &report)
                report.updatedAt = now()
                try await journal.saveAssemblyExecution(report)
                return report
            }

            let key = Self.idempotencyKey(planID: plan.planID, batchIndex: batchIndex)
            let request = InventoryBulkMoveRequest(
                idempotencyKey: key,
                moves: movements.map {
                    InventoryBulkLocationMove(
                        inventoryID: $0.inventoryID,
                        quantity: $0.quantity,
                        destinationLocationName: $0.destinationLocationName
                    )
                }
            )
            do {
                let response = try await writer.bulkMoveInventoryLines(request)
                apply(response: response, batchIndex: batchIndex, report: &report)
            } catch is CancellationError {
                markBatchIndeterminate(batchIndex, message: "The request was cancelled after it may have reached CardNexus.", requestID: nil, report: &report)
                markNotAttempted(fromBatch: batchIndex + 1, reason: "Assembly was cancelled.", report: &report)
                report.updatedAt = now()
                try await journal.saveAssemblyExecution(report)
                return report
            } catch let error as CardNexusClientError {
                if case let .response(status, requestID, envelope) = error, (400 ... 499).contains(status) {
                    markBatchRejected(batchIndex, code: envelope?.code ?? "HTTP_\(status)", data: envelope?.data ?? [:], report: &report)
                } else {
                    markBatchIndeterminate(batchIndex, message: error.localizedDescription, requestID: error.requestID, report: &report)
                }
            } catch {
                markBatchIndeterminate(batchIndex, message: error.localizedDescription, requestID: nil, report: &report)
            }
            report.updatedAt = now()
            try await journal.saveAssemblyExecution(report)
        }
        return report
    }

    public static func idempotencyKey(planID: UUID, batchIndex: Int) -> String {
        "riftbuilder-assembly-\(planID.uuidString.lowercased())-\(batchIndex)"
    }
}

private extension AssemblyExecutor {
    func apply(response: InventoryBulkMoveResponse, batchIndex: Int, report: inout AssemblyExecutionReport) {
        var remoteByIndex: [Int: InventoryBulkMoveItemStatus] = [:]
        for result in response.results where remoteByIndex[result.index] == nil {
            remoteByIndex[result.index] = result.status
        }
        let localIndices = report.results.indices.filter { report.results[$0].batchIndex == batchIndex }
        for (itemIndex, localIndex) in localIndices.enumerated() {
            guard let remote = remoteByIndex[itemIndex] else {
                report.results[localIndex].status = .indeterminate(message: "CardNexus omitted this item from the bulk result.", requestID: nil)
                continue
            }
            switch remote {
            case let .succeeded(inventoryID):
                report.results[localIndex].status = .succeeded(remoteInventoryID: inventoryID)
            case let .rejected(code, data):
                report.results[localIndex].status = .rejected(code: code, data: data)
            }
        }
    }

    func markBatchRejected(_ batchIndex: Int, code: String, data: [String: JSONValue], report: inout AssemblyExecutionReport) {
        for index in report.results.indices where report.results[index].batchIndex == batchIndex {
            report.results[index].status = .rejected(code: code, data: data)
        }
    }

    func markBatchIndeterminate(_ batchIndex: Int, message: String, requestID: String?, report: inout AssemblyExecutionReport) {
        for index in report.results.indices where report.results[index].batchIndex == batchIndex {
            report.results[index].status = .indeterminate(message: message, requestID: requestID)
        }
    }

    func markNotAttempted(fromBatch firstBatch: Int, reason: String, report: inout AssemblyExecutionReport) {
        for index in report.results.indices where report.results[index].batchIndex >= firstBatch {
            report.results[index].status = .notAttempted(reason: reason)
        }
    }
}

private extension CardNexusClientError {
    var requestID: String? {
        switch self {
        case let .response(_, requestID, _), let .decoding(_, requestID): return requestID
        default: return nil
        }
    }
}

private extension Array {
    func chunkedForCardNexus(maximumCount: Int) -> [[Element]] where Element == PlannedInventoryMovement {
        guard !isEmpty else { return [] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + maximumCount - 1) / maximumCount)
        var current: [Element] = []
        var inventoryIDs: Set<String> = []
        for movement in self {
            if current.count == maximumCount || inventoryIDs.contains(movement.inventoryID) {
                chunks.append(current)
                current = []
                inventoryIDs = []
            }
            current.append(movement)
            inventoryIDs.insert(movement.inventoryID)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
