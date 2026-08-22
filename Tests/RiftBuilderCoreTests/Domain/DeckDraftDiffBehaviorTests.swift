import XCTest
@testable import RiftBuilderCore

final class DeckDraftDiffBehaviorTests: XCTestCase {
    func testReportsOnlyNetQuantityChangesForSameLogicalCard() {
        let deckID = UUID()
        let saved = [
            DeckEntry(deckID: deckID, zone: .main, nameSlug: "ahri", quantity: 2),
            DeckEntry(deckID: deckID, zone: .main, nameSlug: "ahri", quantity: 1),
            DeckEntry(deckID: deckID, zone: .main, nameSlug: "vex", quantity: 3),
        ]
        let draft = [
            DeckEntry(deckID: deckID, zone: .main, nameSlug: "ahri", quantity: 5),
            DeckEntry(deckID: deckID, zone: .main, nameSlug: "vex", quantity: 3),
        ]

        let diff = DeckDraftDiff(savedEntries: saved, draftEntries: draft)

        XCTAssertEqual(diff.changes.count, 1)
        XCTAssertEqual(diff.additions.first?.key.nameSlug, "ahri")
        XCTAssertEqual(diff.additions.first?.savedQuantity, 3)
        XCTAssertEqual(diff.additions.first?.draftQuantity, 5)
        XCTAssertEqual(diff.additions.first?.quantityChange, 2)
        XCTAssertTrue(diff.removals.isEmpty)
    }

    func testMovingCardBetweenZonesIsAStoredRemovalAndAddition() {
        let deckID = UUID()
        let diff = DeckDraftDiff(
            savedEntries: [DeckEntry(deckID: deckID, zone: .main, nameSlug: "pickpocket", quantity: 1)],
            draftEntries: [DeckEntry(deckID: deckID, zone: .sideboard, nameSlug: "pickpocket", quantity: 1)]
        )

        XCTAssertEqual(diff.additions.map(\.key.zone), [.sideboard])
        XCTAssertEqual(diff.removals.map(\.key.zone), [.main])
        XCTAssertEqual(diff.additions.map(\.quantityChange), [1])
        XCTAssertEqual(diff.removals.map(\.quantityChange), [-1])
    }

    func testPrintingPreferencesRemainIndependentChanges() {
        let deckID = UUID()
        let normal = DeckEntry(deckID: deckID, zone: .main, nameSlug: "ahri", quantity: 1, preferredProductID: 10, preferredFinish: "normal", preferredLanguage: "en")
        let foil = DeckEntry(deckID: deckID, zone: .main, nameSlug: "ahri", quantity: 1, preferredProductID: 11, preferredFinish: "foil", preferredLanguage: "en")

        let diff = DeckDraftDiff(savedEntries: [normal], draftEntries: [foil])

        XCTAssertEqual(diff.additions.map(\.key.preferredProductID), [11])
        XCTAssertEqual(diff.removals.map(\.key.preferredProductID), [10])
    }

    func testIdenticalDefinitionsHaveNoStoredDiff() {
        let deckID = UUID()
        let entries = [DeckEntry(deckID: deckID, zone: .rune, nameSlug: "mind-rune", quantity: 12)]
        XCTAssertTrue(DeckDraftDiff(savedEntries: entries, draftEntries: entries).isEmpty)
    }
}
