import Foundation

/// The line-level inventory and catalogue data needed by the pure assembly planner.
/// Keeping the original `InventoryLine` values here is intentional: assembly must
/// allocate physical lots, not quantities flattened by card name.
public struct AssemblyInventorySnapshot: Sendable {
    public let lines: [InventoryLine]
    public let printingsByProductID: [Int64: CardPrinting]
    public let locationPolicies: [LocationPolicy]

    public init(lines: [InventoryLine], printingsByProductID: [Int64: CardPrinting], locationPolicies: [LocationPolicy]) {
        self.lines = lines
        self.printingsByProductID = printingsByProductID
        self.locationPolicies = locationPolicies
    }
}

/// Controls which deck zones are treated as supplies rather than scanned,
/// individually owned cards. These choices affect availability and physical
/// inventory movements, but never deck legality.
public struct DeckInventoryAvailability: Codable, Hashable, Sendable {
    public let alwaysAvailableRunes: Bool
    public let alwaysAvailableBattlefields: Bool

    public init(alwaysAvailableRunes: Bool = true, alwaysAvailableBattlefields: Bool = true) {
        self.alwaysAvailableRunes = alwaysAvailableRunes
        self.alwaysAvailableBattlefields = alwaysAvailableBattlefields
    }

    public func isAlwaysAvailable(_ zone: DeckZone) -> Bool {
        switch zone {
        case .rune: alwaysAvailableRunes
        case .battlefield: alwaysAvailableBattlefields
        default: false
        }
    }
}

public struct AssemblyPlanRequest: Sendable {
    public let planID: UUID
    public let deck: DeckSnapshot
    public let inventory: AssemblyInventorySnapshot
    public let destinationLocationName: String
    public let inventoryAvailability: DeckInventoryAvailability

    public init(planID: UUID = UUID(), deck: DeckSnapshot, inventory: AssemblyInventorySnapshot, destinationLocationName: String, inventoryAvailability: DeckInventoryAvailability = DeckInventoryAvailability()) {
        self.planID = planID
        self.deck = deck
        self.inventory = inventory
        self.destinationLocationName = destinationLocationName
        self.inventoryAvailability = inventoryAvailability
    }
}

public struct PrintingPreference: Codable, Hashable, Sendable {
    public let productID: Int64?
    public let finish: String?
    public let language: String?

    public init(productID: Int64? = nil, finish: String? = nil, language: String? = nil) {
        self.productID = productID
        self.finish = finish
        self.language = language
    }

    public var isExplicit: Bool { productID != nil || finish != nil || language != nil }
}

public struct AssemblyRequirementResult: Codable, Hashable, Identifiable, Sendable {
    public var id: String {
        [nameSlug, preference.productID.map(String.init) ?? "", preference.finish ?? "", preference.language ?? ""].joined(separator: "|")
    }

    public let nameSlug: String
    public let preference: PrintingPreference
    public let required: Int
    public let alreadyAtDestination: Int
    public let allocatedFromStorage: Int
    public let missing: Int

    public init(nameSlug: String, preference: PrintingPreference, required: Int, alreadyAtDestination: Int, allocatedFromStorage: Int, missing: Int) {
        self.nameSlug = nameSlug
        self.preference = preference
        self.required = required
        self.alreadyAtDestination = alreadyAtDestination
        self.allocatedFromStorage = allocatedFromStorage
        self.missing = missing
    }
}

public struct PlannedInventoryMovement: Codable, Hashable, Identifiable, Sendable {
    /// Stable for a given plan and source line, and suitable for correlating a
    /// bulk result with local state. The CardNexus idempotency key applies to the
    /// containing batch because that API accepts one key per request.
    public var id: String { operationID }
    public let operationID: String
    public let inventoryID: String
    public let productID: Int64
    public let nameSlug: String
    public let quantity: Int
    public let sourceLocationName: String?
    public let destinationLocationName: String
    public let finish: String?
    public let language: String?
    public let originLotID: UUID?

    public init(operationID: String, inventoryID: String, productID: Int64, nameSlug: String, quantity: Int, sourceLocationName: String?, destinationLocationName: String, finish: String? = nil, language: String? = nil, originLotID: UUID? = nil) {
        self.operationID = operationID
        self.inventoryID = inventoryID
        self.productID = productID
        self.nameSlug = nameSlug
        self.quantity = quantity
        self.sourceLocationName = sourceLocationName
        self.destinationLocationName = destinationLocationName
        self.finish = finish
        self.language = language
        self.originLotID = originLotID
    }
}

public struct AssemblyPlan: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { planID }
    public let planID: UUID
    public let deckID: UUID
    public let destinationLocationName: String
    public let movements: [PlannedInventoryMovement]
    public let requirements: [AssemblyRequirementResult]

    public init(planID: UUID, deckID: UUID, destinationLocationName: String, movements: [PlannedInventoryMovement], requirements: [AssemblyRequirementResult]) {
        self.planID = planID
        self.deckID = deckID
        self.destinationLocationName = destinationLocationName
        self.movements = movements
        self.requirements = requirements
    }

    public var missingQuantity: Int { requirements.reduce(0) { $0 + $1.missing } }
    public var canFullyAssemble: Bool { missingQuantity == 0 }
}

public enum AssemblyMovementStatus: Codable, Hashable, Sendable {
    case pending
    case succeeded(remoteInventoryID: String)
    case rejected(code: String, data: [String: JSONValue])
    /// The request failed without a conclusive per-item response. The server may
    /// have applied it, so callers must retry with the same key or reconcile.
    case indeterminate(message: String, requestID: String?)
    case notAttempted(reason: String)
}

public struct AssemblyMovementResult: Codable, Hashable, Identifiable, Sendable {
    public var id: String { movement.operationID }
    public let movement: PlannedInventoryMovement
    public var status: AssemblyMovementStatus
    public let batchIndex: Int
    public let idempotencyKey: String

    public init(movement: PlannedInventoryMovement, status: AssemblyMovementStatus, batchIndex: Int, idempotencyKey: String) {
        self.movement = movement
        self.status = status
        self.batchIndex = batchIndex
        self.idempotencyKey = idempotencyKey
    }
}

public struct AssemblyExecutionReport: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { planID }
    public let planID: UUID
    public let deckID: UUID
    public let destinationLocationName: String
    public let startedAt: Date
    public var updatedAt: Date
    public var results: [AssemblyMovementResult]

    public init(planID: UUID, deckID: UUID, destinationLocationName: String, startedAt: Date, updatedAt: Date, results: [AssemblyMovementResult]) {
        self.planID = planID
        self.deckID = deckID
        self.destinationLocationName = destinationLocationName
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.results = results
    }

    public var isFullySuccessful: Bool {
        results.allSatisfy {
            if case .succeeded = $0.status { return true }
            return false
        }
    }

    /// A refresh against CardNexus remains mandatory even when every item says
    /// `ok`, because bulk updates can split or merge remote inventory lines.
    public var requiresReconciliation: Bool { !results.isEmpty }
}
