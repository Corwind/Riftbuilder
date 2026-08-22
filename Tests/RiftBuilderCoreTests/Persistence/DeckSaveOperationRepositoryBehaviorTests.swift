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
