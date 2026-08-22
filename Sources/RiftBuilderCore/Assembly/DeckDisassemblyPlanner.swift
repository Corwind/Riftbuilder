import Foundation

public struct DisassemblyPlanRequest: Sendable {
    public let planID: UUID
    public let deckID: UUID
    public let inventory: AssemblyInventorySnapshot
    public let sourceDeckLocationName: String
    public let destinationStorageLocationName: String

    public init(planID: UUID = UUID(), deckID: UUID, inventory: AssemblyInventorySnapshot, sourceDeckLocationName: String, destinationStorageLocationName: String) {
        self.planID = planID
        self.deckID = deckID
        self.inventory = inventory
        self.sourceDeckLocationName = sourceDeckLocationName
        self.destinationStorageLocationName = destinationStorageLocationName
    }
}

public struct DisassemblyPlan: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { planID }
    public let planID: UUID
    public let deckID: UUID
    public let sourceDeckLocationName: String
    public let destinationStorageLocationName: String
    public let movements: [PlannedInventoryMovement]

    public init(planID: UUID, deckID: UUID, sourceDeckLocationName: String, destinationStorageLocationName: String, movements: [PlannedInventoryMovement]) {
        self.planID = planID
        self.deckID = deckID
        self.sourceDeckLocationName = sourceDeckLocationName
        self.destinationStorageLocationName = destinationStorageLocationName
        self.movements = movements
    }

    var executablePlan: AssemblyPlan {
        AssemblyPlan(
            planID: planID,
            deckID: deckID,
            destinationLocationName: destinationStorageLocationName,
            movements: movements,
            requirements: []
        )
    }
}

public enum DisassemblyPlanningError: Error, Hashable, Sendable {
    case emptySourceLocation
    case emptyDestinationLocation
    case sourceLocationNotLinkedToDeck(String, UUID)
    case destinationIsNotStorage(String)
    case sourceAndDestinationAreTheSame
}

extension DisassemblyPlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptySourceLocation: return "A linked CardNexus deck location is required for disassembly."
        case .emptyDestinationLocation: return "Choose a CardNexus storage location before disassembly."
        case let .sourceLocationNotLinkedToDeck(name, deckID): return "The location '\(name)' is not linked to deck \(deckID.uuidString)."
        case let .destinationIsNotStorage(name): return "The destination '\(name)' is not classified as storage."
        case .sourceAndDestinationAreTheSame: return "The disassembly destination must differ from the deck location."
        }
    }
}

/// Moves every synchronized physical line in a deck-linked location to one
/// explicit storage destination. The proposal is deterministic and never edits
/// the cached inventory; reconciliation after execution remains required.
public struct DeckDisassemblyPlanner: Sendable {
    public init() {}

    public func makePlan(_ request: DisassemblyPlanRequest) throws -> DisassemblyPlan {
        let source = request.sourceDeckLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = request.destinationStorageLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw DisassemblyPlanningError.emptySourceLocation }
        guard !destination.isEmpty else { throw DisassemblyPlanningError.emptyDestinationLocation }
        let sourceKey = InventoryLocation.normalize(source)
        let destinationKey = InventoryLocation.normalize(destination)
        guard sourceKey != destinationKey else { throw DisassemblyPlanningError.sourceAndDestinationAreTheSame }

        var policies: [String: LocationPolicy] = [:]
        for policy in request.inventory.locationPolicies { policies[policy.normalizedName] = policy }
        guard let sourcePolicy = policies[sourceKey], sourcePolicy.kind == .deck, sourcePolicy.linkedDeckID == request.deckID else {
            throw DisassemblyPlanningError.sourceLocationNotLinkedToDeck(source, request.deckID)
        }
        guard let destinationPolicy = policies[destinationKey], destinationPolicy.kind == .storage else {
            throw DisassemblyPlanningError.destinationIsNotStorage(destination)
        }

        let movements = request.inventory.lines.compactMap { line -> PlannedInventoryMovement? in
            guard line.quantity > 0,
                  InventoryLocation.normalize(line.locationName) == sourceKey,
                  let printing = request.inventory.printingsByProductID[line.productID]
            else { return nil }
            return PlannedInventoryMovement(
                operationID: "\(request.planID.uuidString.lowercased()):\(line.inventoryID)",
                inventoryID: line.inventoryID,
                productID: line.productID,
                nameSlug: printing.nameSlug,
                quantity: line.quantity,
                sourceLocationName: line.locationName,
                destinationLocationName: destination,
                finish: line.finish,
                language: line.language
            )
        }.sorted {
            if $0.nameSlug != $1.nameSlug { return $0.nameSlug < $1.nameSlug }
            if $0.productID != $1.productID { return $0.productID < $1.productID }
            return $0.inventoryID < $1.inventoryID
        }

        return DisassemblyPlan(
            planID: request.planID,
            deckID: request.deckID,
            sourceDeckLocationName: source,
            destinationStorageLocationName: destination,
            movements: movements
        )
    }
}
