import Foundation
import XCTest
@testable import RiftBuilderCore

final class DeckSavePlannerBehaviorTests: XCTestCase {
    func testAddedCardsArePickedDeterministicallyFromAvailableBoxes() throws {
        let fixture = SavePlanFixture(saved: [], draft: [entry("ahri", quantity: 3)])
        let inventory = fixture.inventory(lines: [
            line("box-b", productID: 1, quantity: 2, location: "Box B"),
            line("box-a", productID: 1, quantity: 2, location: "Box A"),
            line("trade", productID: 1, quantity: 20, location: "Trade"),
            line("other-deck", productID: 1, quantity: 20, location: "Other Deck"),
        ])

        let plan = try fixture.plan(inventory: inventory)

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.movements.map(\.inventoryID), ["box-a", "box-b"])
        XCTAssertEqual(plan.movements.map(\.quantity), [2, 1])
        XCTAssertEqual(plan.movements.map(\.sourceLocationName), ["Box A", "Box B"])
        XCTAssertTrue(plan.movements.allSatisfy { $0.destinationLocationName == "Deck Ezreal" })
        XCTAssertFalse(plan.movements.contains { ["trade", "other-deck"].contains($0.inventoryID) })
    }

    func testRemovedCardsWaitForDestinationBeforeAnyMoveIsProposed() throws {
        let fixture = SavePlanFixture(saved: [entry("ahri", quantity: 3)], draft: [entry("ahri", quantity: 1)])
        let inventory = fixture.inventory(lines: [line("deck-ahri", productID: 1, quantity: 3, location: "Deck Ezreal")])

        let plan = try fixture.plan(inventory: inventory)

        XCTAssertFalse(plan.canApply)
        XCTAssertEqual(plan.unresolvedRemovalDestinations.map(\.nameSlug), ["ahri"])
        XCTAssertTrue(plan.movements.isEmpty)
        XCTAssertEqual(plan.requirements.first?.requested, 2)
        XCTAssertNil(plan.requirements.first?.destinationLocationName)
    }

    func testRemovedCardsMoveFromDeckToChosenBox() throws {
        let requirement = DeckPhysicalRequirementKey(nameSlug: "ahri")
        let fixture = SavePlanFixture(saved: [entry("ahri", quantity: 3)], draft: [entry("ahri", quantity: 1)])
        let inventory = fixture.inventory(lines: [line("deck-ahri", productID: 1, quantity: 3, location: "Deck Ezreal")])

        let plan = try fixture.plan(
            inventory: inventory,
            destinations: [DeckRemovalDestination(requirement: requirement, locationName: "Box B")]
        )

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.movements.count, 1)
        XCTAssertEqual(plan.movements.first?.inventoryID, "deck-ahri")
        XCTAssertEqual(plan.movements.first?.quantity, 2)
        XCTAssertEqual(plan.movements.first?.sourceLocationName, "Deck Ezreal")
        XCTAssertEqual(plan.movements.first?.destinationLocationName, "Box B")
    }

    func testRemovedCardDefaultsToItsRememberedPreviousLocation() throws {
        let fixture = SavePlanFixture(saved: [entry("ahri", quantity: 2)], draft: [entry("ahri", quantity: 1)])
        let remembered = origin(deckID: fixtureDeckID, nameSlug: "ahri", productID: 1, location: "Box A", quantity: 1)

        let plan = try fixture.plan(
            inventory: fixture.inventory(lines: [line("merged-deck-ahri", productID: 1, quantity: 2, location: "Deck Ezreal")]),
            originLots: [remembered]
        )

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.returnRoutes, [DeckReturnRoute(
            key: DeckReturnRouteKey(requirement: DeckPhysicalRequirementKey(nameSlug: "ahri"), originLotID: remembered.id),
            quantity: 1,
            previousLocationName: "Box A",
            destinationLocationName: "Box A"
        )])
        XCTAssertEqual(plan.movements.first?.destinationLocationName, "Box A")
        XCTAssertEqual(plan.movements.first?.originLotID, remembered.id)
    }

    func testRememberedPreviousLocationCanBeOverridden() throws {
        let requirement = DeckPhysicalRequirementKey(nameSlug: "ahri")
        let fixture = SavePlanFixture(saved: [entry("ahri", quantity: 2)], draft: [entry("ahri", quantity: 1)])
        let remembered = origin(deckID: fixtureDeckID, nameSlug: "ahri", productID: 1, location: "Box A", quantity: 1)

        let plan = try fixture.plan(
            inventory: fixture.inventory(lines: [line("deck-ahri", productID: 1, quantity: 2, location: "Deck Ezreal")]),
            destinations: [DeckRemovalDestination(requirement: requirement, originLotID: remembered.id, locationName: "Box B")],
            originLots: [remembered]
        )

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.returnRoutes.first?.previousLocationName, "Box A")
        XCTAssertEqual(plan.returnRoutes.first?.destinationLocationName, "Box B")
        XCTAssertEqual(plan.movements.first?.destinationLocationName, "Box B")
        XCTAssertEqual(plan.movements.first?.originLotID, remembered.id)
    }

    func testMergedDeckLineIsSplitAcrossRememberedSourceLocations() throws {
        let fixture = SavePlanFixture(saved: [entry("ahri", quantity: 2)], draft: [])
        let boxA = origin(deckID: fixtureDeckID, id: UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!, nameSlug: "ahri", productID: 1, location: "Box A", quantity: 1)
        let boxB = origin(deckID: fixtureDeckID, id: UUID(uuidString: "00000000-0000-0000-0000-00000000000b")!, nameSlug: "ahri", productID: 1, location: "Box B", quantity: 1)

        let plan = try fixture.plan(
            inventory: fixture.inventory(lines: [line("merged-deck-ahri", productID: 1, quantity: 2, location: "Deck Ezreal")]),
            originLots: [boxB, boxA]
        )

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.returnRoutes.map(\.destinationLocationName), ["Box A", "Box B"])
        XCTAssertEqual(plan.movements.map(\.inventoryID), ["merged-deck-ahri", "merged-deck-ahri"])
        XCTAssertEqual(plan.movements.map(\.destinationLocationName), ["Box A", "Box B"])
        XCTAssertEqual(Set(plan.movements.compactMap(\.originLotID)), [boxA.id, boxB.id])
    }

    func testUnavailableRememberedLocationRequiresSelectableFallback() throws {
        let requirement = DeckPhysicalRequirementKey(nameSlug: "ahri")
        let fixture = SavePlanFixture(saved: [entry("ahri", quantity: 1)], draft: [])
        let remembered = origin(deckID: fixtureDeckID, nameSlug: "ahri", productID: 1, location: "Trade", quantity: 1)
        let inventory = fixture.inventory(lines: [line("deck-ahri", productID: 1, quantity: 1, location: "Deck Ezreal")])

        let unresolved = try fixture.plan(inventory: inventory, originLots: [remembered])
        XCTAssertFalse(unresolved.canApply)
        XCTAssertEqual(unresolved.unresolvedReturnRoutes, [DeckReturnRouteKey(requirement: requirement, originLotID: remembered.id)])
        XCTAssertEqual(unresolved.returnRoutes.first?.previousLocationName, "Trade")
        XCTAssertNil(unresolved.returnRoutes.first?.destinationLocationName)

        let resolved = try fixture.plan(
            inventory: inventory,
            destinations: [DeckRemovalDestination(requirement: requirement, originLotID: remembered.id, locationName: "Box B")],
            originLots: [remembered]
        )
        XCTAssertTrue(resolved.canApply)
        XCTAssertEqual(resolved.movements.first?.destinationLocationName, "Box B")
    }

    func testOneSavePlanCanPickAdditionsAndReturnRemovals() throws {
        let fixture = SavePlanFixture(
            saved: [entry("ahri", quantity: 3)],
            draft: [entry("ahri", quantity: 1), entry("vex", quantity: 2)]
        )
        let inventory = fixture.inventory(lines: [
            line("deck-ahri", productID: 1, quantity: 3, location: "Deck Ezreal"),
            line("box-vex", productID: 2, quantity: 2, location: "Box A"),
        ])

        let plan = try fixture.plan(
            inventory: inventory,
            destinations: [DeckRemovalDestination(requirement: DeckPhysicalRequirementKey(nameSlug: "ahri"), locationName: "Box B")]
        )

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(Set(plan.movements.map(\.inventoryID)), ["deck-ahri", "box-vex"])
        XCTAssertEqual(plan.requirements.map(\.direction), [.outOfDeck, .intoDeck])
        XCTAssertEqual(plan.requirements.map(\.requested), [2, 2])
    }

    func testZoneOnlyChangesAndRunesNeverMovePhysicalInventory() throws {
        let fixture = SavePlanFixture(
            saved: [entry("ahri", zone: .main, quantity: 1), entry("mind-rune", zone: .rune, quantity: 5)],
            draft: [entry("ahri", zone: .sideboard, quantity: 1), entry("mind-rune", zone: .rune, quantity: 12)]
        )

        let plan = try fixture.plan(inventory: fixture.inventory(lines: [
            line("deck-ahri", productID: 1, quantity: 1, location: "Deck Ezreal"),
        ]))

        XCTAssertTrue(plan.canApply)
        XCTAssertTrue(plan.movements.isEmpty)
        XCTAssertTrue(plan.requirements.isEmpty)
    }

    func testMovingExplicitChosenChampionToGenericMainDeckDoesNotMoveInventory() throws {
        let chosenChampion = DeckEntry(
            deckID: fixtureDeckID,
            zone: .chosenChampion,
            nameSlug: "ahri",
            quantity: 1,
            preferredProductID: 1,
            preferredFinish: "normal",
            preferredLanguage: "en"
        )
        let fixture = SavePlanFixture(
            saved: [chosenChampion],
            draft: [entry("ahri", zone: .main, quantity: 1)]
        )

        let plan = try fixture.plan(
            inventory: fixture.inventory(lines: [line("deck-ahri", productID: 1, quantity: 1, location: "Deck Ezreal")])
        )

        XCTAssertTrue(plan.canApply)
        XCTAssertTrue(plan.movements.isEmpty)
        XCTAssertTrue(plan.requirements.isEmpty)
        XCTAssertTrue(plan.returnRoutes.isEmpty)
    }

    func testPhysicalDriftIsReconciledEvenWhenDraftMatchesSavedDefinition() throws {
        let fixture = SavePlanFixture(
            saved: [entry("ahri", quantity: 2)],
            draft: [entry("ahri", quantity: 2)]
        )
        let inventory = fixture.inventory(lines: [
            line("deck-ahri", productID: 1, quantity: 1, location: "Deck Ezreal"),
            line("box-ahri", productID: 1, quantity: 1, location: "Box A"),
        ])

        let plan = try fixture.plan(inventory: inventory)

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.movements.map(\.inventoryID), ["box-ahri"])
        XCTAssertEqual(plan.movements.map(\.quantity), [1])
        XCTAssertEqual(plan.requirements.first?.requested, 1)
    }

    func testBuildDoesNotReturnPhysicalExtrasWhenDefinitionIsUnchanged() throws {
        let fixture = SavePlanFixture(
            saved: [entry("ahri", quantity: 1), entry("mind-rune", zone: .rune, quantity: 2)],
            draft: [entry("ahri", quantity: 1), entry("mind-rune", zone: .rune, quantity: 2)]
        )
        let inventory = fixture.inventory(lines: [
            line("deck-ahri", productID: 1, quantity: 2, location: "Deck Ezreal"),
            line("deck-runes", productID: 4, quantity: 2, location: "Deck Ezreal"),
        ])

        let plan = try fixture.plan(inventory: inventory)

        XCTAssertTrue(plan.canApply)
        XCTAssertTrue(plan.movements.isEmpty)
        XCTAssertTrue(plan.requirements.isEmpty)
        XCTAssertTrue(plan.returnRoutes.isEmpty)
    }

    func testMovingExplicitMainDeckCardToGenericChosenChampionDoesNotMoveInventory() throws {
        let mainCard = DeckEntry(
            deckID: fixtureDeckID,
            zone: .main,
            nameSlug: "ahri",
            quantity: 1,
            preferredProductID: 1,
            preferredFinish: "normal",
            preferredLanguage: "en"
        )
        let fixture = SavePlanFixture(
            saved: [mainCard],
            draft: [entry("ahri", zone: .chosenChampion, quantity: 1)]
        )

        let plan = try fixture.plan(
            inventory: fixture.inventory(lines: [line("deck-ahri", productID: 1, quantity: 1, location: "Deck Ezreal")])
        )

        XCTAssertTrue(plan.canApply)
        XCTAssertTrue(plan.movements.isEmpty)
        XCTAssertTrue(plan.requirements.isEmpty)
        XCTAssertTrue(plan.returnRoutes.isEmpty)
    }

    func testZoneAndPreferenceChangeWithNetAdditionOnlyMovesTheAddedCopyIntoDeck() throws {
        let chosenChampion = DeckEntry(
            deckID: fixtureDeckID,
            zone: .chosenChampion,
            nameSlug: "ahri",
            quantity: 1,
            preferredProductID: 1,
            preferredFinish: "normal",
            preferredLanguage: "en"
        )
        let fixture = SavePlanFixture(
            saved: [chosenChampion],
            draft: [entry("ahri", zone: .main, quantity: 2)]
        )

        let plan = try fixture.plan(inventory: fixture.inventory(lines: [
            line("deck-ahri", productID: 1, quantity: 1, location: "Deck Ezreal"),
            line("box-ahri", productID: 1, quantity: 1, location: "Box A"),
        ]))

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.movements.count, 1)
        XCTAssertEqual(plan.movements.first?.inventoryID, "box-ahri")
        XCTAssertEqual(plan.movements.first?.quantity, 1)
        XCTAssertEqual(plan.movements.first?.destinationLocationName, "Deck Ezreal")
        XCTAssertEqual(plan.requirements.map(\.direction), [.intoDeck])
        XCTAssertEqual(plan.requirements.map(\.requested), [1])
        XCTAssertTrue(plan.returnRoutes.isEmpty)
    }

    func testZoneAndPreferenceChangeWithNetRemovalOnlyReturnsTheRemovedCopy() throws {
        let chosenChampion = DeckEntry(
            deckID: fixtureDeckID,
            zone: .chosenChampion,
            nameSlug: "ahri",
            quantity: 2,
            preferredProductID: 1,
            preferredFinish: "normal",
            preferredLanguage: "en"
        )
        let fixture = SavePlanFixture(
            saved: [chosenChampion],
            draft: [entry("ahri", zone: .main, quantity: 1)]
        )
        let requirement = DeckPhysicalRequirementKey(
            nameSlug: "ahri",
            preference: PrintingPreference(productID: 1, finish: "normal", language: "en")
        )

        let plan = try fixture.plan(
            inventory: fixture.inventory(lines: [line("deck-ahri", productID: 1, quantity: 2, location: "Deck Ezreal")]),
            destinations: [DeckRemovalDestination(requirement: requirement, locationName: "Box A")]
        )

        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.movements.count, 1)
        XCTAssertEqual(plan.movements.first?.inventoryID, "deck-ahri")
        XCTAssertEqual(plan.movements.first?.quantity, 1)
        XCTAssertEqual(plan.movements.first?.destinationLocationName, "Box A")
        XCTAssertEqual(plan.requirements.map(\.direction), [.outOfDeck])
        XCTAssertEqual(plan.requirements.map(\.requested), [1])
    }

    func testAlwaysAvailableBattlefieldsDoNotCreateSaveMovements() throws {
        let fixture = SavePlanFixture(
            saved: [],
            draft: [entry("spirit-realm", zone: .battlefield, quantity: 3)]
        )

        let plan = try fixture.plan(inventory: fixture.inventory(lines: []))

        XCTAssertTrue(plan.canApply)
        XCTAssertTrue(plan.movements.isEmpty)
        XCTAssertTrue(plan.requirements.isEmpty)
    }

    func testDisabledSupplyOptionsRestorePhysicalSaveRequirements() throws {
        let fixture = SavePlanFixture(
            saved: [],
            draft: [
                entry("mind-rune", zone: .rune, quantity: 2),
                entry("spirit-realm", zone: .battlefield, quantity: 3),
            ]
        )

        let plan = try fixture.plan(
            inventory: fixture.inventory(lines: []),
            inventoryAvailability: DeckInventoryAvailability(alwaysAvailableRunes: false, alwaysAvailableBattlefields: false)
        )

        XCTAssertEqual(plan.requirements.map(\.requirement.nameSlug), ["mind-rune", "spirit-realm"])
        XCTAssertEqual(plan.missingQuantity, 5)
        XCTAssertFalse(plan.canApply)
    }

    func testShortagePreventsApplyingDraftAndExplainsMissingQuantity() throws {
        let fixture = SavePlanFixture(saved: [], draft: [entry("vex", quantity: 3)])
        let inventory = fixture.inventory(lines: [line("only-vex", productID: 2, quantity: 1, location: "Box A")])

        let plan = try fixture.plan(inventory: inventory)

        XCTAssertFalse(plan.canApply)
        XCTAssertEqual(plan.missingQuantity, 2)
        XCTAssertEqual(plan.requirements.first?.allocated, 1)
        XCTAssertEqual(plan.requirements.first?.missing, 2)
    }

    func testUnavailableOrDeckRemovalDestinationIsRejected() throws {
        let requirement = DeckPhysicalRequirementKey(nameSlug: "ahri")
        let fixture = SavePlanFixture(saved: [entry("ahri", quantity: 1)], draft: [])
        let inventory = fixture.inventory(lines: [line("deck-ahri", productID: 1, quantity: 1, location: "Deck Ezreal")])

        XCTAssertThrowsError(try fixture.plan(
            inventory: inventory,
            destinations: [DeckRemovalDestination(requirement: requirement, locationName: "Trade")]
        )) { error in
            XCTAssertEqual(error as? DeckSavePlanningError, .removalDestinationNotAvailableStorage("Trade"))
        }
        XCTAssertThrowsError(try fixture.plan(
            inventory: inventory,
            destinations: [DeckRemovalDestination(requirement: requirement, locationName: "Deck Ezreal")]
        )) { error in
            XCTAssertEqual(error as? DeckSavePlanningError, .removalDestinationIsDeckLocation("Deck Ezreal"))
        }
    }

    func testRequestedPrintingIsPickedBeforeFallbackPrinting() throws {
        let preferred = DeckEntry(deckID: fixtureDeckID, zone: .main, nameSlug: "ahri", quantity: 1, preferredProductID: 3, preferredFinish: "foil", preferredLanguage: "en")
        let fixture = SavePlanFixture(saved: [], draft: [preferred])
        let inventory = fixture.inventory(lines: [
            line("ordinary", productID: 1, quantity: 1, location: "Box A"),
            line("preferred", productID: 3, finish: "foil", quantity: 1, location: "Box B"),
        ])

        let plan = try fixture.plan(inventory: inventory)

        XCTAssertEqual(plan.movements.map(\.inventoryID), ["preferred"])
    }
}

