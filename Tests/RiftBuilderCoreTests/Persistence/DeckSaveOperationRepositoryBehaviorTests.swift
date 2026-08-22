import Foundation
import XCTest
@testable import RiftBuilderCore

final class DeckSaveOperationRepositoryBehaviorTests: XCTestCase {
    func testReviewedPlanSurvivesReloadWithRemovalDestinations() async throws {
        let context = try await operationContext()
        let operation = makeOperation(deckID: context.deck.id, draftUpdatedAt: context.draft.updatedAt)

        try await context.repository.saveDeckSaveOperation(operation)
        let reloaded = try await context.repository.deckSaveOperation(deckID: context.deck.id)

        XCTAssertEqual(reloaded, operation)
        XCTAssertEqual(reloaded?.plan.movements.first?.destinationLocationName, "Box A")
    }

    func testEditingDraftAfterReviewPreventsStalePlanFromFinalizing() async throws {
        let context = try await operationContext()
        let operation = makeOperation(deckID: context.deck.id, draftUpdatedAt: context.draft.updatedAt)
        try await context.repository.saveDeckSaveOperation(operation)
        try await context.repository.saveDeckDraftEntry(
            DeckEntry(deckID: context.deck.id, zone: .sideboard, nameSlug: "ahri", quantity: 1),
            at: Date(timeIntervalSince1970: 40)
        )

        do {
            _ = try await context.repository.finalizeDeckSaveOperation(deckID: context.deck.id, operationID: operation.id, at: Date(timeIntervalSince1970: 50))
            XCTFail("Expected stale plan rejection")
        } catch let error as DeckSaveOperationStoreError {
            XCTAssertEqual(error, .draftChanged(context.deck.id))
        }

        let retainedDraft = try await context.repository.deckDraftSnapshot(id: context.deck.id)
        let saved = try await context.repository.deckSnapshot(id: context.deck.id)
        XCTAssertNotNil(retainedDraft)
        XCTAssertEqual(saved?.entries.map(\.quantity), [2])
    }

    func testFinalizationReplacesSavedDefinitionAndClearsDraftAndOperationTogether() async throws {
        let context = try await operationContext()
        let operation = makeOperation(deckID: context.deck.id, draftUpdatedAt: context.draft.updatedAt)
        try await context.repository.saveDeckSaveOperation(operation)

        let finalized = try await context.repository.finalizeDeckSaveOperation(
            deckID: context.deck.id,
            operationID: operation.id,
            at: Date(timeIntervalSince1970: 50)
        )

        XCTAssertEqual(finalized?.entries.map(\.quantity), [3])
        let clearedDraft = try await context.repository.deckDraftSnapshot(id: context.deck.id)
        let clearedOperation = try await context.repository.deckSaveOperation(deckID: context.deck.id)
        XCTAssertNil(clearedDraft)
        XCTAssertNil(clearedOperation)
    }

