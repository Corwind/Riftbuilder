import Foundation

public struct InventoryLocationQuantityEdit: Hashable, Sendable {
    public let nameSlug: String
    public let quantitiesByLocation: [String: Int]

    public init(nameSlug: String, quantitiesByLocation: [String: Int]) {
        self.nameSlug = nameSlug
        self.quantitiesByLocation = quantitiesByLocation
    }
}

public struct PlannedInventoryQuantityUpdate: Hashable, Sendable {
    public let inventoryID: String
    public let nameSlug: String
    public let quantityAdjustment: Int?
    public let destinationLocationName: String?
    public let count: Int?

    public init(
        inventoryID: String,
        nameSlug: String,
        quantityAdjustment: Int? = nil,
        destinationLocationName: String? = nil,
        count: Int? = nil
    ) {
        self.inventoryID = inventoryID
        self.nameSlug = nameSlug
        self.quantityAdjustment = quantityAdjustment
        self.destinationLocationName = destinationLocationName
        self.count = count
    }

    public var requestItem: InventoryBulkUpdateItem {
        InventoryBulkUpdateItem(
            inventoryID: inventoryID,
            quantityAdjustment: quantityAdjustment,
            destinationLocationName: destinationLocationName,
            count: count
        )
    }
}

public struct PlannedInventoryLineDeletion: Hashable, Sendable {
    public let inventoryID: String
    public let nameSlug: String
    public let quantity: Int

    public init(inventoryID: String, nameSlug: String, quantity: Int) {
        self.inventoryID = inventoryID
        self.nameSlug = nameSlug
        self.quantity = quantity
    }
}

public struct InventoryLocationQuantityEditPlan: Hashable, Sendable {
    public let id: UUID
    public let updates: [PlannedInventoryQuantityUpdate]
    public let deletions: [PlannedInventoryLineDeletion]

    public init(
        id: UUID = UUID(),
        updates: [PlannedInventoryQuantityUpdate],
        deletions: [PlannedInventoryLineDeletion]
    ) {
        self.id = id
        self.updates = updates
        self.deletions = deletions
    }

    public var movedQuantity: Int { updates.compactMap(\.count).reduce(0, +) }
    public var addedQuantity: Int {
        updates.compactMap(\.quantityAdjustment).filter { $0 > 0 }.reduce(0, +)
    }
    public var removedQuantity: Int {
        -updates.compactMap(\.quantityAdjustment).filter { $0 < 0 }.reduce(0, +)
            + deletions.reduce(0) { $0 + $1.quantity }
    }
}

public enum InventoryLocationQuantityEditError: Error, Hashable, Sendable {
    case duplicateCard(String)
    case unknownCard(String)
    case invalidQuantity(nameSlug: String, locationKey: String, quantity: Int)
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
            return "The requested quantity for '\(nameSlug)' at '\(locationKey)' is invalid (\(quantity))."
        case .unknownDestination(let locationKey):
            return "The destination location '\(locationKey)' is unavailable."
        case .unlocatedDestination:
            return "Cards can be removed from Unlocated, but new copies cannot be added there in inventory edit mode."
        case .incompletePlan(let nameSlug):
            return "RiftBuilder could not produce a complete inventory update plan for '\(nameSlug)'."
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
        var updates: [PlannedInventoryQuantityUpdate] = []
        var deletions: [PlannedInventoryLineDeletion] = []

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

            var lines = cardLines.map {
                MutableInventoryLine(
                    inventoryID: $0.inventoryID,
                    locationKey: InventoryLocation.normalize($0.locationName),
                    quantity: $0.quantity
                )
            }
            var currentByLocation: [String: Int] = [:]
            for line in lines {
                currentByLocation[line.locationKey, default: 0] += line.quantity
            }
            let requestedByLocation = edit.quantitiesByLocation
            var deficits = try requestedByLocation.compactMap { locationKey, requested -> DestinationDeficit? in
                let deficit = requested - currentByLocation[locationKey, default: 0]
                guard deficit > 0 else { return nil }
                guard locationKey != "__unlocated__" else {
                    throw InventoryLocationQuantityEditError.unlocatedDestination
                }
                guard let displayName = destinationNames[locationKey] else {
                    throw InventoryLocationQuantityEditError.unknownDestination(locationKey)
                }
                return DestinationDeficit(
                    locationKey: locationKey,
                    displayName: displayName,
                    remaining: deficit
                )
            }
            .sorted { $0.locationKey < $1.locationKey }
            var surplusByLocation = currentByLocation.reduce(into: [String: Int]()) { result, item in
                let requested = requestedByLocation[item.key, default: 0]
                if item.value > requested { result[item.key] = item.value - requested }
            }

