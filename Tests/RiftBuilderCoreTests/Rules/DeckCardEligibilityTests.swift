import XCTest
@testable import RiftBuilderCore

final class DeckCardEligibilityTests: XCTestCase {
    func testDedicatedZonesAcceptOnlyTheirCardRoles() {
        let legend = card("legend", cardType: "Champion Legend", tags: ["Champion"])
        let taggedChampion = card("champion", cardType: "Unit", tags: ["Champion"])
        let typedChampion = card("typed-champion", cardType: "Unit", superType: "CHAMPION")
        let battlefield = card("battlefield", cardType: "Battlefield")
        let rune = card("rune", cardType: "Basic Rune", domains: ["Calm"])
        let unit = card("unit", cardType: "Unit")

        XCTAssertTrue(DeckCardEligibility.allows(legend, in: .legend))
        XCTAssertFalse(DeckCardEligibility.allows(taggedChampion, in: .legend))
        XCTAssertTrue(DeckCardEligibility.allows(taggedChampion, in: .chosenChampion))
        XCTAssertTrue(DeckCardEligibility.allows(typedChampion, in: .chosenChampion))
        XCTAssertFalse(DeckCardEligibility.allows(legend, in: .chosenChampion))
        XCTAssertTrue(DeckCardEligibility.allows(battlefield, in: .battlefield))
        XCTAssertFalse(DeckCardEligibility.allows(unit, in: .battlefield))
        XCTAssertTrue(DeckCardEligibility.allows(rune, in: .rune))
        XCTAssertFalse(DeckCardEligibility.allows(unit, in: .rune))
    }

    func testRuneZoneUsesChosenLegendDomainsWhenAvailable() {
        let calmMindLegend = card("legend", cardType: "Legend", domains: [" calm ", "mind"])
        let calmLegend = card("calm-legend", cardType: "Legend", domains: ["Calm"])
        let calmRune = card("calm-rune", cardType: "Rune", domains: ["CALM"])
        let mindRune = card("mind-rune", cardType: "Rune", domains: ["Mind"])
        let bodyRune = card("body-rune", cardType: "Rune", domains: ["Body"])
        let dualRune = card("dual-rune", cardType: "Rune", domains: ["Calm", "Mind"])
        let unknownRune = card("unknown-rune", cardType: "Rune")

        XCTAssertTrue(DeckCardEligibility.allows(bodyRune, in: .rune))
        XCTAssertTrue(DeckCardEligibility.allows(calmRune, in: .rune, legend: calmMindLegend))
        XCTAssertTrue(DeckCardEligibility.allows(mindRune, in: .rune, legend: calmMindLegend))
        XCTAssertTrue(DeckCardEligibility.allows(dualRune, in: .rune, legend: calmMindLegend))
        XCTAssertFalse(DeckCardEligibility.allows(dualRune, in: .rune, legend: calmLegend))
        XCTAssertFalse(DeckCardEligibility.allows(bodyRune, in: .rune, legend: calmMindLegend))
        XCTAssertFalse(DeckCardEligibility.allows(unknownRune, in: .rune, legend: calmMindLegend))
    }

    func testChosenChampionMustShareATagWithTheChosenLegend() {
        let legend = card("legend", cardType: "Legend", tags: ["Ahri", "Ionia"])
        let matchingChampion = card("matching", cardType: "Unit", tags: ["Champion", "AHRI"])
        let otherChampion = card("other", cardType: "Unit", tags: ["Champion", "Garen"])

        XCTAssertTrue(DeckCardEligibility.allows(matchingChampion, in: .chosenChampion))
        XCTAssertTrue(DeckCardEligibility.allows(otherChampion, in: .chosenChampion))
        XCTAssertTrue(DeckCardEligibility.allows(matchingChampion, in: .chosenChampion, legend: legend))
        XCTAssertFalse(DeckCardEligibility.allows(otherChampion, in: .chosenChampion, legend: legend))
    }

    func testMainDeckAndSideboardExcludeLegendsRunesAndBattlefields() {
        let legend = card("legend", cardType: "Legend")
        let playableCards = [
            card("champion", cardType: "Unit", tags: ["Champion"]),
            card("unit", cardType: "Unit"),
            card("spell", cardType: "Spell"),
            card("gear", cardType: "Gear"),
        ]
        let battlefield = card("battlefield", cardType: "Battlefield")
        let rune = card("rune", cardType: "Rune", domains: ["Calm"])

        XCTAssertFalse(DeckCardEligibility.allows(legend, in: .main))
        XCTAssertFalse(DeckCardEligibility.allows(legend, in: .sideboard))
        XCTAssertFalse(DeckCardEligibility.allows(battlefield, in: .main))
        XCTAssertFalse(DeckCardEligibility.allows(battlefield, in: .sideboard))
        XCTAssertFalse(DeckCardEligibility.allows(rune, in: .main))
        XCTAssertFalse(DeckCardEligibility.allows(rune, in: .sideboard))
        XCTAssertTrue(playableCards.allSatisfy { DeckCardEligibility.allows($0, in: .main) })
        XCTAssertTrue(playableCards.allSatisfy { DeckCardEligibility.allows($0, in: .sideboard) })
    }
}

private func card(
    _ nameSlug: String,
    cardType: String,
    superType: String? = nil,
    tags: [String] = [],
    domains: [String] = []
) -> CardIdentity {
    CardIdentity(
        nameSlug: nameSlug,
        displayName: nameSlug,
        cardType: cardType,
        superType: superType,
        domains: domains,
        tags: tags
    )
}
