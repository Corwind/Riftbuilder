import Foundation
import XCTest
@testable import RiftBuilderCore

final class TextDeckNameResolverTests: XCTestCase {
    func testResolvesNamesWithoutGuessingAndCreatesFreshEntriesForDeck() throws {
        let deckID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let document = try TextDeckTextParser.parse("""
            Legend:
            1 EZRÉAL,   Prodigal Explorer
            MainDeck:
            3 Fizz, Trickster
            2 Unknown Card
            """)
        let ezreal = identity("ezreal-prodigal-explorer", "Ezreal, Prodigal Explorer")
        let fizz = identity("fizz-trickster", "Fizz, Trickster")

        let result = TextDeckNameResolver.resolve(document, against: [ezreal, fizz], deckID: deckID)

        XCTAssertFalse(result.isFullyResolved)
        XCTAssertEqual(result.entries.map(\.deckID), [deckID, deckID])
        XCTAssertEqual(result.entries.map(\.nameSlug), [ezreal.nameSlug, fizz.nameSlug])
        XCTAssertEqual(result.entries.map(\.quantity), [1, 3])
        XCTAssertEqual(Set(result.entries.map(\.id)).count, 2)
        XCTAssertEqual(result.identities, [ezreal.nameSlug: ezreal, fizz.nameSlug: fizz])
        XCTAssertEqual(result.unresolvedCards.map(\.entry.displayName), ["Unknown Card"])
        XCTAssertTrue(result.ambiguousCards.isEmpty)
    }

    func testReportsAllExactNormalizedAmbiguitiesWithoutChoosingOne() throws {
        let document = try TextDeckTextParser.parse("MainDeck:\n1 The Wanderer")
        let first = identity("the-wanderer-alpha", "The Wanderer")
        let second = identity("the-wanderer-beta", "the wanderer")

        let result = TextDeckNameResolver.resolve(document, against: [second, first], deckID: UUID())

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.unresolvedCards.isEmpty)
        XCTAssertEqual(result.ambiguousCards.count, 1)
        XCTAssertEqual(result.ambiguousCards[0].candidates.map(\.nameSlug), [first.nameSlug, second.nameSlug])
    }

    func testFullyResolvedResultIsReadyForDeckCreation() throws {
        let document = try TextDeckTextParser.parse("Champion:\n1 Ezreal, Prodigy")
        let ezreal = identity("ezreal-prodigy", "Ezreal, Prodigy")
        let result = TextDeckNameResolver.resolve(document, against: [ezreal], deckID: UUID())

        XCTAssertTrue(result.isFullyResolved)
        XCTAssertEqual(result.entries.single?.zone, .chosenChampion)
        XCTAssertEqual(result.entries.single?.preferredProductID, nil)
    }
}

private extension TextDeckNameResolverTests {
    func identity(_ nameSlug: String, _ displayName: String) -> CardIdentity {
        CardIdentity(nameSlug: nameSlug, displayName: displayName)
    }
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}
