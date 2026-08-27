import Foundation

public struct InventoryLocationQuantityEdit: Hashable, Sendable {
    public let nameSlug: String
    public let quantitiesByLocation: [String: Int]

    public init(nameSlug: String, quantitiesByLocation: [String: Int]) {
        self.nameSlug = nameSlug
        self.quantitiesByLocation = quantitiesByLocation
    }
}

public struct InventoryLocationQuantityEditPlan: Hashable, Sendable {
    public let id: UUID
    public let movements: [BulkLocationMovement]

    public init(id: UUID = UUID(), movements: [BulkLocationMovement]) {
        self.id = id
        self.movements = movements
    }

    public var movedQuantity: Int { movements.reduce(0) { $0 + $1.quantity } }
}

public enum InventoryLocationQuantityEditError: Error, Hashable, Sendable {
    case duplicateCard(String)
    case unknownCard(String)
    case invalidQuantity(nameSlug: String, locationKey: String, quantity: Int)
    case totalChanged(nameSlug: String, current: Int, requested: Int)
    case unknownDestination(String)
    case unlocatedDestination
    case incompletePlan(nameSlug: String)
}

extension InventoryLocationQuantityEditError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateCard(let nameSlug):
            return "The quantity edit contains '\(nameSlug)' more than once."
        case .unknownCard(let nameSlug):
            return "No physical inventory lines were found for '\(nameSlug)'."
        case .invalidQuantity(let nameSlug, let locationKey, let quantity):
            return
                "The requested quantity for '\(nameSlug)' at '\(locationKey)' is invalid (\(quantity))."
        case .totalChanged(let nameSlug, let current, let requested):
            return "'\(nameSlug)' owns \(current) copies, but the edited locations total \(requested)."
        case .unknownDestination(let locationKey):
            return "The destination location '\(locationKey)' is unavailable."
        case .unlocatedDestination:
            return
                "Cards can be moved out of Unlocated, but Unlocated cannot receive cards in inventory edit mode."
        case .incompletePlan(let nameSlug):
            return "RiftBuilder could not produce a complete location plan for '\(nameSlug)'."
        }
    }
}

public struct InventoryLocationQuantityEditPlanner: Sendable {
    public init() {}

    public func makePlan(
        inventory: AssemblyInventorySnapshot,
        edits: [InventoryLocationQuantityEdit],
        planID: UUID = UUID()
    ) throws -> InventoryLocationQuantityEditPlan {
        let printingNameByProductID = inventory.printingsByProductID.mapValues(\CardPrinting.nameSlug)
        let destinationNames = Dictionary(
            uniqueKeysWithValues: inventory.locationPolicies
                .filter { $0.kind != .unavailable }
                .map { ($0.normalizedName, $0.displayName) })
        var seenCards: Set<String> = []
        var movements: [BulkLocationMovement] = []

        for edit in edits.sorted(by: { $0.nameSlug < $1.nameSlug }) {
            guard seenCards.insert(edit.nameSlug).inserted else {
                throw InventoryLocationQuantityEditError.duplicateCard(edit.nameSlug)
            }
            for (locationKey, quantity) in edit.quantitiesByLocation where quantity < 0 {
                throw InventoryLocationQuantityEditError.invalidQuantity(
                    nameSlug: edit.nameSlug, locationKey: locationKey, quantity: quantity)
            }

            let cardLines = inventory.lines
                .filter { $0.quantity > 0 && printingNameByProductID[$0.productID] == edit.nameSlug }
                .sorted { $0.inventoryID < $1.inventoryID }
            guard !cardLines.isEmpty else {
                throw InventoryLocationQuantityEditError.unknownCard(edit.nameSlug)
            }

            var currentByLocation: [String: Int] = [:]
            for line in cardLines {
                currentByLocation[InventoryLocation.normalize(line.locationName), default: 0] += line.quantity
            }
            let requestedByLocation = edit.quantitiesByLocation
            let currentTotal = currentByLocation.values.reduce(0, +)
            let requestedTotal = requestedByLocation.values.reduce(0, +)
            guard currentTotal == requestedTotal else {
                throw InventoryLocationQuantityEditError.totalChanged(nameSlug: edit.nameSlug, current: currentTotal, requested: requestedTotal)
            }
            var deficits = try requestedByLocation.compactMap { locationKey, requested -> DestinationDeficit? in
                let deficit = requested - currentByLocation[locationKey, default: 0]
                guard deficit > 0 else { return nil }
                guard locationKey != "__unlocated__" else { throw InventoryLocationQuantityEditError.unlocatedDestination }
                guard let displayName = destinationNames[locationKey] else {
                    throw InventoryLocationQuantityEditError.unknownDestination(locationKey)
                }
                return DestinationDeficit(locationKey: locationKey, displayName: displayName, remaining: deficit)
            }
            .sorted { $0.locationKey < $1.locationKey }

            var surplusByLocation = currentByLocation.reduce(into: [String: Int]()) { result, item in
                let requested = requestedByLocation[item.key, default: 0]
                if item.value > requested { result[item.key] = item.value - requested }
            }

            for line in cardLines {
                let sourceKey = InventoryLocation.normalize(line.locationName)
                var lineRemaining = min(line.quantity, surplusByLocation[sourceKey, default: 0])
                guard lineRemaining > 0 else { continue }

                for index in deficits.indices where lineRemaining > 0 && deficits[index].remaining > 0 {
                    let quantity = min(lineRemaining, deficits[index].remaining)
                    movements.append(
                        BulkLocationMovement(
                            inventoryID: line.inventoryID,
                            nameSlug: edit.nameSlug,
                            sourceLocationName: line.locationName,
                            quantity: quantity,
                            destinationLocationName: deficits[index].displayName
                        ))
                    lineRemaining -= quantity
                    surplusByLocation[sourceKey, default: 0] -= quantity
                    deficits[index].remaining -= quantity
                }
            }

            guard deficits.allSatisfy({ $0.remaining == 0 }),
                surplusByLocation.values.allSatisfy({ $0 == 0 })
            else {
                throw InventoryLocationQuantityEditError.incompletePlan(nameSlug: edit.nameSlug)
            }
        }

        return InventoryLocationQuantityEditPlan(id: planID, movements: movements)
    }
}

private struct DestinationDeficit {
    let locationKey: String
    let displayName: String
    var remaining: Int
}