private let fixtureDeckID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!

private struct SavePlanFixture {
    let deck: Deck
    let saved: DeckSnapshot
    let draft: DeckDraftSnapshot

    init(saved savedEntries: [DeckEntry], draft draftEntries: [DeckEntry]) {
        deck = Deck(id: fixtureDeckID, name: "Ezreal")
        saved = DeckSnapshot(deck: deck, entries: savedEntries, identities: [:])
        draft = DeckDraftSnapshot(deck: deck, entries: draftEntries, identities: [:], baseDeckUpdatedAt: .distantPast, createdAt: .distantPast, updatedAt: .distantPast)
    }

    func inventory(lines: [InventoryLine]) -> AssemblyInventorySnapshot {
        AssemblyInventorySnapshot(
            lines: lines,
            printingsByProductID: [
                1: CardPrinting(productID: 1, nameSlug: "ahri", printingSlug: "ahri-normal", displayName: "Ahri"),
                2: CardPrinting(productID: 2, nameSlug: "vex", printingSlug: "vex-normal", displayName: "Vex"),
                3: CardPrinting(productID: 3, nameSlug: "ahri", printingSlug: "ahri-foil", displayName: "Ahri"),
                4: CardPrinting(productID: 4, nameSlug: "mind-rune", printingSlug: "mind-rune-normal", displayName: "Mind Rune"),
                5: CardPrinting(productID: 5, nameSlug: "spirit-realm", printingSlug: "spirit-realm-normal", displayName: "Spirit Realm"),
            ],
            locationPolicies: [
                LocationPolicy(normalizedName: "deck ezreal", displayName: "Deck Ezreal", kind: .deck, countsAsAvailable: false, linkedDeckID: fixtureDeckID),
                LocationPolicy(normalizedName: "other deck", displayName: "Other Deck", kind: .deck, countsAsAvailable: false, linkedDeckID: UUID()),
                LocationPolicy(normalizedName: "box a", displayName: "Box A", kind: .storage, countsAsAvailable: true),
                LocationPolicy(normalizedName: "box b", displayName: "Box B", kind: .storage, countsAsAvailable: true),
                LocationPolicy(normalizedName: "trade", displayName: "Trade", kind: .unavailable, countsAsAvailable: false),
            ]
        )
    }

