import Foundation
import RiftBuilderCore

struct AppInventoryQuantityEditResult: Sendable {
    let editedCardCount: Int
    let bulkUpdateCount: Int
    let deletedLineCount: Int
    let addedQuantity: Int
    let removedQuantity: Int
    let movedQuantity: Int
    let synchronizationWarning: String?
}

enum AppInventoryQuantityEditError: LocalizedError {
    case noChanges
    case executionFailed(completedUpdates: Int, completedDeletions: Int, rejectionCodes: [String])
    case requestFailed(completedUpdates: Int, completedDeletions: Int, reason: String)
    case requestAndReconciliationFailed(
        completedUpdates: Int,
        completedDeletions: Int,
        request: String,
        reconciliation: String
    )

    var errorDescription: String? {
        switch self {
        case .noChanges:
            return "No inventory quantities changed."
        case .executionFailed(let completedUpdates, let completedDeletions, let rejectionCodes):
            let codes = rejectionCodes.isEmpty ? "an unknown error" : rejectionCodes.joined(separator: ", ")
            return "CardNexus rejected part of the edit after \(completedUpdates) update(s) and \(completedDeletions) deletion(s) succeeded (\(codes)). Inventory was refreshed before returning."
        case .requestFailed(let completedUpdates, let completedDeletions, let reason):
            return "The inventory edit stopped after \(completedUpdates) update(s) and \(completedDeletions) deletion(s) succeeded: \(reason) Inventory was refreshed before returning."
        case .requestAndReconciliationFailed(
            let completedUpdates,
            let completedDeletions,
            let request,
            let reconciliation
        ):
            return "The inventory edit stopped after \(completedUpdates) update(s) and \(completedDeletions) deletion(s) succeeded: \(request) Refreshing inventory also failed: \(reconciliation) Synchronize before editing again."
        }
    }
}

protocol InventoryQuantityEditing: AppDataServicing {
    func updateInventoryLocationQuantities(_ edits: [InventoryLocationQuantityEdit]) async throws
        -> AppInventoryQuantityEditResult
}

extension LiveAppDataService {
    func updateInventoryLocationQuantities(_ edits: [InventoryLocationQuantityEdit]) async throws
        -> AppInventoryQuantityEditResult
    {
        guard !edits.isEmpty else { throw AppInventoryQuantityEditError.noChanges }
        _ = try await refreshInventoryOnly()
        let snapshot = try await assemblyStore.assemblyInventorySnapshot()
        let plan = try InventoryLocationQuantityEditPlanner().makePlan(
            inventory: snapshot,
            edits: edits
        )
        guard !plan.updates.isEmpty || !plan.deletions.isEmpty else {
            throw AppInventoryQuantityEditError.noChanges
        }

        let batches = updateBatches(plan.updates)
        var completedUpdates = 0
        var completedDeletions = 0
        var rejectionCodes: Set<String> = []

        do {
            execution: for (batchIndex, batch) in batches.enumerated() {
                try Task.checkCancellation()
                let response = try await cardNexus.bulkUpdateInventoryLines(
                    InventoryBulkUpdateRequest(
                        idempotencyKey: "riftbuilder-inventory-edit-\(plan.id.uuidString.lowercased())-\(batchIndex)",
                        items: batch.map(\.requestItem)
                    ))
                let resultsByIndex = Dictionary(
                    response.results.map { ($0.index, $0.status) },
                    uniquingKeysWith: { first, _ in first }
                )
                for index in batch.indices {
                    switch resultsByIndex[index] {
                    case .succeeded:
                        completedUpdates += 1
                    case .rejected(let code, _):
                        rejectionCodes.insert(code)
                    case nil:
                        rejectionCodes.insert("MISSING_RESULT")
                    }
                }
                if !rejectionCodes.isEmpty { break execution }
            }

            if rejectionCodes.isEmpty {
                for deletion in plan.deletions {
                    try Task.checkCancellation()
                    try await cardNexus.deleteInventoryLine(inventoryID: deletion.inventoryID)
                    completedDeletions += 1
                }
            }
        } catch {
            let requestMessage = error.localizedDescription
            do {
                _ = try await refreshInventoryOnly()
            } catch let reconciliationError {
                throw AppInventoryQuantityEditError.requestAndReconciliationFailed(
                    completedUpdates: completedUpdates,
                    completedDeletions: completedDeletions,
                    request: requestMessage,
                    reconciliation: reconciliationError.localizedDescription
                )
            }
            throw AppInventoryQuantityEditError.requestFailed(
                completedUpdates: completedUpdates,
                completedDeletions: completedDeletions,
                reason: requestMessage
            )
        }

        let synchronizationWarning: String?
        do {
            _ = try await refreshInventoryOnly()
            synchronizationWarning = nil
        } catch {
            synchronizationWarning = error.localizedDescription
        }
        if !rejectionCodes.isEmpty {
            throw AppInventoryQuantityEditError.executionFailed(
                completedUpdates: completedUpdates,
                completedDeletions: completedDeletions,
                rejectionCodes: rejectionCodes.sorted()
            )
        }
        return AppInventoryQuantityEditResult(
            editedCardCount: edits.count,
            bulkUpdateCount: completedUpdates,
            deletedLineCount: completedDeletions,
            addedQuantity: plan.addedQuantity,
            removedQuantity: plan.removedQuantity,
            movedQuantity: plan.movedQuantity,
            synchronizationWarning: synchronizationWarning
        )
    }