    func testFinalizedAdditionsRememberOriginAndFinalizedRemovalConsumesItEvenWithOverride() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [CardPrinting(productID: 1, nameSlug: "ahri", printingSlug: "ahri", displayName: "Ahri", finishes: ["foil"], languages: ["en"])],
            checksum: "catalogue",
            completedAt: .distantPast
        )
        let deck = Deck(name: "Deck")
        try await repository.saveDeck(deck)
        _ = try await repository.beginDeckDraft(id: deck.id, at: Date(timeIntervalSince1970: 10))
        try await repository.saveDeckDraftEntry(
            DeckEntry(deckID: deck.id, zone: .main, nameSlug: "ahri", quantity: 2),
            at: Date(timeIntervalSince1970: 11)
        )
        let firstDraftValue = try await repository.deckDraftSnapshot(id: deck.id)
        let firstDraft = try XCTUnwrap(firstDraftValue)
        let addition = PlannedInventoryMovement(
            operationID: "add",
            inventoryID: "box-line",
            productID: 1,
            nameSlug: "ahri",
            quantity: 2,
            sourceLocationName: "Box A",
            destinationLocationName: "Deck",
            finish: "foil",
            language: "en"
        )
        let firstPlan = DeckSavePlan(planID: UUID(), deckID: deck.id, deckLocationName: "Deck", movements: [addition], requirements: [], unresolvedRemovalDestinations: [])
        let firstOperation = DeckSaveOperation(plan: firstPlan, draftUpdatedAt: firstDraft.updatedAt)
        try await repository.saveDeckSaveOperation(firstOperation)
        _ = try await repository.finalizeDeckSaveOperation(deckID: deck.id, operationID: firstOperation.id, at: Date(timeIntervalSince1970: 12))

        let rememberedLots = try await repository.deckCardOriginLots(deckID: deck.id)
        let remembered = try XCTUnwrap(rememberedLots.first)
        XCTAssertEqual(remembered.previousLocationName, "Box A")
        XCTAssertEqual(remembered.previousLocationKey, "box a")
        XCTAssertEqual(remembered.productID, 1)
        XCTAssertEqual(remembered.finish, "foil")
        XCTAssertEqual(remembered.language, "en")
        XCTAssertEqual(remembered.quantity, 2)

        let secondDraftValue = try await repository.beginDeckDraft(id: deck.id, at: Date(timeIntervalSince1970: 20))
        let secondDraft = try XCTUnwrap(secondDraftValue)
        var edited = try XCTUnwrap(secondDraft.entries.first)
        edited.quantity = 1
        try await repository.saveDeckDraftEntry(edited, at: Date(timeIntervalSince1970: 21))
        let editedDraftValue = try await repository.deckDraftSnapshot(id: deck.id)
        let editedDraft = try XCTUnwrap(editedDraftValue)
        let removal = PlannedInventoryMovement(
            operationID: "remove",
            inventoryID: "deck-line",
            productID: 1,
            nameSlug: "ahri",
            quantity: 1,
            sourceLocationName: "Deck",
            destinationLocationName: "Box B",
            finish: "foil",
            language: "en",
            originLotID: remembered.id
        )
        let secondPlan = DeckSavePlan(planID: UUID(), deckID: deck.id, deckLocationName: "Deck", movements: [removal], requirements: [], unresolvedRemovalDestinations: [])
        let secondOperation = DeckSaveOperation(plan: secondPlan, draftUpdatedAt: editedDraft.updatedAt)
        try await repository.saveDeckSaveOperation(secondOperation)
        _ = try await repository.finalizeDeckSaveOperation(deckID: deck.id, operationID: secondOperation.id, at: Date(timeIntervalSince1970: 22))

        let remainingLots = try await repository.deckCardOriginLots(deckID: deck.id)
        let remaining = try XCTUnwrap(remainingLots.first)
        XCTAssertEqual(remaining.previousLocationName, "Box A", "Changing the return destination must not rewrite the remembered origin")
        XCTAssertEqual(remaining.quantity, 1)
    }
}

private struct OperationContext {
    let repository: GRDBRiftBuilderRepository
    let deck: Deck
    let draft: DeckDraftSnapshot
}

private func operationContext() async throws -> OperationContext {
    let repository = try GRDBRiftBuilderRepository.inMemory()
    let printing = CardPrinting(productID: 1, nameSlug: "ahri", printingSlug: "ahri", displayName: "Ahri")
    try await repository.replaceCatalogue(printings: [printing], checksum: "catalogue", completedAt: .distantPast)
    let deck = Deck(name: "Deck")
    try await repository.saveDeck(deck)
    try await repository.saveDeckEntry(DeckEntry(deckID: deck.id, zone: .main, nameSlug: "ahri", quantity: 2))
    let started = try await repository.beginDeckDraft(id: deck.id, at: Date(timeIntervalSince1970: 20))
    var entry = try XCTUnwrap(started?.entries.first)
    entry.quantity = 3
    try await repository.saveDeckDraftEntry(entry, at: Date(timeIntervalSince1970: 30))
    let draftValue = try await repository.deckDraftSnapshot(id: deck.id)
    let draft = try XCTUnwrap(draftValue)
    return OperationContext(repository: repository, deck: deck, draft: draft)
}

private func makeOperation(deckID: UUID, draftUpdatedAt: Date) -> DeckSaveOperation {
    let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
    let movement = PlannedInventoryMovement(operationID: "remove", inventoryID: "line", productID: 1, nameSlug: "ahri", quantity: 1, sourceLocationName: "Deck", destinationLocationName: "Box A")
    let plan = DeckSavePlan(planID: planID, deckID: deckID, deckLocationName: "Deck", movements: [movement], requirements: [], unresolvedRemovalDestinations: [])
    return DeckSaveOperation(plan: plan, draftUpdatedAt: draftUpdatedAt, createdAt: Date(timeIntervalSince1970: 31))
}