    func plan(inventory: AssemblyInventorySnapshot, destinations: [DeckRemovalDestination] = [], inventoryAvailability: DeckInventoryAvailability = DeckInventoryAvailability(), originLots: [DeckCardOriginLot] = []) throws -> DeckSavePlan {
        try DeckSavePlanner().makePlan(DeckSavePlanRequest(
            planID: UUID(uuidString: "00000000-0000-0000-0000-000000000999")!,
            savedDeck: saved,
            draft: draft,
            inventory: inventory,
            deckLocationName: "Deck Ezreal",
            removalDestinations: destinations,
            inventoryAvailability: inventoryAvailability,
            originLots: originLots
        ))
    }
}

private func entry(_ slug: String, zone: DeckZone = .main, quantity: Int) -> DeckEntry {
    DeckEntry(deckID: fixtureDeckID, zone: zone, nameSlug: slug, quantity: quantity)
}

private func line(_ id: String, productID: Int64, finish: String = "normal", quantity: Int, location: String) -> InventoryLine {
    InventoryLine(inventoryID: id, productID: productID, finish: finish, language: "en", quantity: quantity, locationName: location, updatedAt: .distantPast)
}

private func origin(deckID: UUID, id: UUID = UUID(), nameSlug: String, productID: Int64, location: String, quantity: Int) -> DeckCardOriginLot {
    DeckCardOriginLot(
        id: id,
        deckID: deckID,
        nameSlug: nameSlug,
        productID: productID,
        finish: "normal",
        language: "en",
        previousLocationKey: InventoryLocation.normalize(location),
        previousLocationName: location,
        quantity: quantity,
        createdAt: .distantPast
    )
}