    private func updateBatches(
        _ updates: [PlannedInventoryQuantityUpdate]
    ) -> [[PlannedInventoryQuantityUpdate]] {
        var pending = updates
        var batches: [[PlannedInventoryQuantityUpdate]] = []
        while !pending.isEmpty {
            var usedInventoryIDs: Set<String> = []
            var batch: [PlannedInventoryQuantityUpdate] = []
            var deferred: [PlannedInventoryQuantityUpdate] = []
            for update in pending {
                if batch.count < 200, usedInventoryIDs.insert(update.inventoryID).inserted {
                    batch.append(update)
                } else {
                    deferred.append(update)
                }
            }
            batches.append(batch)
            pending = deferred
        }
        return batches
    }
}

extension LiveAppDataService: InventoryQuantityEditing {}

extension DemoAppDataService: InventoryQuantityEditing {
    func updateInventoryLocationQuantities(_ edits: [InventoryLocationQuantityEdit]) async throws
        -> AppInventoryQuantityEditResult
    {
        throw AppServiceError.unavailable("Inventory quantity editing is unavailable in demo mode.")
    }
}

extension UnavailableAppDataService: InventoryQuantityEditing {
    func updateInventoryLocationQuantities(_ edits: [InventoryLocationQuantityEdit]) async throws
        -> AppInventoryQuantityEditResult
    {
        throw AppServiceError.unavailable("Inventory quantity editing is unavailable.")
    }
}

extension AppModel {
    func saveInventoryLocationQuantities(_ edits: [InventoryLocationQuantityEdit]) async -> Bool {
        guard let editor = service as? any InventoryQuantityEditing else {
            notice = "Inventory quantity editing is unavailable."
            return false
        }
        do {
            let result = try await editor.updateInventoryLocationQuantities(edits)
            await loadInventory()
            await loadLocations()
            await loadDecks()
            var changes: [String] = []
            if result.addedQuantity > 0 { changes.append("added \(result.addedQuantity)") }
            if result.removedQuantity > 0 { changes.append("removed \(result.removedQuantity)") }
            if result.movedQuantity > 0 { changes.append("moved \(result.movedQuantity)") }
            let changeSummary = changes.isEmpty ? "updated quantities" : changes.joined(separator: ", ")
            var message = "Saved \(result.editedCardCount) card edit\(result.editedCardCount == 1 ? "" : "s"): \(changeSummary)."
            if result.deletedLineCount > 0 {
                message += " Removed \(result.deletedLineCount) empty inventory line\(result.deletedLineCount == 1 ? "" : "s")."
            }
            if let warning = result.synchronizationWarning {
                message += " CardNexus saved the changes, but the final refresh failed: \(warning)"
            }
            notice = message
            return true
        } catch {
            await loadInventory()
            notice = "Inventory update failed: \(error.localizedDescription)"
            return false
        }
    }
}
