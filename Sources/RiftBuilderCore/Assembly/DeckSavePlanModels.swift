import Foundation

public struct DeckPhysicalRequirementKey: Codable, Hashable, Sendable {
    public let nameSlug: String
    public let preference: PrintingPreference

    public init(nameSlug: String, preference: PrintingPreference = PrintingPreference()) {
        self.nameSlug = nameSlug
        self.preference = preference
    }

    public init(entry: DeckEntry) {
        self.init(
            nameSlug: entry.nameSlug,
            preference: PrintingPreference(
                productID: entry.preferredProductID,
                finish: entry.preferredFinish,
                language: entry.preferredLanguage
            )
        )
    }
}

public struct DeckRemovalDestination: Codable, Hashable, Sendable {
    public let requirement: DeckPhysicalRequirementKey
    public let originLotID: UUID?
    public let locationName: String

    public init(requirement: DeckPhysicalRequirementKey, originLotID: UUID? = nil, locationName: String) {
        self.requirement = requirement
        self.originLotID = originLotID
        self.locationName = locationName
    }

    public init(route: DeckReturnRouteKey, locationName: String) {
        self.init(requirement: route.requirement, originLotID: route.originLotID, locationName: locationName)
    }
}

public struct DeckReturnRouteKey: Codable, Hashable, Sendable {
    public let requirement: DeckPhysicalRequirementKey
    public let originLotID: UUID?

    public init(requirement: DeckPhysicalRequirementKey, originLotID: UUID?) {
        self.requirement = requirement
        self.originLotID = originLotID
    }
}

public struct DeckReturnRoute: Codable, Hashable, Sendable {
    public let key: DeckReturnRouteKey
    public let quantity: Int
    public let previousLocationName: String?
    public let destinationLocationName: String?

    public init(key: DeckReturnRouteKey, quantity: Int, previousLocationName: String?, destinationLocationName: String?) {
        self.key = key
        self.quantity = quantity
        self.previousLocationName = previousLocationName
        self.destinationLocationName = destinationLocationName
    }
}

public enum DeckSaveMovementDirection: String, Codable, Hashable, Sendable {
    case intoDeck
    case outOfDeck
}

public struct DeckSaveRequirementResult: Codable, Hashable, Sendable {
    public let requirement: DeckPhysicalRequirementKey
    public let direction: DeckSaveMovementDirection
    public let requested: Int
    public let allocated: Int
    public let missing: Int
    public let destinationLocationName: String?

    public init(requirement: DeckPhysicalRequirementKey, direction: DeckSaveMovementDirection, requested: Int, allocated: Int, missing: Int, destinationLocationName: String?) {
        self.requirement = requirement
        self.direction = direction
        self.requested = requested
        self.allocated = allocated
        self.missing = missing
        self.destinationLocationName = destinationLocationName
    }
}

public struct DeckSavePlanRequest: Sendable {
    public let planID: UUID
    public let savedDeck: DeckSnapshot
    public let draft: DeckDraftSnapshot
    public let inventory: AssemblyInventorySnapshot
    public let deckLocationName: String
    public let removalDestinations: [DeckRemovalDestination]
    public let inventoryAvailability: DeckInventoryAvailability
    public let originLots: [DeckCardOriginLot]

    public init(planID: UUID = UUID(), savedDeck: DeckSnapshot, draft: DeckDraftSnapshot, inventory: AssemblyInventorySnapshot, deckLocationName: String, removalDestinations: [DeckRemovalDestination] = [], inventoryAvailability: DeckInventoryAvailability = DeckInventoryAvailability(), originLots: [DeckCardOriginLot] = []) {
        self.planID = planID
        self.savedDeck = savedDeck
        self.draft = draft
        self.inventory = inventory
        self.deckLocationName = deckLocationName
        self.removalDestinations = removalDestinations
        self.inventoryAvailability = inventoryAvailability
        self.originLots = originLots
    }
}

