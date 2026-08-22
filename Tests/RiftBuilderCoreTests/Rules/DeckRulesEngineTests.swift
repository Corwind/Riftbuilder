import Foundation
import XCTest
@testable import RiftBuilderCore

final class DeckRulesEngineTests: XCTestCase {
    func testBundledRulesetDecodesVersionedMetadata() throws {
        let ruleset = try ConstructedRulesetLoader.bundled()
        XCTAssertEqual(ruleset.id, "constructed-2026-07-16")
        XCTAssertEqual(ruleset.mainDeckCount, 40)
        XCTAssertEqual(ruleset.runeCount, 12)
        XCTAssertFalse(ruleset.bannedCards.isEmpty)
    }

    func testCompleteConstructedDeckPassesAllRules() throws {
        let fixture = makeValidDeck()
        let issues = DeckRulesEngine.validate(snapshot: fixture.snapshot, ruleset: fixture.ruleset)
        XCTAssertTrue(issues.isEmpty, issues.map { "\($0.code): \($0.message)" }.joined(separator: "\n"))
    }

    func testZoneCountsReportEachBoundary() {
        let fixture = makeValidDeck()
        let entries = fixture.snapshot.entries.filter { $0.zone != .rune && $0.zone != .battlefield }
        let snapshot = DeckSnapshot(deck: fixture.snapshot.deck, entries: entries, identities: fixture.snapshot.identities)
        let codes = Set(DeckRulesEngine.validate(snapshot: snapshot, ruleset: fixture.ruleset).map(\.code))
        XCTAssertTrue(codes.contains("rune_count"))
        XCTAssertTrue(codes.contains("battlefield_count"))
        XCTAssertTrue(codes.contains("battlefield_uniqueness"))
    }

    func testCopyLimitIncludesChosenChampionAndSideboard() {
        let fixture = makeValidDeck()
        let championSlug = "chosen"
        let sideboard = DeckEntry(deckID: fixture.snapshot.deck.id, zone: .sideboard, nameSlug: championSlug, quantity: 3)
        let snapshot = DeckSnapshot(
            deck: fixture.snapshot.deck,
            entries: fixture.snapshot.entries + [sideboard],
            identities: fixture.snapshot.identities
        )
        let issues = DeckRulesEngine.validate(snapshot: snapshot, ruleset: fixture.ruleset)
        XCTAssertTrue(issues.contains { $0.code == "copy_limit" && $0.affectedNameSlugs == [championSlug] })
    }

    func testDomainOutsideLegendIdentityIsRejected() {
        var fixture = makeValidDeck()
        fixture.identities["main-0"] = identity("main-0", domains: ["fury"])
        let snapshot = DeckSnapshot(deck: fixture.snapshot.deck, entries: fixture.snapshot.entries, identities: fixture.identities)
        let issues = DeckRulesEngine.validate(snapshot: snapshot, ruleset: fixture.ruleset)
        XCTAssertTrue(issues.contains { $0.code == "domain_identity" && $0.affectedNameSlugs == ["main-0"] })
    }

    func testChosenChampionMustMatchLegendTag() {
        var fixture = makeValidDeck()
        fixture.identities["chosen"] = identity("chosen", tags: ["Garen"])
        let snapshot = DeckSnapshot(deck: fixture.snapshot.deck, entries: fixture.snapshot.entries, identities: fixture.identities)
        XCTAssertTrue(DeckRulesEngine.validate(snapshot: snapshot, ruleset: fixture.ruleset).contains { $0.code == "champion_tag" })
    }

    func testSignatureLimitAndChampionRestriction() {
        var fixture = makeValidDeck()
        fixture.identities["main-0"] = identity(
            "main-0",
            attributes: [
                "isSignature": .bool(true),
                "signatureFor": .string("Garen"),
            ]
        )
        let entries = fixture.snapshot.entries.map { entry in
            guard entry.nameSlug == "main-0" else { return entry }
            var changed = entry
            changed.quantity = 4
            return changed
        }
        let snapshot = DeckSnapshot(deck: fixture.snapshot.deck, entries: entries, identities: fixture.identities)
        let codes = Set(DeckRulesEngine.validate(snapshot: snapshot, ruleset: fixture.ruleset).map(\.code))
        XCTAssertTrue(codes.contains("signature_limit"))
        XCTAssertTrue(codes.contains("signature_restriction"))
    }

    func testBannedCardAndBattlefieldAreRejectedCaseInsensitively() {
        var fixture = makeValidDeck()
        fixture.identities["main-0"] = identity("main-0", displayName: "Called Shot")
        fixture.identities["battlefield-0"] = identity("battlefield-0", displayName: "Dreaming Tree", domains: [])
        let snapshot = DeckSnapshot(deck: fixture.snapshot.deck, entries: fixture.snapshot.entries, identities: fixture.identities)
        let codes = Set(DeckRulesEngine.validate(snapshot: snapshot, ruleset: fixture.ruleset).map(\.code))
        XCTAssertTrue(codes.contains("banned_card"))
        XCTAssertTrue(codes.contains("banned_battlefield"))
    }

