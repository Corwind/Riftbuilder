import Foundation
import XCTest
@testable import RiftBuilderCore

final class TextDeckPunctuationNormalizationTests: XCTestCase {
    func testCommaExportResolvesToSpacedHyphenCatalogueName() throws {
        let document = try TextDeckTextParser.parse("Champion:\n1 Ezreal, Prodigy")
        let catalogueCard = identity("ezreal-prodigy", "Ezreal - Prodigy")

        let result = TextDeckNameResolver.resolve(document, against: [catalogueCard], deckID: UUID())

        XCTAssertTrue(result.isFullyResolved)
        XCTAssertEqual(result.entries.single?.nameSlug, catalogueCard.nameSlug)
    }

    func testTitleDashVariantsShareOneCanonicalSeparator() {
        let expected = TextDeckNameNormalizer.normalize("Ezreal, Prodigy")

        XCTAssertEqual(TextDeckNameNormalizer.normalize("Ezreal - Prodigy"), expected)
        XCTAssertEqual(TextDeckNameNormalizer.normalize("Ezreal – Prodigy"), expected)
        XCTAssertEqual(TextDeckNameNormalizer.normalize("Ezreal—Prodigy"), expected)
        XCTAssertEqual(TextDeckNameNormalizer.normalize("Ezreal ,  Prodigy"), expected)
    }

    func testNormalizerPreservesSemanticPunctuationAndWordBoundaries() {
        XCTAssertNotEqual(TextDeckNameNormalizer.normalize("Kai'Sa"), TextDeckNameNormalizer.normalize("Kaisa"))
        XCTAssertNotEqual(TextDeckNameNormalizer.normalize("A B"), TextDeckNameNormalizer.normalize("AB"))
        XCTAssertNotEqual(TextDeckNameNormalizer.normalize("Thousand-Tailed Watcher"), TextDeckNameNormalizer.normalize("Thousand, Tailed Watcher"))
        XCTAssertNotEqual(TextDeckNameNormalizer.normalize("One: Two"), TextDeckNameNormalizer.normalize("One, Two"))
    }

    func testEquivalentPunctuationCandidatesRemainAmbiguous() throws {
        let document = try TextDeckTextParser.parse("Champion:\n1 Ezreal, Prodigy")
        let comma = identity("ezreal-prodigy-comma", "Ezreal, Prodigy")
        let dash = identity("ezreal-prodigy-dash", "Ezreal - Prodigy")

        let result = TextDeckNameResolver.resolve(document, against: [dash, comma], deckID: UUID())

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.unresolvedCards.isEmpty)
        XCTAssertEqual(result.ambiguousCards.single?.candidates.map(\.nameSlug), [comma.nameSlug, dash.nameSlug])
    }

    func testParserCoalescesEquivalentTitleSeparatorsButNotInternalHyphens() throws {
        let document = try TextDeckTextParser.parse("""
            MainDeck:
            1 Ezreal, Prodigy
            2 Ezreal - Prodigy
            1 Thousand-Tailed Watcher
            1 Thousand, Tailed Watcher
            """)

        XCTAssertEqual(document.entries.count, 3)
        XCTAssertEqual(document.entries[0].displayName, "Ezreal, Prodigy")
        XCTAssertEqual(document.entries[0].quantity, 3)
        XCTAssertEqual(document.entries[1].displayName, "Thousand-Tailed Watcher")
        XCTAssertEqual(document.entries[2].displayName, "Thousand, Tailed Watcher")
    }
}

private extension TextDeckPunctuationNormalizationTests {
    func identity(_ nameSlug: String, _ displayName: String) -> CardIdentity {
        CardIdentity(nameSlug: nameSlug, displayName: displayName)
    }
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}
