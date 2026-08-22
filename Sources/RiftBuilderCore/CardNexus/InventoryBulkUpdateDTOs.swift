import Foundation

public enum InventoryBulkMoveValidationError: Error, Hashable, Sendable {
    case emptyIdempotencyKey
    case invalidItemCount(Int)
    case duplicateInventoryID(String)
    case invalidMove(index: Int)
}

extension InventoryBulkMoveValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyIdempotencyKey:
            return "The CardNexus bulk-update idempotency key cannot be empty."
        case let .invalidItemCount(count):
            return "CardNexus bulk update accepts between 1 and 200 items, not \(count)."
        case let .duplicateInventoryID(id):
            return "Inventory line '\(id)' appears more than once in the bulk update."
        case let .invalidMove(index):
            return "Bulk move at index \(index) needs an inventory ID, a positive count, and a destination location."
        }
    }
}

struct InventoryBulkUpdateRequestDTO: Encodable, Sendable {
    let items: [InventoryBulkUpdateItemDTO]
}

struct InventoryBulkUpdateItemDTO: Encodable, Sendable {
    let inventoryId: String
    let location: String
    let count: Int
}

struct InventoryBulkUpdateResponseDTO: Decodable, Sendable {
    let results: [InventoryBulkUpdateResultDTO]

    var model: InventoryBulkMoveResponse {
        InventoryBulkMoveResponse(results: results.map(\.model))
    }
}

struct InventoryBulkUpdateResultDTO: Decodable, Sendable {
    let index: Int
    let status: String
    let inventoryId: String?
    let code: String?
    let data: [String: JSONValue]?

    var model: InventoryBulkMoveItemResult {
        if status == "ok", let inventoryId {
            return InventoryBulkMoveItemResult(index: index, status: .succeeded(inventoryID: inventoryId))
        }
        return InventoryBulkMoveItemResult(
            index: index,
            status: .rejected(code: code ?? "INVALID_RESPONSE", data: data ?? [:])
        )
    }
}