public struct DeckSavePlan: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { planID }
    public let planID: UUID
    public let deckID: UUID
    public let deckLocationName: String
    public let movements: [PlannedInventoryMovement]
    public let requirements: [DeckSaveRequirementResult]
    public let unresolvedRemovalDestinations: [DeckPhysicalRequirementKey]
    public let returnRoutes: [DeckReturnRoute]
    public let unresolvedReturnRoutes: [DeckReturnRouteKey]

    public init(planID: UUID, deckID: UUID, deckLocationName: String, movements: [PlannedInventoryMovement], requirements: [DeckSaveRequirementResult], unresolvedRemovalDestinations: [DeckPhysicalRequirementKey], returnRoutes: [DeckReturnRoute] = [], unresolvedReturnRoutes: [DeckReturnRouteKey] = []) {
        self.planID = planID
        self.deckID = deckID
        self.deckLocationName = deckLocationName
        self.movements = movements
        self.requirements = requirements
        self.unresolvedRemovalDestinations = unresolvedRemovalDestinations
        self.returnRoutes = returnRoutes
        self.unresolvedReturnRoutes = unresolvedReturnRoutes
    }

    public var missingQuantity: Int { requirements.reduce(0) { $0 + $1.missing } }
    public var canApply: Bool { missingQuantity == 0 && unresolvedRemovalDestinations.isEmpty && unresolvedReturnRoutes.isEmpty }

    public var executablePlan: AssemblyPlan {
        AssemblyPlan(
            planID: planID,
            deckID: deckID,
            destinationLocationName: deckLocationName,
            movements: movements,
            requirements: []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case planID, deckID, deckLocationName, movements, requirements
        case unresolvedRemovalDestinations, returnRoutes, unresolvedReturnRoutes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planID = try container.decode(UUID.self, forKey: .planID)
        deckID = try container.decode(UUID.self, forKey: .deckID)
        deckLocationName = try container.decode(String.self, forKey: .deckLocationName)
        movements = try container.decode([PlannedInventoryMovement].self, forKey: .movements)
        requirements = try container.decode([DeckSaveRequirementResult].self, forKey: .requirements)
        unresolvedRemovalDestinations = try container.decodeIfPresent([DeckPhysicalRequirementKey].self, forKey: .unresolvedRemovalDestinations) ?? []
        returnRoutes = try container.decodeIfPresent([DeckReturnRoute].self, forKey: .returnRoutes) ?? []
        unresolvedReturnRoutes = try container.decodeIfPresent([DeckReturnRouteKey].self, forKey: .unresolvedReturnRoutes) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(planID, forKey: .planID)
        try container.encode(deckID, forKey: .deckID)
        try container.encode(deckLocationName, forKey: .deckLocationName)
        try container.encode(movements, forKey: .movements)
        try container.encode(requirements, forKey: .requirements)
        try container.encode(unresolvedRemovalDestinations, forKey: .unresolvedRemovalDestinations)
        try container.encode(returnRoutes, forKey: .returnRoutes)
        try container.encode(unresolvedReturnRoutes, forKey: .unresolvedReturnRoutes)
    }
}

public struct DeckSaveOperation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { plan.planID }
    public let plan: DeckSavePlan
    public let draftUpdatedAt: Date
    public let createdAt: Date

    public init(plan: DeckSavePlan, draftUpdatedAt: Date, createdAt: Date = Date()) {
        self.plan = plan
        self.draftUpdatedAt = draftUpdatedAt
        self.createdAt = createdAt
    }
}

public struct DeckSaveApplicationOutcome: Sendable {
    public let report: AssemblyExecutionReport?
    public let reconciled: Bool
    public let finalizedSnapshot: DeckSnapshot?
    public let message: String?

    public init(report: AssemblyExecutionReport?, reconciled: Bool, finalizedSnapshot: DeckSnapshot?, message: String? = nil) {
        self.report = report
        self.reconciled = reconciled
        self.finalizedSnapshot = finalizedSnapshot
        self.message = message
    }

    public var isFinalized: Bool { finalizedSnapshot != nil }
}
