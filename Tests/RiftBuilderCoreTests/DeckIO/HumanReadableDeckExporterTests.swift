import XCTest
@testable import RiftBuilderCore

final class HumanReadableDeckExporterTests: XCTestCase {
    func testTextExportUsesZoneOrderNamesCountsAndPreferences() {
        let deck = Deck(name: "Ahri Control", state: .planned, rulesetID: "constructed-test")
        let identities = [
            "legend": CardIdentity(nameSlug: "legend", displayName: "Ahri, Nine-Tailed"),
            "champion": CardIdentity(nameSlug: "champion", displayName: "Ahri, Charmer"),
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
            Ahri Control
            Ruleset: constructed-test
            State: Planned

            Legend (1)
            1x Ahri, Nine-Tailed

            Chosen Champion (1)
            1x Ahri, Charmer

            Main Deck (3)
            3x Called Shot [product 42, foil, en]

            Runes (12)
            12x Calm Rune

            Battlefields (1)
            1x Dreaming Tree

            Sideboard (2)
            2x Backup Plan

            """)
    }

    func testTextExportFallsBackToSameNameSlugForUnresolvedCards() {
        let deck = Deck(name: "Plan")
        let snapshot = DeckSnapshot(
            deck: deck,
            entries: [DeckEntry(deckID: deck.id, zone: .main, nameSlug: "unknown-card", quantity: 2)],
            identities: [:]
        )
        XCTAssertTrue(HumanReadableDeckExporter.export(snapshot).contains("2x unknown-card"))
    }
}
