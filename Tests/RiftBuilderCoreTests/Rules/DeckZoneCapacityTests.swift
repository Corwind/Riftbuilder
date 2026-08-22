import XCTest
@testable import RiftBuilderCore

final class DeckZoneCapacityTests: XCTestCase {
    func testConfiguredZoneMaximumsMatchConstructedDeckLimits() {
        XCTAssertEqual(DeckZoneCapacity.maximumTotalQuantity(for: .legend), 1)
        XCTAssertEqual(DeckZoneCapacity.maximumTotalQuantity(for: .chosenChampion), 1)
        XCTAssertEqual(DeckZoneCapacity.maximumTotalQuantity(for: .battlefield), 3)
        XCTAssertEqual(DeckZoneCapacity.maximumTotalQuantity(for: .rune), 12)
        XCTAssertEqual(DeckZoneCapacity.maximumTotalQuantity(for: .sideboard), 10)
        XCTAssertNil(DeckZoneCapacity.maximumTotalQuantity(for: .main))
    }

    func testZoneCapacityCountsQuantitiesAndRejectsOverflow() {
        let deckID = UUID()
        let entries = [
            DeckEntry(deckID: deckID, zone: .rune, nameSlug: "calm-rune", quantity: 5),
            DeckEntry(deckID: deckID, zone: .rune, nameSlug: "mind-rune", quantity: 7),
            DeckEntry(deckID: deckID, zone: .sideboard, nameSlug: "spell", quantity: 9),
        ]

        XCTAssertEqual(DeckZoneCapacity.totalQuantity(in: .rune, entries: entries), 12)
        XCTAssertEqual(DeckZoneCapacity.remainingQuantity(in: .rune, entries: entries), 0)
        XCTAssertFalse(DeckZoneCapacity.canAdd(nameSlug: "chaos-rune", to: .rune, entries: entries))
        XCTAssertTrue(DeckZoneCapacity.canAdd(nameSlug: "another-spell", to: .sideboard, entries: entries))
    }

    func testSingleCardZonesAndBattlefieldsRejectDuplicateCards() {
        let deckID = UUID()
        let entries = [
            DeckEntry(deckID: deckID, zone: .legend, nameSlug: "legend", quantity: 1),
            DeckEntry(deckID: deckID, zone: .chosenChampion, nameSlug: "champion", quantity: 1),
            DeckEntry(deckID: deckID, zone: .battlefield, nameSlug: "field-one", quantity: 1),
        ]

        XCTAssertFalse(DeckZoneCapacity.canAdd(nameSlug: "other-legend", to: .legend, entries: entries))
        XCTAssertFalse(DeckZoneCapacity.canAdd(nameSlug: "other-champion", to: .chosenChampion, entries: entries))
        XCTAssertFalse(DeckZoneCapacity.canAdd(nameSlug: "field-one", to: .battlefield, entries: entries))
        XCTAssertTrue(DeckZoneCapacity.canAdd(nameSlug: "field-two", to: .battlefield, entries: entries))
    }
}
