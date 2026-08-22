import XCTest
@testable import RiftBuilderCore

final class DomainModelTests: XCTestCase {
    func testLocationNormalizationIsStable() {
        XCTAssertEqual(InventoryLocation.normalize("  Box A "), "box a")
        XCTAssertEqual(InventoryLocation.normalize(nil), "__unlocated__")
    }

    func testTargetDeckAvailabilityIncludesItsOwnCards() {
        let availability = CardAvailability(
            totalOwned: 8,
            availableInStorage: 3,
            inTargetDeck: 2,
            inOtherDecks: 3,
            required: 6
        )
        XCTAssertEqual(availability.usableForTargetDeck, 5)
        XCTAssertEqual(availability.missing, 1)
    }
}
