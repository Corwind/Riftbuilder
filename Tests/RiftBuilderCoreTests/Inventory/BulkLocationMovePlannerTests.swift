import Foundation
import XCTest
@testable import RiftBuilderCore

final class BulkLocationMovePlannerTests: XCTestCase {
    func testPlansEveryMatchingPhysicalLineFromSelectedSource() {
        let snapshot = inventorySnapshot()
        let plan = BulkLocationMovePlanner().makePlan(
            inventory: snapshot,
            nameSlugs: ["ahri", "jinx"],
            sourceLocationKey: "box a",
            destinationLocationName: "Box B",
            planID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )

        XCTAssertEqual(plan.movements, [
            BulkLocationMovement(inventoryID: "line-a", nameSlug: "ahri", sourceLocationName: "Box A", quantity: 2, destinationLocationName: "Box B"),
            BulkLocationMovement(inventoryID: "line-c", nameSlug: "jinx", sourceLocationName: "BOX A", quantity: 4, destinationLocationName: "Box B"),
        ])
        XCTAssertEqual(plan.totalQuantity, 6)
    }

    func testAllSourcesSkipsLinesAlreadyAtDestinationAndUnknownPrintings() {
        let plan = BulkLocationMovePlanner().makePlan(
            inventory: inventorySnapshot(),
            nameSlugs: ["ahri"],
            sourceLocationKey: nil,
            destinationLocationName: "box b"
        )

        XCTAssertEqual(plan.movements.map(\.inventoryID), ["line-a"])
        XCTAssertEqual(plan.totalQuantity, 2)
    }

    private func inventorySnapshot() -> AssemblyInventorySnapshot {
        let now = Date(timeIntervalSince1970: 1)
        let lines = [
            InventoryLine(inventoryID: "line-b", productID: 1, finish: "Normal", quantity: 3, locationName: "Box B", updatedAt: now),
            InventoryLine(inventoryID: "line-a", productID: 1, finish: "Normal", quantity: 2, locationName: "Box A", updatedAt: now),
            InventoryLine(inventoryID: "line-c", productID: 2, finish: "Normal", quantity: 4, locationName: "BOX A", updatedAt: now),
            InventoryLine(inventoryID: "line-unknown", productID: 99, finish: "Normal", quantity: 8, locationName: "Box A", updatedAt: now),
        ]
        return AssemblyInventorySnapshot(
            lines: lines,
            printingsByProductID: [
                1: CardPrinting(productID: 1, nameSlug: "ahri", printingSlug: "ahri-1", displayName: "Ahri"),
                2: CardPrinting(productID: 2, nameSlug: "jinx", printingSlug: "jinx-1", displayName: "Jinx"),
            ],
            locationPolicies: []
        )
    }
}
