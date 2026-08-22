import Foundation
import XCTest
@testable import RiftBuilderCore

final class DeckAssemblyPlannerTests: XCTestCase {
    func testPlannerUsesOnlyAvailableStoragePrefersRequestedPrintingAndSubtractsDestinationCopies() throws {
        let deck = Deck(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Ahri")
        let entries = [
            DeckEntry(deckID: deck.id, zone: .main, nameSlug: "ahri", quantity: 2, preferredProductID: 2, preferredFinish: "foil", preferredLanguage: "en"),
            DeckEntry(deckID: deck.id, zone: .main, nameSlug: "ahri", quantity: 2),
        ]
        let inventory = snapshot(deckID: deck.id, lines: [
            assemblyLine("destination", productID: 1, quantity: 1, location: "Deck Ahri"),
            assemblyLine("ordinary", productID: 1, quantity: 5, location: "Box A"),
            assemblyLine("preferred", productID: 2, finish: "foil", quantity: 2, location: "Box B"),
            assemblyLine("other-deck", productID: 2, finish: "foil", quantity: 20, location: "Deck Other"),
            assemblyLine("trade", productID: 2, finish: "foil", quantity: 20, location: "Trade"),
        ])
        let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let plan = try DeckAssemblyPlanner().makePlan(AssemblyPlanRequest(
            planID: planID,
            deck: DeckSnapshot(deck: deck, entries: entries, identities: [:]),
            inventory: inventory,
            destinationLocationName: "Deck Ahri"
        ))

        XCTAssertTrue(plan.canFullyAssemble)
        XCTAssertEqual(plan.movements.map(\.inventoryID), ["ordinary", "preferred"])
        XCTAssertEqual(plan.movements.map(\.quantity), [2, 1])
        XCTAssertEqual(plan.movements.reduce(0) { $0 + $1.quantity }, 3)
        XCTAssertEqual(plan.requirements.reduce(0) { $0 + $1.alreadyAtDestination }, 1)
        XCTAssertFalse(plan.movements.contains { ["other-deck", "trade"].contains($0.inventoryID) })
        XCTAssertTrue(plan.movements.allSatisfy { $0.operationID.hasPrefix(planID.uuidString.lowercased()) })
    }

    func testPlannerIsDeterministicAcrossInputOrderingAndReportsShortage() throws {
        let deck = Deck(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Deck")
        let entries = [DeckEntry(deckID: deck.id, zone: .main, nameSlug: "ahri", quantity: 5)]
        let lines = [
            assemblyLine("z", productID: 1, quantity: 1, location: "Box B"),
            assemblyLine("a", productID: 1, quantity: 2, location: "Box A"),
        ]
        let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000088")!
        func plan(_ sourceLines: [InventoryLine]) throws -> AssemblyPlan {
            try DeckAssemblyPlanner().makePlan(AssemblyPlanRequest(
                planID: planID,
                deck: DeckSnapshot(deck: deck, entries: entries, identities: [:]),
                inventory: snapshot(deckID: deck.id, lines: sourceLines),
                destinationLocationName: "Deck Ahri"
            ))
        }
        let forward = try plan(lines)
        let reversed = try plan(Array(lines.reversed()))
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.movements.map(\.inventoryID), ["a", "z"])
        XCTAssertEqual(forward.missingQuantity, 2)
        XCTAssertFalse(forward.canFullyAssemble)
    }

    func testPlannerRequiresDestinationPolicyLinkedToTargetDeck() {
        let deck = Deck(name: "Deck")
        let wrongDeckID = UUID()
        let inventory = AssemblyInventorySnapshot(
            lines: [],
            printingsByProductID: [:],
            locationPolicies: [LocationPolicy(normalizedName: "deck ahri", displayName: "Deck Ahri", kind: .deck, countsAsAvailable: false, linkedDeckID: wrongDeckID)]
        )
        XCTAssertThrowsError(try DeckAssemblyPlanner().makePlan(AssemblyPlanRequest(
            deck: DeckSnapshot(deck: deck, entries: [], identities: [:]),
            inventory: inventory,
            destinationLocationName: "Deck Ahri"
        ))) { error in
            XCTAssertEqual(error as? AssemblyPlanningError, .destinationLocationNotLinkedToDeck("Deck Ahri", deck.id))
        }
    }
}

private func snapshot(deckID: UUID, lines: [InventoryLine]) -> AssemblyInventorySnapshot {
    AssemblyInventorySnapshot(
        lines: lines,
        printingsByProductID: [
            1: CardPrinting(productID: 1, nameSlug: "ahri", printingSlug: "ahri-1", displayName: "Ahri"),
            2: CardPrinting(productID: 2, nameSlug: "ahri", printingSlug: "ahri-2", displayName: "Ahri"),
        ],
        locationPolicies: [
            LocationPolicy(normalizedName: "box a", displayName: "Box A", kind: .storage, countsAsAvailable: true),
            LocationPolicy(normalizedName: "box b", displayName: "Box B", kind: .storage, countsAsAvailable: true),
            LocationPolicy(normalizedName: "deck ahri", displayName: "Deck Ahri", kind: .deck, countsAsAvailable: false, linkedDeckID: deckID),
            LocationPolicy(normalizedName: "deck other", displayName: "Deck Other", kind: .deck, countsAsAvailable: false, linkedDeckID: UUID()),
            LocationPolicy(normalizedName: "trade", displayName: "Trade", kind: .unavailable, countsAsAvailable: false),
        ]
    )
}

private func assemblyLine(_ id: String, productID: Int64, finish: String = "normal", quantity: Int, location: String) -> InventoryLine {
    InventoryLine(
        inventoryID: id,
        productID: productID,
        finish: finish,
        language: "en",
        quantity: quantity,
        locationName: location,
        updatedAt: Date(timeIntervalSince1970: 1)
    )
}
