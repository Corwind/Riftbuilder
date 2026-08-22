import Foundation
import XCTest
@testable import RiftBuilderCore

final class UnlimitedRuneAssemblyTests: XCTestCase {
    func testTwelveRunesNeedNoInventoryAndDoNotChangeNonRuneAllocation() throws {
        let deckID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let deck = Deck(id: deckID, name: "Rune Test")
        let snapshot = DeckSnapshot(
            deck: deck,
            entries: [
                DeckEntry(deckID: deckID, zone: .rune, nameSlug: "fury-rune", quantity: 12),
                DeckEntry(deckID: deckID, zone: .main, nameSlug: "ahri", quantity: 2),
            ],
            identities: [:]
        )
        let inventory = AssemblyInventorySnapshot(
            lines: [InventoryLine(
                inventoryID: "ahri-box-line",
                productID: 101,
                finish: "normal",
                language: "en",
                quantity: 2,
                locationName: "Box A",
                updatedAt: Date(timeIntervalSince1970: 1)
            )],
            printingsByProductID: [
                101: CardPrinting(productID: 101, nameSlug: "ahri", printingSlug: "ahri-101", displayName: "Ahri"),
            ],
            locationPolicies: [
                LocationPolicy(normalizedName: "box a", displayName: "Box A", kind: .storage, countsAsAvailable: true),
                LocationPolicy(normalizedName: "deck rune test", displayName: "Deck Rune Test", kind: .deck, countsAsAvailable: false, linkedDeckID: deckID),
            ]
        )

        let plan = try DeckAssemblyPlanner().makePlan(AssemblyPlanRequest(
            planID: planID,
            deck: snapshot,
            inventory: inventory,
            destinationLocationName: "Deck Rune Test"
        ))

        XCTAssertEqual(plan.requirements.map(\.nameSlug), ["ahri"])
        XCTAssertFalse(plan.requirements.contains { $0.nameSlug == "fury-rune" })
        XCTAssertEqual(plan.missingQuantity, 0)
        XCTAssertEqual(plan.movements.map(\.inventoryID), ["ahri-box-line"])
        XCTAssertEqual(plan.movements.map(\.quantity), [2])
        XCTAssertTrue(plan.canFullyAssemble)
    }

    func testRuneOnlyDeckProducesNoRequirementShortageOrMovementWithEmptyInventory() throws {
        let deckID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
        let deck = Deck(id: deckID, name: "Runes Only")
        let inventory = AssemblyInventorySnapshot(
            lines: [],
            printingsByProductID: [:],
            locationPolicies: [
                LocationPolicy(normalizedName: "deck runes", displayName: "Deck Runes", kind: .deck, countsAsAvailable: false, linkedDeckID: deckID),
            ]
        )

        let plan = try DeckAssemblyPlanner().makePlan(AssemblyPlanRequest(
            deck: DeckSnapshot(
                deck: deck,
                entries: [DeckEntry(deckID: deckID, zone: .rune, nameSlug: "calm-rune", quantity: 12)],
                identities: [:]
            ),
            inventory: inventory,
            destinationLocationName: "Deck Runes"
        ))

        XCTAssertTrue(plan.requirements.isEmpty)
        XCTAssertTrue(plan.movements.isEmpty)
        XCTAssertEqual(plan.missingQuantity, 0)
        XCTAssertTrue(plan.canFullyAssemble)
    }
}
