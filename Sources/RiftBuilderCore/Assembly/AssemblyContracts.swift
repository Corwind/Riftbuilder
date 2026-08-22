import Foundation

public protocol AssemblyInventoryProviding: Sendable {
    func assemblyInventorySnapshot() async throws -> AssemblyInventorySnapshot
}

public protocol AssemblyExecutionJournaling: Sendable {
    func saveAssemblyExecution(_ report: AssemblyExecutionReport) async throws
    func assemblyExecution(planID: UUID) async throws -> AssemblyExecutionReport?
    func markAssemblyExecutionReconciled(planID: UUID) async throws
}

public protocol DeckSavePlanExecuting: Sendable {
    func execute(_ plan: AssemblyPlan) async throws -> AssemblyExecutionReport
}

public protocol DeckSaveInventoryReconciling: Sendable {
    func reconcileDeckSaveInventory() async throws
}

public protocol DeckSaveOperationStoring: Sendable {
    func saveDeckSaveOperation(_ operation: DeckSaveOperation) async throws
    func deckSaveOperation(deckID: UUID) async throws -> DeckSaveOperation?
    func finalizeDeckSaveOperation(deckID: UUID, operationID: UUID, at date: Date) async throws -> DeckSnapshot?
}

public struct InventoryBulkLocationMove: Codable, Hashable, Sendable {
    public let inventoryID: String
    public let quantity: Int
    public let destinationLocationName: String

    public init(inventoryID: String, quantity: Int, destinationLocationName: String) {
        self.inventoryID = inventoryID
        self.quantity = quantity
        self.destinationLocationName = destinationLocationName
    }
}

public struct InventoryBulkMoveRequest: Codable, Hashable, Sendable {
    public let idempotencyKey: String
    public let moves: [InventoryBulkLocationMove]

    public init(idempotencyKey: String, moves: [InventoryBulkLocationMove]) {
        self.idempotencyKey = idempotencyKey
        self.moves = moves
    }
}

public enum InventoryBulkMoveItemStatus: Codable, Hashable, Sendable {
    case succeeded(inventoryID: String)
    case rejected(code: String, data: [String: JSONValue])
}

public struct InventoryBulkMoveItemResult: Codable, Hashable, Sendable {
    public let index: Int
    public let status: InventoryBulkMoveItemStatus

    public init(index: Int, status: InventoryBulkMoveItemStatus) {
        self.index = index
        self.status = status
    }
}

public struct InventoryBulkMoveResponse: Codable, Hashable, Sendable {
    public let results: [InventoryBulkMoveItemResult]

    public init(results: [InventoryBulkMoveItemResult]) {
        self.results = results
    }
}

public struct InventoryLocationUpsertRequest: Codable, Hashable, Sendable {
    public let name: String
    public let color: String?
    public let icon: String?

    public init(name: String, color: String? = nil, icon: String? = nil) {
        self.name = name
        self.color = color
        self.icon = icon
    }
}

public protocol CardNexusInventoryWriting: Sendable {
    /// Creates the location or returns/updates the case-insensitive match. The
    /// client always sends `upsert: true`, making setup safe to repeat.
    func upsertInventoryLocation(_ request: InventoryLocationUpsertRequest) async throws -> InventoryLocation

    /// Moves up to 200 distinct inventory lines using CardNexus's bulk update
    /// endpoint. The request's idempotency key must be reused for any retry.
    func bulkMoveInventoryLines(_ request: InventoryBulkMoveRequest) async throws -> InventoryBulkMoveResponse
}
