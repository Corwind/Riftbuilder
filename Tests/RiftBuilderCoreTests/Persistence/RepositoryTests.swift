import Foundation
import XCTest
@testable import RiftBuilderCore

final class RepositoryTests: XCTestCase {
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

        let card = try XCTUnwrap(try await repository.inventoryCards(search: nil, targetDeckID: nil).first)
        XCTAssertEqual(card.availability.totalOwned, 4)
        XCTAssertEqual(card.availability.availableInStorage, 0)
        XCTAssertEqual(card.availability.otherwiseUnavailable, 4)
        let policy = try XCTUnwrap(try await repository.locationPolicies().first(where: { $0.normalizedName == "box a" }))
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

        let card = try XCTUnwrap(try await repository.inventoryCards(search: nil, targetDeckID: nil).first)
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

        let forTarget = try XCTUnwrap(try await repository.inventoryCards(search: nil, targetDeckID: target.id).first)
        XCTAssertEqual(forTarget.availability.totalOwned, 10)
        XCTAssertEqual(forTarget.availability.availableInStorage, 3)
        XCTAssertEqual(forTarget.availability.inTargetDeck, 2)
        XCTAssertEqual(forTarget.availability.inOtherDecks, 4)
        XCTAssertEqual(forTarget.availability.otherwiseUnavailable, 1)
        XCTAssertEqual(forTarget.availability.required, 6)
        XCTAssertEqual(forTarget.availability.missing, 1)

        let globally = try XCTUnwrap(try await repository.inventoryCards(search: nil, targetDeckID: nil).first)
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
        var snapshot = try XCTUnwrap(try await repository.deckSnapshot(id: deck.id))
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entries.first?.quantity, 3)

        try await repository.saveLocationPolicy(LocationPolicy(normalizedName: "deck", displayName: "Deck", kind: .deck, countsAsAvailable: false, linkedDeckID: deck.id))
        try await repository.deleteDeck(id: deck.id)
        XCTAssertNil(try await repository.deckSnapshot(id: deck.id))
        XCTAssertTrue(try await repository.decks().isEmpty)
        let policy = try XCTUnwrap(try await repository.locationPolicies().first)
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
