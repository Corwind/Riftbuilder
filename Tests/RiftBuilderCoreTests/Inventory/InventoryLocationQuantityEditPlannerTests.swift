import Foundation
import XCTest
@testable import RiftBuilderCore

final class InventoryLocationQuantityEditPlannerTests: XCTestCase {
    func testPlansBalancedMovesAcrossLocations() throws {
        let edit = InventoryLocationQuantityEdit(
            nameSlug: "ahri",
            quantitiesByLocation: ["box a": 1, "box b": 2, "deck": 3]
        )
        let plan = try InventoryLocationQuantityEditPlanner().makePlan(inventory: snapshot(), edits: [edit])

        XCTAssertEqual(plan.movements, [
            BulkLocationMovement(inventoryID: "line-a", nameSlug: "ahri", sourceLocationName: "Box A", quantity: 1, destinationLocationName: "Box B"),
            BulkLocationMovement(inventoryID: "line-a", nameSlug: "ahri", sourceLocationName: "Box A", quantity: 1, destinationLocationName: "Deck"),
        ])
        XCTAssertEqual(plan.movedQuantity, 2)
    }

    func testRejectsChangingTheOwnedTotal() {
        let edit = InventoryLocationQuantityEdit(nameSlug: "ahri", quantitiesByLocation: ["box a": 1])

        XCTAssertThrowsError(try InventoryLocationQuantityEditPlanner().makePlan(inventory: snapshot(), edits: [edit])) { error in
            XCTAssertEqual(error as? InventoryLocationQuantityEditError, .totalChanged(nameSlug: "ahri", current: 6, requested: 1))
        }
    }

    func testMovesCardsOutOfUnlocated() throws {
        let edit = InventoryLocationQuantityEdit(
            nameSlug: "ahri",
            quantitiesByLocation: ["__unlocated__": 0, "box a": 4, "box b": 1, "deck": 2]
        )
        let plan = try InventoryLocationQuantityEditPlanner().makePlan(inventory: snapshot(includingUnlocated: true), edits: [edit])

        XCTAssertEqual(plan.movements, [
            BulkLocationMovement(inventoryID: "line-u", nameSlug: "ahri", sourceLocationName: nil, quantity: 1, destinationLocationName: "Box A"),
        ])
    }

    private func snapshot(includingUnlocated: Bool = false) -> AssemblyInventorySnapshot {
        var lines = [
            InventoryLine(inventoryID: "line-a", productID: 1, finish: "Normal", quantity: 3, locationName: "Box A", updatedAt: .distantPast),
            InventoryLine(inventoryID: "line-b", productID: 1, finish: "Normal", quantity: 2, locationName: "Deck", updatedAt: .distantPast),
            InventoryLine(inventoryID: "line-c", productID: 1, finish: "Normal", quantity: 1, locationName: "Box B", updatedAt: .distantPast),
        ]
        if includingUnlocated {
            lines.append(InventoryLine(inventoryID: "line-u", productID: 1, finish: "Normal", quantity: 1, locationName: nil, updatedAt: .distantPast))
        }
        return AssemblyInventorySnapshot(
            lines: lines,
            printingsByProductID: [1: CardPrinting(productID: 1, nameSlug: "ahri", printingSlug: "ahri-1", displayName: "Ahri")],
            locationPolicies: [
                LocationPolicy(normalizedName: "box a", displayName: "Box A"),
                LocationPolicy(normalizedName: "box b", displayName: "Box B"),
                LocationPolicy(normalizedName: "deck", displayName: "Deck", kind: .deck, countsAsAvailable: false),
            ]
        )
    }
}
