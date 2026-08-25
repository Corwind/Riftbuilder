import Foundation

public struct BulkLocationMovePlan: Hashable, Sendable {
    public let id: UUID
    public let destinationLocationName: String
    public let movements: [BulkLocationMovement]

    public init(id: UUID = UUID(), destinationLocationName: String, movements: [BulkLocationMovement]) {
        self.id = id
        self.destinationLocationName = destinationLocationName
        self.movements = movements
    }

    public var totalQuantity: Int { movements.reduce(0) { $0 + $1.quantity } }
}

public struct BulkLocationMovement: Hashable, Sendable {
    public let inventoryID: String
    public let nameSlug: String
    public let sourceLocationName: String?
    public let quantity: Int
    public let destinationLocationName: String

    public init(inventoryID: String, nameSlug: String, sourceLocationName: String?, quantity: Int, destinationLocationName: String) {
        self.inventoryID = inventoryID
        self.nameSlug = nameSlug
        self.sourceLocationName = sourceLocationName
        self.quantity = quantity
        self.destinationLocationName = destinationLocationName
    }
}

public struct BulkLocationMovePlanner: Sendable {
    public init() {}

    public func makePlan(
        inventory: AssemblyInventorySnapshot,
        nameSlugs: Set<String>,
        sourceLocationKey: String?,
        destinationLocationName: String,
        planID: UUID = UUID()
    ) -> BulkLocationMovePlan {
        let destinationKey = InventoryLocation.normalize(destinationLocationName)
        let movements = inventory.lines.compactMap { line -> BulkLocationMovement? in
            guard line.quantity > 0,
                  let nameSlug = inventory.printingsByProductID[line.productID]?.nameSlug,
                  nameSlugs.contains(nameSlug)
            else { return nil }

            let lineLocationKey = InventoryLocation.normalize(line.locationName)
            guard lineLocationKey != destinationKey,
                  sourceLocationKey.map({ $0 == lineLocationKey }) != false
            else { return nil }

            return BulkLocationMovement(
                inventoryID: line.inventoryID,
                nameSlug: nameSlug,
                sourceLocationName: line.locationName,
                quantity: line.quantity,
                destinationLocationName: destinationLocationName
            )
        }
        .sorted { $0.inventoryID < $1.inventoryID }

        return BulkLocationMovePlan(id: planID, destinationLocationName: destinationLocationName, movements: movements)
    }
}
