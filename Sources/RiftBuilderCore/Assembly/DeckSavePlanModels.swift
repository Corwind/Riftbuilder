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
    public let locationName: String

    public init(requirement: DeckPhysicalRequirementKey, locationName: String) {
        self.requirement = requirement
        self.locationName = locationName
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

    public init(planID: UUID = UUID(), savedDeck: DeckSnapshot, draft: DeckDraftSnapshot, inventory: AssemblyInventorySnapshot, deckLocationName: String, removalDestinations: [DeckRemovalDestination] = []) {
        self.planID = planID
        self.savedDeck = savedDeck
        self.draft = draft
        self.inventory = inventory
        self.deckLocationName = deckLocationName
        self.removalDestinations = removalDestinations
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

    public init(planID: UUID, deckID: UUID, deckLocationName: String, movements: [PlannedInventoryMovement], requirements: [DeckSaveRequirementResult], unresolvedRemovalDestinations: [DeckPhysicalRequirementKey]) {
        self.planID = planID
        self.deckID = deckID
        self.deckLocationName = deckLocationName
        self.movements = movements
        self.requirements = requirements
        self.unresolvedRemovalDestinations = unresolvedRemovalDestinations
    }

    public var missingQuantity: Int { requirements.reduce(0) { $0 + $1.missing } }
    public var canApply: Bool { missingQuantity == 0 && unresolvedRemovalDestinations.isEmpty }

    public var executablePlan: AssemblyPlan {
        AssemblyPlan(
            planID: planID,
            deckID: deckID,
            destinationLocationName: deckLocationName,
            movements: movements,
            requirements: []
        )
    }
}
