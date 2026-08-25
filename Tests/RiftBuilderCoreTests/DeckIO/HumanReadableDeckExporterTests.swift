import XCTest
@testable import RiftBuilderCore

final class HumanReadableDeckExporterTests: XCTestCase {
    func testTextExportUsesRiftDeckClipboardFormat() throws {
        let deck = Deck(name: "Ahri Control", state: .planned, rulesetID: "constructed-test")
        let identities = [
            "legend": CardIdentity(nameSlug: "legend", displayName: "Ahri - Nine-Tailed"),
            "champion": CardIdentity(nameSlug: "champion", displayName: "Ahri - Charmer"),
            "spell": CardIdentity(nameSlug: "spell", displayName: "Called Shot"),
            "rune": CardIdentity(nameSlug: "rune", displayName: "Calm Rune"),
            "field": CardIdentity(nameSlug: "field", displayName: "Dreaming Tree"),
            "side": CardIdentity(nameSlug: "side", displayName: "Backup Plan"),
        ]
        let snapshot = DeckSnapshot(
            deck: deck,
            entries: [
                DeckEntry(deckID: deck.id, zone: .sideboard, nameSlug: "side", quantity: 2),
                DeckEntry(deckID: deck.id, zone: .battlefield, nameSlug: "field", quantity: 1),
                DeckEntry(deckID: deck.id, zone: .rune, nameSlug: "rune", quantity: 12),
                DeckEntry(deckID: deck.id, zone: .main, nameSlug: "spell", quantity: 3, preferredProductID: 42, preferredFinish: "foil", preferredLanguage: "en"),
                DeckEntry(deckID: deck.id, zone: .chosenChampion, nameSlug: "champion", quantity: 1),
                DeckEntry(deckID: deck.id, zone: .legend, nameSlug: "legend", quantity: 1),
            ],
            identities: identities
        )

        XCTAssertEqual(HumanReadableDeckExporter.export(snapshot), """
            Legend:
            1 Ahri, Nine-Tailed

            Champion:
            1 Ahri, Charmer

            MainDeck:
            3 Called Shot

            Battlefields:
            1 Dreaming Tree

            Rune Pool:
            12 Calm Rune

            Sideboard:
            2 Backup Plan
            """ + "\n")

        let reparsed = try TextDeckTextParser.parse(HumanReadableDeckExporter.export(snapshot))
        XCTAssertEqual(reparsed.entries.map { "\($0.zone.rawValue)|\($0.displayName)|\($0.quantity)" }, [
            "legend|Ahri, Nine-Tailed|1",
            "chosenChampion|Ahri, Charmer|1",
            "main|Called Shot|3",
            "battlefield|Dreaming Tree|1",
            "rune|Calm Rune|12",
            "sideboard|Backup Plan|2",
        ])
    }

    func testTextExportFallsBackToSameNameSlugForUnresolvedCards() {
        let deck = Deck(name: "Plan")
        let snapshot = DeckSnapshot(
            deck: deck,
            entries: [DeckEntry(deckID: deck.id, zone: .main, nameSlug: "unknown-card", quantity: 2)],
            identities: [:]
        )
        XCTAssertEqual(HumanReadableDeckExporter.export(snapshot), "MainDeck:\n2 unknown-card\n")
    }
}
