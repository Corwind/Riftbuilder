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
        XCTAssertTrue(plan.canApply)
    }

    func testDisassemblyDefaultsEachOriginLotToItsPreviousStorageLocation() throws {
        let deckID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let boxAID = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
        let boxBID = UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!
        let inventory = disassemblyInventory(deckID: deckID, lines: [disassemblyLine("merged", productID: 1, quantity: 2, location: "Deck Ahri")])
        let origins = [
            disassemblyOrigin(id: boxBID, deckID: deckID, location: "Box B"),
            disassemblyOrigin(id: boxAID, deckID: deckID, location: "Box A"),
        ]

        let plan = try DeckDisassemblyPlanner().makePlan(DisassemblyPlanRequest(
            deckID: deckID,
            inventory: inventory,
            sourceDeckLocationName: "Deck Ahri",
            originLots: origins
        ))

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.returnRoutes.map(\.destinationLocationName), ["Box A", "Box B"])
        XCTAssertEqual(plan.movements.map(\.inventoryID), ["merged", "merged"])
        XCTAssertEqual(plan.movements.map(\.destinationLocationName), ["Box A", "Box B"])
        XCTAssertEqual(Set(plan.movements.compactMap(\.originLotID)), [boxAID, boxBID])
    }

    func testDisassemblyOriginDestinationCanBeOverriddenAndLegacyInventoryNeedsFallback() throws {
        let deckID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let origin = disassemblyOrigin(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000c")!, deckID: deckID, location: "Box A")
        let inventory = disassemblyInventory(deckID: deckID, lines: [
            disassemblyLine("remembered", productID: 1, quantity: 1, location: "Deck Ahri"),
            disassemblyLine("legacy", productID: 2, quantity: 1, location: "Deck Ahri"),
        ])
        let rememberedRequirement = DeckPhysicalRequirementKey(nameSlug: "ahri", preference: PrintingPreference(productID: 1, finish: "normal"))
        let legacyRequirement = DeckPhysicalRequirementKey(nameSlug: "jinx", preference: PrintingPreference(productID: 2, finish: "normal"))

        let unresolved = try DeckDisassemblyPlanner().makePlan(DisassemblyPlanRequest(
            deckID: deckID,
            inventory: inventory,
            sourceDeckLocationName: "Deck Ahri",
            removalDestinations: [DeckRemovalDestination(requirement: rememberedRequirement, originLotID: origin.id, locationName: "Box B")],
            originLots: [origin]
        ))
        XCTAssertFalse(unresolved.canApply)
        XCTAssertEqual(unresolved.returnRoutes.first { $0.key.originLotID == origin.id }?.destinationLocationName, "Box B")
        XCTAssertTrue(unresolved.unresolvedReturnRoutes.contains(DeckReturnRouteKey(requirement: legacyRequirement, originLotID: nil)))

        let resolved = try DeckDisassemblyPlanner().makePlan(DisassemblyPlanRequest(
            deckID: deckID,
            inventory: inventory,
            sourceDeckLocationName: "Deck Ahri",
            destinationStorageLocationName: "Box A",
            removalDestinations: [DeckRemovalDestination(requirement: rememberedRequirement, originLotID: origin.id, locationName: "Box B")],
            originLots: [origin]
        ))
        XCTAssertTrue(resolved.canApply)
        XCTAssertEqual(Set(resolved.movements.map(\.destinationLocationName)), ["Box A", "Box B"])
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

private func disassemblyInventory(deckID: UUID, lines: [InventoryLine]) -> AssemblyInventorySnapshot {
    AssemblyInventorySnapshot(
        lines: lines,
        printingsByProductID: [
            1: CardPrinting(productID: 1, nameSlug: "ahri", printingSlug: "a", displayName: "Ahri"),
            2: CardPrinting(productID: 2, nameSlug: "jinx", printingSlug: "j", displayName: "Jinx"),
        ],
        locationPolicies: [
            LocationPolicy(normalizedName: "deck ahri", displayName: "Deck Ahri", kind: .deck, countsAsAvailable: false, linkedDeckID: deckID),
            LocationPolicy(normalizedName: "box a", displayName: "Box A", kind: .storage, countsAsAvailable: true),
            LocationPolicy(normalizedName: "box b", displayName: "Box B", kind: .storage, countsAsAvailable: true),
        ]
    )
}

private func disassemblyOrigin(id: UUID, deckID: UUID, location: String) -> DeckCardOriginLot {
    DeckCardOriginLot(
        id: id,
        deckID: deckID,
        nameSlug: "ahri",
        productID: 1,
        finish: "normal",
        previousLocationKey: InventoryLocation.normalize(location),
        previousLocationName: location,
        quantity: 1,
        createdAt: .distantPast
    )
}
