import Foundation
import XCTest
@testable import RiftBuilderCore

final class DeckDraftRepositoryBehaviorTests: XCTestCase {
    func testEditingDraftDoesNotChangePhysicallySavedDeck() async throws {
        let repository = try await repositoryWithSavedDeck(quantity: 2)
        let decks = try await repository.decks()
        let deck = try XCTUnwrap(decks.first)
        let startedValue = try await repository.beginDeckDraft(id: deck.id, at: date(20))
        let started = try XCTUnwrap(startedValue)
        var edited = try XCTUnwrap(started.entries.first)
        edited.quantity = 4

        try await repository.saveDeckDraftEntry(edited, at: date(30))

        let savedValue = try await repository.deckSnapshot(id: deck.id)
        let draftValue = try await repository.deckDraftSnapshot(id: deck.id)
        let saved = try XCTUnwrap(savedValue)
        let draft = try XCTUnwrap(draftValue)
        XCTAssertEqual(saved.entries.map(\.quantity), [2], "The saved definition must continue to describe physical inventory")
        XCTAssertEqual(draft.entries.map(\.quantity), [4], "Edits belong to the durable draft")
        XCTAssertEqual(draft.createdAt, date(20))
        XCTAssertEqual(draft.updatedAt, date(30))
    }

    func testStartingExistingDraftResumesItWithoutOverwritingChanges() async throws {
        let repository = try await repositoryWithSavedDeck(quantity: 2)
        let decks = try await repository.decks()
        let deck = try XCTUnwrap(decks.first)
        let startedValue = try await repository.beginDeckDraft(id: deck.id, at: date(20))
        let started = try XCTUnwrap(startedValue)
        var edited = try XCTUnwrap(started.entries.first)
        edited.quantity = 5
        try await repository.saveDeckDraftEntry(edited, at: date(30))

        let resumedValue = try await repository.beginDeckDraft(id: deck.id, at: date(40))
        let resumed = try XCTUnwrap(resumedValue)

        XCTAssertEqual(resumed.entries.map(\.quantity), [5])
        XCTAssertEqual(resumed.createdAt, date(20))
        XCTAssertEqual(resumed.updatedAt, date(30), "Merely reopening a draft is not an edit")
    }

    func testDiscardRestoresSavedDefinitionAsOnlySourceOfDeckContents() async throws {
        let repository = try await repositoryWithSavedDeck(quantity: 2)
        let decks = try await repository.decks()
        let deck = try XCTUnwrap(decks.first)
        let startedValue = try await repository.beginDeckDraft(id: deck.id, at: date(20))
        let started = try XCTUnwrap(startedValue)
        var edited = try XCTUnwrap(started.entries.first)
        edited.quantity = 7
        try await repository.saveDeckDraftEntry(edited, at: date(30))

        try await repository.discardDeckDraft(id: deck.id)

        let discardedDraft = try await repository.deckDraftSnapshot(id: deck.id)
        let saved = try await repository.deckSnapshot(id: deck.id)
        XCTAssertNil(discardedDraft)
        XCTAssertEqual(saved?.entries.map(\.quantity), [2])
    }

    func testCommitAtomicallyReplacesSavedDefinitionAndClearsDraft() async throws {
        let repository = try await repositoryWithSavedDeck(quantity: 2)
        let decks = try await repository.decks()
        let deck = try XCTUnwrap(decks.first)
        let startedValue = try await repository.beginDeckDraft(id: deck.id, at: date(20))
        let started = try XCTUnwrap(startedValue)
        var main = try XCTUnwrap(started.entries.first)
        main.quantity = 3
        try await repository.saveDeckDraftEntry(main, at: date(30))
        try await repository.saveDeckDraftEntry(
            DeckEntry(deckID: deck.id, zone: .sideboard, nameSlug: "ahri", quantity: 1),
            at: date(31)
        )

        let committedValue = try await repository.commitDeckDraft(id: deck.id, at: date(40))
        let committed = try XCTUnwrap(committedValue)

        XCTAssertEqual(committed.deck.updatedAt, date(40))
        XCTAssertEqual(committed.entries.map(\.quantity).sorted(), [1, 3])
        XCTAssertEqual(Set(committed.entries.map(\.zone)), [.main, .sideboard])
        let clearedDraft = try await repository.deckDraftSnapshot(id: deck.id)
        let saved = try await repository.deckSnapshot(id: deck.id)
        XCTAssertNil(clearedDraft)
        XCTAssertEqual(saved, committed)
    }

    func testDeletingDeckAlsoDeletesItsDraft() async throws {
        let repository = try await repositoryWithSavedDeck(quantity: 2)
        let decks = try await repository.decks()
        let deck = try XCTUnwrap(decks.first)
        _ = try await repository.beginDeckDraft(id: deck.id, at: date(20))

        try await repository.deleteDeck(id: deck.id)

        let draft = try await repository.deckDraftSnapshot(id: deck.id)
        let saved = try await repository.deckSnapshot(id: deck.id)
        XCTAssertNil(draft)
        XCTAssertNil(saved)
    }
}

private func repositoryWithSavedDeck(quantity: Int) async throws -> GRDBRiftBuilderRepository {
    let repository = try GRDBRiftBuilderRepository.inMemory()
    try await repository.replaceCatalogue(
        printings: [CardPrinting(
            productID: 1,
            nameSlug: "ahri",
            printingSlug: "ahri-one",
            displayName: "Ahri, Charmer",
            finishes: ["normal"],
            languages: ["en"]
        )],
        checksum: "catalogue",
        completedAt: date(1)
    )
    let deck = Deck(name: "Ahri", createdAt: date(10), updatedAt: date(10))
    try await repository.saveDeck(deck)
    try await repository.saveDeckEntry(DeckEntry(deckID: deck.id, zone: .main, nameSlug: "ahri", quantity: quantity))
    return repository
}

private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}
