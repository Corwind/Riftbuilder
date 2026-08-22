import Foundation
import XCTest
@testable import RiftBuilderCore

final class RepositoryTests: XCTestCase {
    func testDeckLocationLinksAreOneToOneAndOnlyDeckLocationsCanLink() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        let deck = Deck(name: "Ahri")
        try await repository.saveDeck(deck)
        try await repository.saveLocationPolicy(LocationPolicy(
            normalizedName: "deck a",
            displayName: "Deck A",
            kind: .deck,
            countsAsAvailable: false,
            linkedDeckID: deck.id
        ))

        do {
            try await repository.saveLocationPolicy(LocationPolicy(
                normalizedName: "deck b",
                displayName: "Deck B",
                kind: .deck,
                countsAsAvailable: false,
                linkedDeckID: deck.id
            ))
            XCTFail("Expected one-to-one deck location enforcement")
        } catch let error as LocationPolicyPersistenceError {
            XCTAssertEqual(error, .deckAlreadyLinked(deckID: deck.id, locationName: "Deck A"))
        }

        do {
            try await repository.saveLocationPolicy(LocationPolicy(
                normalizedName: "box",
                displayName: "Box",
                kind: .storage,
                countsAsAvailable: true,
                linkedDeckID: deck.id
            ))
            XCTFail("Expected linked storage rejection")
        } catch let error as LocationPolicyPersistenceError {
            XCTAssertEqual(error, .linkedDeckRequiresDeckClassification)
        }
    }

    func testImportDeckSnapshotAndLocationLinkAreCommittedAtomically() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        let printing = CardPrinting(productID: 1, nameSlug: "ahri", printingSlug: "ahri-1", displayName: "Ahri")
        try await repository.replaceCatalogue(printings: [printing], checksum: "catalogue", completedAt: .distantPast)
        try await repository.synchronizeInventory(
            lines: [InventoryLine(inventoryID: "deck-line", productID: 1, finish: "normal", quantity: 1, locationName: "Scanned Deck", updatedAt: .distantPast)],
            locations: [InventoryLocation(name: "Scanned Deck")],
            generation: UUID(),
            completedAt: .distantPast
        )
        try await repository.saveLocationPolicy(LocationPolicy(normalizedName: "scanned deck", displayName: "Scanned Deck", kind: .deck, countsAsAvailable: false))
        let deck = Deck(name: "Imported", state: .assembled)
        let snapshot = DeckSnapshot(
            deck: deck,
            entries: [DeckEntry(deckID: deck.id, zone: .main, nameSlug: "ahri", quantity: 1, preferredProductID: 1, preferredFinish: "normal")],
            identities: [:]
        )

        try await repository.importDeckSnapshot(snapshot, fromLocationKey: "scanned deck")

        let importedSnapshot = try await repository.deckSnapshot(id: deck.id)
        let linkedPolicies = try await repository.locationPolicies()
        XCTAssertEqual(importedSnapshot?.entries.first?.nameSlug, "ahri")
        XCTAssertEqual(linkedPolicies.first { $0.normalizedName == "scanned deck" }?.linkedDeckID, deck.id)

        let rejectedDeck = Deck(name: "Duplicate Import", state: .assembled)
        let rejectedSnapshot = DeckSnapshot(deck: rejectedDeck, entries: [], identities: [:])
        do {
            try await repository.importDeckSnapshot(rejectedSnapshot, fromLocationKey: "scanned deck")
            XCTFail("Expected already-linked location rejection")
        } catch let error as DeckLocationImportPersistenceError {
            XCTAssertEqual(error, .locationAlreadyLinked("Scanned Deck", deck.id))
        }
        let rejectedDeckSnapshot = try await repository.deckSnapshot(id: rejectedDeck.id)
        XCTAssertNil(rejectedDeckSnapshot, "The rejected deck insert must roll back with the link failure")
    }
    func testInventorySweepPreservesLotsAndAggregatesAcrossPrintingsAndLocations() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [printing(1, slug: "ahri-one"), printing(2, slug: "ahri-two")],
            checksum: "catalogue-1",
            completedAt: Date(timeIntervalSince1970: 1)
        )

        try await repository.synchronizeInventory(
            lines: [
                line("a", productID: 1, quantity: 3, location: "Box A"),
                line("b", productID: 2, quantity: 1, location: "Box B"),
                line("c", productID: 1, quantity: 2, location: nil),
            ],
            locations: [InventoryLocation(name: "Box A"), InventoryLocation(name: "Box B")],
            generation: UUID(),
            completedAt: Date(timeIntervalSince1970: 2)
        )

        let cards = try await repository.inventoryCards(search: nil, targetDeckID: nil)
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(card.identity.nameSlug, "ahri")
        XCTAssertEqual(card.availability.totalOwned, 6)
        XCTAssertEqual(card.availability.availableInStorage, 6)
        XCTAssertEqual(card.locations.map(\.quantity).reduce(0, +), 6)
        XCTAssertEqual(Set(card.locations.map(\.normalizedLocationName)), ["box a", "box b", "__unlocated__"])
    }

    func testSuccessfulSweepDeletesStaleLinesButKeepsLocationClassification() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [printing(1, slug: "ahri-one")],
            checksum: "catalogue",
            completedAt: .now
        )
        try await repository.synchronizeInventory(
            lines: [line("a", productID: 1, quantity: 3, location: "BOX A"), line("b", productID: 1, quantity: 2, location: "Box B")],
            locations: [],
            generation: UUID(),
            completedAt: .now
        )
        try await repository.saveLocationPolicy(LocationPolicy(
            normalizedName: "box a",
            displayName: "My Primary Box",
            kind: .unavailable,
            countsAsAvailable: false
        ))

        try await repository.synchronizeInventory(
            lines: [line("a", productID: 1, quantity: 4, location: "box a")],
            locations: [],
            generation: UUID(),
            completedAt: .now
        )

        let inventoryCards = try await repository.inventoryCards(search: nil, targetDeckID: nil)
        let card = try XCTUnwrap(inventoryCards.first)
        XCTAssertEqual(card.availability.totalOwned, 4)
        XCTAssertEqual(card.availability.availableInStorage, 0)
        XCTAssertEqual(card.availability.otherwiseUnavailable, 4)
        let locationPolicies = try await repository.locationPolicies()
        let policy = try XCTUnwrap(locationPolicies.first(where: { $0.normalizedName == "box a" }))
        XCTAssertEqual(policy.displayName, "My Primary Box")
        XCTAssertEqual(policy.kind, .unavailable)
    }

    func testFailedSweepRollsBackUpdatesAndStaleDeletion() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [printing(1, slug: "ahri-one")],
            checksum: "catalogue",
            completedAt: .now
        )
        try await repository.synchronizeInventory(
            lines: [line("a", productID: 1, quantity: 3, location: "Box")],
            locations: [],
            generation: UUID(),
            completedAt: .now
        )

        do {
            try await repository.synchronizeInventory(
                lines: [
                    line("a", productID: 1, quantity: 99, location: "Box"),
                    line("invalid", productID: 999, quantity: 1, location: "Box"),
                ],
                locations: [],
                generation: UUID(),
                completedAt: .now
            )
            XCTFail("Expected the missing printing foreign key to reject the sweep")
        } catch {}

        let inventoryCards = try await repository.inventoryCards(search: nil, targetDeckID: nil)
        let card = try XCTUnwrap(inventoryCards.first)
        XCTAssertEqual(card.availability.totalOwned, 3)
    }

    func testAvailabilityExcludesOtherDeckAndIncludesTargetDeck() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(printings: [printing(1, slug: "ahri-one")], checksum: "c", completedAt: .now)
        let target = Deck(name: "Target", state: .assembled)
        let other = Deck(name: "Other", state: .assembled)
        try await repository.saveDeck(target)
        try await repository.saveDeck(other)
        try await repository.synchronizeInventory(
            lines: [
                line("storage", productID: 1, quantity: 3, location: "Box"),
                line("target", productID: 1, quantity: 2, location: "Deck Target"),
                line("other", productID: 1, quantity: 4, location: "Deck Other"),
                line("bad", productID: 1, quantity: 1, location: "Trade"),
            ],
            locations: [],
            generation: UUID(),
            completedAt: .now
        )
        try await repository.saveLocationPolicy(LocationPolicy(normalizedName: "deck target", displayName: "Deck Target", kind: .deck, countsAsAvailable: false, linkedDeckID: target.id))
        try await repository.saveLocationPolicy(LocationPolicy(normalizedName: "deck other", displayName: "Deck Other", kind: .deck, countsAsAvailable: false, linkedDeckID: other.id))
        try await repository.saveLocationPolicy(LocationPolicy(normalizedName: "trade", displayName: "Trade", kind: .unavailable, countsAsAvailable: false))
        try await repository.saveDeckEntry(DeckEntry(deckID: target.id, zone: .main, nameSlug: "ahri", quantity: 6))

        let targetInventoryCards = try await repository.inventoryCards(search: nil, targetDeckID: target.id)
        let forTarget = try XCTUnwrap(targetInventoryCards.first)
        XCTAssertEqual(forTarget.availability.totalOwned, 10)
        XCTAssertEqual(forTarget.availability.availableInStorage, 3)
        XCTAssertEqual(forTarget.availability.inTargetDeck, 2)
        XCTAssertEqual(forTarget.availability.inOtherDecks, 4)
        XCTAssertEqual(forTarget.availability.otherwiseUnavailable, 1)
        XCTAssertEqual(forTarget.availability.required, 6)
        XCTAssertEqual(forTarget.availability.missing, 1)

        let globalInventoryCards = try await repository.inventoryCards(search: nil, targetDeckID: nil)
        let globally = try XCTUnwrap(globalInventoryCards.first)
        XCTAssertEqual(globally.availability.inTargetDeck, 0)
        XCTAssertEqual(globally.availability.inOtherDecks, 6)
    }

    func testDeckCRUDCoalescesMovedEntriesAndDeletionClearsLocationLink() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(printings: [printing(1, slug: "ahri-one")], checksum: "c", completedAt: .now)
        let deck = Deck(name: "Deck")
        try await repository.saveDeck(deck)
        let first = DeckEntry(deckID: deck.id, zone: .main, nameSlug: "ahri", quantity: 2)
        let second = DeckEntry(deckID: deck.id, zone: .sideboard, nameSlug: "ahri", quantity: 1)
        try await repository.saveDeckEntry(first)
        try await repository.saveDeckEntry(second)

        var moved = second
        moved.zone = .main
        try await repository.saveDeckEntry(moved)
        let savedSnapshot = try await repository.deckSnapshot(id: deck.id)
        var snapshot = try XCTUnwrap(savedSnapshot)
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entries.first?.quantity, 3)

        try await repository.saveLocationPolicy(LocationPolicy(normalizedName: "deck", displayName: "Deck", kind: .deck, countsAsAvailable: false, linkedDeckID: deck.id))
        try await repository.deleteDeck(id: deck.id)
        let deletedSnapshot = try await repository.deckSnapshot(id: deck.id)
        XCTAssertNil(deletedSnapshot)
        let remainingDecks = try await repository.decks()
        XCTAssertTrue(remainingDecks.isEmpty)
        let locationPolicies = try await repository.locationPolicies()
        let policy = try XCTUnwrap(locationPolicies.first)
        XCTAssertNil(policy.linkedDeckID)
        snapshot = DeckSnapshot(deck: deck, entries: [], identities: [:])
        XCTAssertTrue(snapshot.entries.isEmpty)
    }
}

private func printing(_ productID: Int64, slug: String) -> CardPrinting {
    CardPrinting(
        productID: productID,
        nameSlug: "ahri",
        printingSlug: slug,
        displayName: "Ahri, Charmer",
        finishes: ["normal"],
        languages: ["en"],
        attributes: [
            "cardType": .string("Unit"),
            "domains": .array([.string("calm")]),
            "tags": .array([.string("Ahri")]),
        ]
    )
}

private func line(_ id: String, productID: Int64, quantity: Int, location: String?) -> InventoryLine {
    InventoryLine(
        inventoryID: id,
        productID: productID,
        finish: "normal",
        language: "en",
        quantity: quantity,
        locationName: location,
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}
