import Foundation
import XCTest
@testable import RiftBuilderCore

final class TextDeckTextParserTests: XCTestCase {
    func testParsesRiftDeckExportAndMapsEverySection() throws {
        let document = try TextDeckTextParser.parse(sampleExport)

        XCTAssertEqual(document.suggestedDeckName, "Ezreal Deck")
        XCTAssertEqual(document.entries.first, .init(zone: .legend, displayName: "Ezreal, Prodigal Explorer", quantity: 1, lineNumber: 2))
        XCTAssertEqual(document.entries.first(where: { $0.displayName == "Ezreal, Prodigy" })?.zone, .chosenChampion)
        XCTAssertEqual(document.entries.first(where: { $0.displayName == "Fizz, Trickster" })?.zone, .main)
        XCTAssertEqual(document.entries.first(where: { $0.displayName == "Frozen Fortress" })?.zone, .battlefield)
        XCTAssertEqual(document.entries.first(where: { $0.displayName == "Mind Rune" })?.zone, .rune)
        XCTAssertEqual(document.entries.first(where: { $0.displayName == "Pickpocket" })?.zone, .sideboard)
        XCTAssertEqual(document.entries.first(where: { $0.displayName == "Pickpocket" })?.quantity, 3)
    }

    func testToleratesBOMCRLFTrailingWhitespaceAndCoalescesNamesWithinZone() throws {
        let text = "\u{feff}MainDeck:  \r\n1 Café Duelist   \r\n2   cafe\u{301} duelist\t\r\n\r\nSideboard:\r\n1 Café Duelist\r\n"
        let document = try TextDeckTextParser.parse(text)

        XCTAssertEqual(document.entries, [
            .init(zone: .main, displayName: "Café Duelist", quantity: 3, lineNumber: 2),
            .init(zone: .sideboard, displayName: "Café Duelist", quantity: 1, lineNumber: 6),
        ])
    }

    func testRejectsEntryBeforeSectionWithLineNumber() {
        assertParseError("\n1 Ezreal", equals: .entryBeforeSection(line: 2, content: "1 Ezreal"))
    }

    func testRejectsUnknownSectionWithLineNumber() {
        assertParseError("Legend:\n1 Ezreal\nMaybeboard:\n1 Fizz", equals: .unknownSection(line: 3, heading: "Maybeboard"))
    }

    func testRejectsMalformedNonPositiveAndMissingQuantities() {
        assertParseError("MainDeck:\nthree Fizz", equals: .invalidQuantity(line: 2, token: "three"))
        assertParseError("MainDeck:\n0 Fizz", equals: .invalidQuantity(line: 2, token: "0"))
        assertParseError("MainDeck:\n3", equals: .missingCardName(line: 2))
    }

    func testLocalizedErrorsIncludeLineNumber() {
        XCTAssertThrowsError(try TextDeckTextParser.parse("MainDeck:\nnope Fizz")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Line 2"))
        }
    }
}

private extension TextDeckTextParserTests {
    func assertParseError(_ text: String, equals expected: TextDeckImportError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TextDeckTextParser.parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? TextDeckImportError, expected, file: file, line: line)
        }
    }

    var sampleExport: String {
        """
        Legend:
        1 Ezreal, Prodigal Explorer

        Champion:
        1 Ezreal, Prodigy

        MainDeck:
        2 Vex, Apathetic
        3 Fizz, Trickster
        2 Thousand-Tailed Watcher

        Battlefields:
        1 Frozen Fortress

        Rune Pool:
        5 Mind Rune
        7 Chaos Rune

        Sideboard:
        1 Turn to Dust
        3 Pickpocket
        """
    }
}