    func testSideboardMaximumIsEnforced() {
        let fixture = makeValidDeck()
        let sideboard = DeckEntry(deckID: fixture.snapshot.deck.id, zone: .sideboard, nameSlug: "main-0", quantity: 11)
        let snapshot = DeckSnapshot(deck: fixture.snapshot.deck, entries: fixture.snapshot.entries + [sideboard], identities: fixture.snapshot.identities)
        let codes = Set(DeckRulesEngine.validate(snapshot: snapshot, ruleset: fixture.ruleset).map(\.code))
        XCTAssertTrue(codes.contains("sideboard_count"))
        XCTAssertTrue(codes.contains("copy_limit"))
    }

    func testLegalSetCheckRejectsKnownIllegalAndWarnsOnUnknown() throws {
        var fixture = makeValidDeck()
        fixture.identities["main-0"] = identity("main-0", attributes: ["expansionSlug": .string("future")])
        fixture.identities["main-1"] = identity("main-1")
        let base = fixture.ruleset
        let ruleset = ConstructedRuleset(
            id: base.id,
            name: base.name,
            effectiveDate: base.effectiveDate,
            sourceURL: base.sourceURL,
            mainDeckCount: base.mainDeckCount,
            runeCount: base.runeCount,
            battlefieldCount: base.battlefieldCount,
            maximumCopiesByName: base.maximumCopiesByName,
            maximumSideboardCount: base.maximumSideboardCount,
            maximumSignatureCards: base.maximumSignatureCards,
            bannedCards: base.bannedCards,
            bannedBattlefields: base.bannedBattlefields,
            legalExpansionSlugs: ["origins"]
        )
        let snapshot = DeckSnapshot(deck: fixture.snapshot.deck, entries: fixture.snapshot.entries, identities: fixture.identities)
        let issues = DeckRulesEngine.validate(snapshot: snapshot, ruleset: ruleset)
        XCTAssertTrue(issues.contains { $0.code == "illegal_set" && $0.affectedNameSlugs == ["main-0"] })
        XCTAssertTrue(issues.contains { $0.code == "unknown_set_legality" && $0.affectedNameSlugs == ["main-1"] })
    }

    func testValidationIssueIdentifiersAreDeterministic() {
        let fixture = makeValidDeck()
        let invalid = DeckSnapshot(deck: fixture.snapshot.deck, entries: [], identities: fixture.snapshot.identities)
        let first = DeckRulesEngine.validate(snapshot: invalid, ruleset: fixture.ruleset)
        let second = DeckRulesEngine.validate(snapshot: invalid, ruleset: fixture.ruleset)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }
}

private struct RulesFixture {
    let snapshot: DeckSnapshot
    let ruleset: ConstructedRuleset
    var identities: [String: CardIdentity]
}

private func makeValidDeck() -> RulesFixture {
    let deck = Deck(name: "Valid")
    var identities: [String: CardIdentity] = [:]
    var entries: [DeckEntry] = []

    identities["legend"] = identity("legend", tags: ["Ahri"])
    entries.append(DeckEntry(deckID: deck.id, zone: .legend, nameSlug: "legend", quantity: 1))
    identities["chosen"] = identity("chosen", tags: ["Ahri"])
    entries.append(DeckEntry(deckID: deck.id, zone: .chosenChampion, nameSlug: "chosen", quantity: 1))

    for index in 0..<13 {
        let slug = "main-\(index)"
        identities[slug] = identity(slug)
        entries.append(DeckEntry(deckID: deck.id, zone: .main, nameSlug: slug, quantity: 3))
    }
    for index in 0..<4 {
        let slug = "rune-\(index)"
        identities[slug] = identity(slug)
        entries.append(DeckEntry(deckID: deck.id, zone: .rune, nameSlug: slug, quantity: 3))
    }
    for index in 0..<3 {
        let slug = "battlefield-\(index)"
        identities[slug] = identity(slug, domains: [])
        entries.append(DeckEntry(deckID: deck.id, zone: .battlefield, nameSlug: slug, quantity: 1))
    }

    let ruleset = ConstructedRuleset(
        id: "test",
        name: "Test Constructed",
        effectiveDate: "2026-07-16",
        sourceURL: URL(string: "https://example.com/rules")!,
        mainDeckCount: 40,
        runeCount: 12,
        battlefieldCount: 3,
        maximumCopiesByName: 3,
        maximumSideboardCount: 10,
        maximumSignatureCards: 3,
        bannedCards: ["called shot"],
        bannedBattlefields: ["dreaming tree"]
    )
    return RulesFixture(snapshot: DeckSnapshot(deck: deck, entries: entries, identities: identities), ruleset: ruleset, identities: identities)
}

private func identity(
    _ slug: String,
    displayName: String? = nil,
    domains: [String] = ["calm"],
    tags: [String] = [],
    attributes: [String: JSONValue] = [:]
) -> CardIdentity {
    CardIdentity(
        nameSlug: slug,
        displayName: displayName ?? slug,
        cardType: "Unit",
        domains: domains,
        tags: tags,
        attributes: attributes
    )
}