            let currentTotal = currentByLocation.values.reduce(0, +)
            let requestedTotal = requestedByLocation.values.reduce(0, +)
            var additionsRemaining = max(0, requestedTotal - currentTotal)
            for deficitIndex in deficits.indices
            where additionsRemaining > 0 && deficits[deficitIndex].remaining > 0 {
                let quantity = min(additionsRemaining, deficits[deficitIndex].remaining)
                if let targetLineIndex = lines.firstIndex(where: {
                    $0.quantity > 0 && $0.locationKey == deficits[deficitIndex].locationKey
                }) {
                    updates.append(
                        PlannedInventoryQuantityUpdate(
                            inventoryID: lines[targetLineIndex].inventoryID,
                            nameSlug: edit.nameSlug,
                            quantityAdjustment: quantity
                        ))
                    lines[targetLineIndex].quantity += quantity
                } else if let carrierIndex = lines.firstIndex(where: { $0.quantity > 0 }) {
                    updates.append(
                        PlannedInventoryQuantityUpdate(
                            inventoryID: lines[carrierIndex].inventoryID,
                            nameSlug: edit.nameSlug,
                            quantityAdjustment: quantity
                        ))
                    lines[carrierIndex].quantity += quantity
                    updates.append(
                        PlannedInventoryQuantityUpdate(
                            inventoryID: lines[carrierIndex].inventoryID,
                            nameSlug: edit.nameSlug,
                            destinationLocationName: deficits[deficitIndex].displayName,
                            count: quantity
                        ))
                    lines[carrierIndex].quantity -= quantity
                } else {
                    throw InventoryLocationQuantityEditError.incompletePlan(nameSlug: edit.nameSlug)
                }
                additionsRemaining -= quantity
                deficits[deficitIndex].remaining -= quantity
            }
            guard additionsRemaining == 0 else {
                throw InventoryLocationQuantityEditError.incompletePlan(nameSlug: edit.nameSlug)
            }

            for lineIndex in lines.indices {
                let sourceKey = lines[lineIndex].locationKey
                var availableSurplus = min(
                    lines[lineIndex].quantity,
                    surplusByLocation[sourceKey, default: 0]
                )
                guard availableSurplus > 0 else { continue }

                for deficitIndex in deficits.indices
                where availableSurplus > 0 && deficits[deficitIndex].remaining > 0 {
                    let quantity = min(availableSurplus, deficits[deficitIndex].remaining)
                    updates.append(
                        PlannedInventoryQuantityUpdate(
                            inventoryID: lines[lineIndex].inventoryID,
                            nameSlug: edit.nameSlug,
                            destinationLocationName: deficits[deficitIndex].displayName,
                            count: quantity
                        ))
                    availableSurplus -= quantity
                    surplusByLocation[sourceKey, default: 0] -= quantity
                    deficits[deficitIndex].remaining -= quantity
                    if quantity == lines[lineIndex].quantity {
                        lines[lineIndex].locationKey = deficits[deficitIndex].locationKey
                    } else {
                        lines[lineIndex].quantity -= quantity
                    }
                }
            }

            for sourceKey in surplusByLocation.keys.sorted() {
                var remaining = surplusByLocation[sourceKey, default: 0]
                guard remaining > 0 else { continue }
                for lineIndex in lines.indices
                where remaining > 0 && lines[lineIndex].quantity > 0
                    && lines[lineIndex].locationKey == sourceKey {
                    let quantity = min(remaining, lines[lineIndex].quantity)
                    if quantity == lines[lineIndex].quantity {
                        deletions.append(
                            PlannedInventoryLineDeletion(
                                inventoryID: lines[lineIndex].inventoryID,
                                nameSlug: edit.nameSlug,
                                quantity: quantity
                            ))
                        lines[lineIndex].quantity = 0
                    } else {
                        updates.append(
                            PlannedInventoryQuantityUpdate(
                                inventoryID: lines[lineIndex].inventoryID,
                                nameSlug: edit.nameSlug,
                                quantityAdjustment: -quantity
                            ))
                        lines[lineIndex].quantity -= quantity
                    }
                    remaining -= quantity
                }
                surplusByLocation[sourceKey] = remaining
            }

            guard deficits.allSatisfy({ $0.remaining == 0 }),
                  surplusByLocation.values.allSatisfy({ $0 == 0 })
            else {
                throw InventoryLocationQuantityEditError.incompletePlan(nameSlug: edit.nameSlug)
            }
        }

        return InventoryLocationQuantityEditPlan(
            id: planID,
            updates: updates,
            deletions: deletions
        )
    }
}

private struct DestinationDeficit {
    let locationKey: String
    let displayName: String
    var remaining: Int
}

private struct MutableInventoryLine {
    let inventoryID: String
    var locationKey: String
    var quantity: Int
}
