import Foundation
import XCTest
@testable import RiftBuilderCore

final class InventoryLocationQuantityEditPlannerTests: XCTestCase {
    func testPlansBalancedMovesAcrossLocations() throws {
        let edit = InventoryLocationQuantityEdit(
            nameSlug: "ahri",
            quantitiesByLocation: ["box a": 1, "box b": 2, "deck": 3]
        )
        let plan = try InventoryLocationQuantityEditPlanner().makePlan(
            inventory: snapshot(),
            edits: [edit]
        )

        XCTAssertEqual(plan.updates, [
            PlannedInventoryQuantityUpdate(
                inventoryID: "line-a",
                nameSlug: "ahri",
                destinationLocationName: "Box B",
                count: 1
            ),
            PlannedInventoryQuantityUpdate(
                inventoryID: "line-a",
                nameSlug: "ahri",
                destinationLocationName: "Deck",
                count: 1
            ),
        ])
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.movedQuantity, 2)
        XCTAssertEqual(plan.addedQuantity, 0)
        XCTAssertEqual(plan.removedQuantity, 0)
    }

    func testAddsCopiesToAnExistingLocationWithRelativeAdjustment() throws {
        let edit = InventoryLocationQuantityEdit(
            nameSlug: "ahri",
            quantitiesByLocation: ["box a": 3, "box b": 3, "deck": 2]
        )
        let plan = try InventoryLocationQuantityEditPlanner().makePlan(
            inventory: snapshot(),
            edits: [edit]
        )

        XCTAssertEqual(plan.updates, [
            PlannedInventoryQuantityUpdate(
                inventoryID: "line-c",
                nameSlug: "ahri",
                quantityAdjustment: 2
            ),
        ])
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.addedQuantity, 2)
    }

    func testAddsCopiesToANewLocationByAdjustingThenSplittingAStableCarrier() throws {
        let edit = InventoryLocationQuantityEdit(
            nameSlug: "ahri",
            quantitiesByLocation: ["box a": 3, "box b": 1, "deck": 2, "shelf": 2]
        )
        let plan = try InventoryLocationQuantityEditPlanner().makePlan(
            inventory: snapshot(),
            edits: [edit]
        )

        XCTAssertEqual(plan.updates, [
            PlannedInventoryQuantityUpdate(
                inventoryID: "line-a",
                nameSlug: "ahri",
                quantityAdjustment: 2
            ),
            PlannedInventoryQuantityUpdate(
                inventoryID: "line-a",
                nameSlug: "ahri",
                destinationLocationName: "Shelf",
                count: 2
            ),
        ])
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.addedQuantity, 2)
        XCTAssertEqual(plan.movedQuantity, 2)
    }

    func testPartiallyRemovesCopiesWithRelativeAdjustment() throws {
        let edit = InventoryLocationQuantityEdit(
            nameSlug: "ahri",
            quantitiesByLocation: ["box a": 1, "box b": 1, "deck": 2]
        )
        let plan = try InventoryLocationQuantityEditPlanner().makePlan(
            inventory: snapshot(),
            edits: [edit]
        )

        XCTAssertEqual(plan.updates, [
            PlannedInventoryQuantityUpdate(
                inventoryID: "line-a",
                nameSlug: "ahri",
                quantityAdjustment: -2
            ),
        ])
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.removedQuantity, 2)
    }

    func testFullyRemovedLocationBecomesLineDeletion() throws {
        let edit = InventoryLocationQuantityEdit(
            nameSlug: "ahri",
            quantitiesByLocation: ["box a": 0, "box b": 1, "deck": 2]
        )
        let plan = try InventoryLocationQuantityEditPlanner().makePlan(
            inventory: snapshot(),
            edits: [edit]
        )

        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertEqual(plan.deletions, [
            PlannedInventoryLineDeletion(
                inventoryID: "line-a",
                nameSlug: "ahri",
                quantity: 3
            ),
        ])
        XCTAssertEqual(plan.removedQuantity, 3)
    }

    func testRejectsAddingCopiesToUnlocated() {
        let edit = InventoryLocationQuantityEdit(
            nameSlug: "ahri",
            quantitiesByLocation: ["__unlocated__": 2, "box a": 3, "box b": 1, "deck": 2]
        )

        XCTAssertThrowsError(
            try InventoryLocationQuantityEditPlanner().makePlan(
                inventory: snapshot(includingUnlocated: true),
                edits: [edit]
            )
        ) { error in
            XCTAssertEqual(error as? InventoryLocationQuantityEditError, .unlocatedDestination)
        }
    }

    private func snapshot(includingUnlocated: Bool = false) -> AssemblyInventorySnapshot {
        var lines = [
            InventoryLine(
                inventoryID: "line-a",
                productID: 1,
                finish: "Normal",
                quantity: 3,
                locationName: "Box A",
                updatedAt: .distantPast
            ),
            InventoryLine(
                inventoryID: "line-b",
                productID: 1,
                finish: "Normal",
                quantity: 2,
                locationName: "Deck",
                updatedAt: .distantPast
            ),
            InventoryLine(
                inventoryID: "line-c",
                productID: 1,
                finish: "Normal",
                quantity: 1,
                locationName: "Box B",
                updatedAt: .distantPast
            ),
        ]
        if includingUnlocated {
            lines.append(
                InventoryLine(
                    inventoryID: "line-u",
                    productID: 1,
                    finish: "Normal",
                    quantity: 1,
                    locationName: nil,
                    updatedAt: .distantPast
                ))
        }
        return AssemblyInventorySnapshot(
            lines: lines,
            printingsByProductID: [
                1: CardPrinting(
                    productID: 1,
                    nameSlug: "ahri",
                    printingSlug: "ahri-1",
                    displayName: "Ahri"
                ),
            ],
            locationPolicies: [
                LocationPolicy(normalizedName: "box a", displayName: "Box A"),
                LocationPolicy(normalizedName: "box b", displayName: "Box B"),
                LocationPolicy(
                    normalizedName: "deck",
                    displayName: "Deck",
                    kind: .deck,
                    countsAsAvailable: false
                ),
                LocationPolicy(normalizedName: "shelf", displayName: "Shelf"),
            ]
        )
    }
}
