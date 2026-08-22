import Foundation
import XCTest
@testable import RiftBuilderCore

final class DeckDisassemblyPlannerTests: XCTestCase {
    func testDisassemblyMovesEveryDeckLocationLineToExplicitStorageAndNothingElse() throws {
        let deckID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let inventory = AssemblyInventorySnapshot(
            lines: [
                disassemblyLine("b", productID: 2, quantity: 2, location: "Deck Ahri"),
                disassemblyLine("a", productID: 1, quantity: 3, location: "deck ahri"),
                disassemblyLine("box", productID: 1, quantity: 9, location: "Box A"),
            ],
            printingsByProductID: [
                1: CardPrinting(productID: 1, nameSlug: "ahri", printingSlug: "a", displayName: "Ahri"),
                2: CardPrinting(productID: 2, nameSlug: "jinx", printingSlug: "j", displayName: "Jinx"),
            ],
            locationPolicies: [
                LocationPolicy(normalizedName: "deck ahri", displayName: "Deck Ahri", kind: .deck, countsAsAvailable: false, linkedDeckID: deckID),
                LocationPolicy(normalizedName: "box a", displayName: "Box A", kind: .storage, countsAsAvailable: true),
            ]
        )
        let plan = try DeckDisassemblyPlanner().makePlan(DisassemblyPlanRequest(
            deckID: deckID,
            inventory: inventory,
            sourceDeckLocationName: "Deck Ahri",
            destinationStorageLocationName: "Box A"
        ))
        XCTAssertEqual(plan.movements.map(\.inventoryID), ["a", "b"])
        XCTAssertEqual(plan.movements.map(\.quantity), [3, 2])
        XCTAssertTrue(plan.movements.allSatisfy { $0.destinationLocationName == "Box A" })
    }

    func testDisassemblyRejectsNonStorageDestination() {
        let deckID = UUID()
        let inventory = AssemblyInventorySnapshot(
            lines: [],
            printingsByProductID: [:],
            locationPolicies: [
                LocationPolicy(normalizedName: "deck", displayName: "Deck", kind: .deck, countsAsAvailable: false, linkedDeckID: deckID),
                LocationPolicy(normalizedName: "trade", displayName: "Trade", kind: .unavailable, countsAsAvailable: false),
            ]
        )
        XCTAssertThrowsError(try DeckDisassemblyPlanner().makePlan(DisassemblyPlanRequest(
            deckID: deckID,
            inventory: inventory,
            sourceDeckLocationName: "Deck",
            destinationStorageLocationName: "Trade"
        ))) { error in
            XCTAssertEqual(error as? DisassemblyPlanningError, .destinationIsNotStorage("Trade"))
        }
    }
}

private func disassemblyLine(_ id: String, productID: Int64, quantity: Int, location: String) -> InventoryLine {
    InventoryLine(inventoryID: id, productID: productID, finish: "normal", quantity: quantity, locationName: location, updatedAt: .now)
}
