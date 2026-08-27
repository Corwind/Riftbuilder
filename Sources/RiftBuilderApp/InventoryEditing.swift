import Foundation
import RiftBuilderCore

struct AppInventoryQuantityEditResult: Sendable {
    let editedCardCount: Int
    let movementCount: Int
    let movedQuantity: Int
    let synchronizationWarning: String?
}

enum AppInventoryQuantityEditError: LocalizedError {
    case noChanges
    case executionFailed(completedMovements: Int, rejectionCodes: [String])
    case requestFailed(completedMovements: Int, reason: String)
    case requestAndReconciliationFailed(
        completedMovements: Int, request: String, reconciliation: String)

    var errorDescription: String? {
        switch self {
        case .noChanges:
            return "No inventory quantities changed."
        case .executionFailed(let completedMovements, let rejectionCodes):
            let codes =
                rejectionCodes.isEmpty ? "an unknown error" : rejectionCodes.joined(separator: ", ")
            return
                "CardNexus rejected part of the edit after \(completedMovements) movement(s) succeeded (\(codes)). Inventory was refreshed before returning."
        case .requestFailed(let completedMovements, let reason):
            return
                "The inventory edit stopped after \(completedMovements) movement(s) succeeded: \(reason) Inventory was refreshed before returning."
        case .requestAndReconciliationFailed(let completedMovements, let request, let reconciliation):
            return
                "The inventory edit stopped after \(completedMovements) movement(s) succeeded: \(request) Refreshing inventory also failed: \(reconciliation) Synchronize before editing again."
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
            inventory: snapshot, edits: edits)
        guard !plan.movements.isEmpty else { throw AppInventoryQuantityEditError.noChanges }

        let batches = movementBatches(plan.movements)
        var completedMovements = 0
        var rejectionCodes: Set<String> = []

        do {
            execution: for (batchIndex, batch) in batches.enumerated() {
                try Task.checkCancellation()
                let response = try await cardNexus.bulkMoveInventoryLines(
                    InventoryBulkMoveRequest(
                        idempotencyKey:
                            "riftbuilder-inventory-edit-\(plan.id.uuidString.lowercased())-\(batchIndex)",
                        moves: batch.map {
                            InventoryBulkLocationMove(
                                inventoryID: $0.inventoryID,
                                quantity: $0.quantity,
                                destinationLocationName: $0.destinationLocationName
                            )
                        }
                    ))
                let resultsByIndex = Dictionary(
                    response.results.map { ($0.index, $0.status) }, uniquingKeysWith: { first, _ in first })
                for index in batch.indices {
                    switch resultsByIndex[index] {
                    case .succeeded:
                        completedMovements += 1
                    case .rejected(let code, _):
                        rejectionCodes.insert(code)
                    case nil:
                        rejectionCodes.insert("MISSING_RESULT")
                    }
                }
                if !rejectionCodes.isEmpty { break execution }
            }
        } catch {
            let requestMessage = error.localizedDescription
            do {
                _ = try await refreshInventoryOnly()
            } catch let reconciliationError {
                throw AppInventoryQuantityEditError.requestAndReconciliationFailed(
                    completedMovements: completedMovements,
                    request: requestMessage,
                    reconciliation: reconciliationError.localizedDescription
                )
            }
            throw AppInventoryQuantityEditError.requestFailed(
                completedMovements: completedMovements, reason: requestMessage)
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
                completedMovements: completedMovements,
                rejectionCodes: rejectionCodes.sorted()
            )
        }
        return AppInventoryQuantityEditResult(
            editedCardCount: edits.count,
            movementCount: completedMovements,
            movedQuantity: plan.movedQuantity,
            synchronizationWarning: synchronizationWarning
        )
    }

    private func movementBatches(_ movements: [BulkLocationMovement]) -> [[BulkLocationMovement]] {
        var pending = movements
        var batches: [[BulkLocationMovement]] = []
        while !pending.isEmpty {
            var usedInventoryIDs: Set<String> = []
            var batch: [BulkLocationMovement] = []
            var deferred: [BulkLocationMovement] = []
            for movement in pending {
                if batch.count < 200, usedInventoryIDs.insert(movement.inventoryID).inserted {
                    batch.append(movement)
                } else {
                    deferred.append(movement)
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
            var message =
                "Updated \(result.editedCardCount) card\(result.editedCardCount == 1 ? "" : "s") across \(result.movementCount) inventory movement\(result.movementCount == 1 ? "" : "s")."
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
