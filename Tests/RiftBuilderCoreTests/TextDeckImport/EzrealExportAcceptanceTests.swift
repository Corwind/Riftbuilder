import XCTest
@testable import RiftBuilderCore

final class EzrealExportAcceptanceTests: XCTestCase {
    func testParsesCompleteEzrealRiftDeckExport() throws {
        let document = try TextDeckTextParser.parse(export)

        XCTAssertEqual(document.suggestedDeckName, "Ezreal Deck")
        XCTAssertEqual(document.entries.count, 33)
        XCTAssertEqual(document.entries.reduce(0) { $0 + $1.quantity }, 66)
        XCTAssertEqual(quantity(in: .legend, document), 1)
        XCTAssertEqual(quantity(in: .chosenChampion, document), 1)
        XCTAssertEqual(quantity(in: .main, document), 39)
        XCTAssertEqual(quantity(in: .battlefield, document), 3)
        XCTAssertEqual(quantity(in: .rune, document), 12)
        XCTAssertEqual(quantity(in: .sideboard, document), 10)
        XCTAssertEqual(document.entries.first { $0.zone == .main && $0.displayName == "Turn to Dust" }?.quantity, 1)
        XCTAssertEqual(document.entries.first { $0.zone == .sideboard && $0.displayName == "Turn to Dust" }?.quantity, 1)
    }

    private func quantity(in zone: DeckZone, _ document: TextDeckImportDocument) -> Int {
        document.entries.lazy.filter { $0.zone == zone }.reduce(0) { $0 + $1.quantity }
    }

    private var export: String {
        """
        Legend:
        1 Ezreal, Prodigal Explorer

        Champion:
        1 Ezreal, Prodigy

        MainDeck:
        2 Vex, Apathetic
        3 Fizz, Trickster
        2 Thousand-Tailed Watcher
        2 Deadly Flourish
        3 Star-Crossed
        2 Wages of Pain
        3 Bellows Breath
        3 Stupefy
        1 Retreat
        3 Stacked Deck
        1 Hard Bargain
        2 Temporal Breach
        3 Bewitching Spirit
        2 The List
        3 Pack of Wonders
        2 Treasure Trove
        1 Turn to Dust
        1 Gust

        Battlefields:
        1 Frozen Fortress
        1 Sigil of the Storm
        1 Rockfall Path

        Rune Pool:
        5 Mind Rune
        7 Chaos Rune

        Sideboard:
        1 Turn to Dust
        1 Unchecked Power
        1 Singularity
        1 Acceptable Losses
        1 Abandon
        1 Tail-Cloaked Matriarch
        1 Angler Beast
        3 Pickpocket
        """
    }
}
