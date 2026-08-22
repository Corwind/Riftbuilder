import Foundation
import XCTest
@testable import RiftBuilderCore

final class DeckLocationImporterTests: XCTestCase {
    func testDeckLocationIsInferredIntoLegalZonesDeterministically() throws {
        let fixture = importFixture()
        let first = try DeckLocationImporter().makeCandidate(fixture.request)
        let reversedInventory = AssemblyInventorySnapshot(
            lines: Array(fixture.request.inventory.lines.reversed()),
            printingsByProductID: fixture.request.inventory.printingsByProductID,
            locationPolicies: fixture.request.inventory.locationPolicies
        )
        let second = try DeckLocationImporter().makeCandidate(DeckLocationImportRequest(
            deckID: fixture.request.deckID,
            deckName: fixture.request.deckName,
            location: fixture.request.location,
            inventory: reversedInventory,
            identities: fixture.request.identities,
            ruleset: fixture.request.ruleset,
            createdAt: fixture.request.createdAt
        ))

        XCTAssertTrue(first.canSave)
        XCTAssertFalse(first.validationIssues.contains { $0.severity == .error })
        XCTAssertEqual(quantity(in: .legend, entries: first.snapshot.entries), 1)
        XCTAssertEqual(quantity(in: .chosenChampion, entries: first.snapshot.entries), 1)
        XCTAssertEqual(quantity(in: .main, entries: first.snapshot.entries), 39)
        XCTAssertEqual(quantity(in: .rune, entries: first.snapshot.entries), 12)
        XCTAssertEqual(quantity(in: .battlefield, entries: first.snapshot.entries), 3)
        XCTAssertEqual(first.snapshot.entries.first { $0.zone == .chosenChampion }?.nameSlug, "chosen-champion")
        XCTAssertEqual(logicalEntries(first.snapshot.entries), logicalEntries(second.snapshot.entries))
    }

    func testOnlyUnlinkedDeckClassifiedLocationsCanBeImported() throws {
        let fixture = importFixture()
        let storage = LocationPolicy(normalizedName: "scanned deck", displayName: "Scanned Deck", kind: .storage, countsAsAvailable: true)
        XCTAssertThrowsError(try DeckLocationImporter().makeCandidate(DeckLocationImportRequest(
            deckID: fixture.request.deckID,
            deckName: fixture.request.deckName,
            location: storage,
            inventory: fixture.request.inventory,
            identities: fixture.request.identities,
            ruleset: fixture.request.ruleset
        ))) { error in
            XCTAssertEqual(error as? DeckLocationImportError, .locationMustBeClassifiedAsDeck("Scanned Deck"))
        }

        let existingDeckID = UUID()
        var linked = fixture.request.location
        linked.linkedDeckID = existingDeckID
        XCTAssertThrowsError(try DeckLocationImporter().makeCandidate(DeckLocationImportRequest(
            deckName: fixture.request.deckName,
            location: linked,
            inventory: fixture.request.inventory,
            identities: fixture.request.identities,
            ruleset: fixture.request.ruleset
        ))) { error in
            XCTAssertEqual(error as? DeckLocationImportError, .locationAlreadyLinked("Scanned Deck", existingDeckID))
        }
    }

    func testIllegalInferenceIsReportedInsteadOfBeingSaveable() throws {
        let fixture = importFixture()
        let inventoryWithoutBattlefields = AssemblyInventorySnapshot(
            lines: fixture.request.inventory.lines.filter { line in
                guard let printing = fixture.request.inventory.printingsByProductID[line.productID] else { return false }
                return !printing.nameSlug.hasPrefix("battlefield-")
            },
            printingsByProductID: fixture.request.inventory.printingsByProductID,
            locationPolicies: fixture.request.inventory.locationPolicies
        )
        let result = try DeckLocationImporter().makeCandidate(DeckLocationImportRequest(
            deckID: fixture.request.deckID,
            deckName: fixture.request.deckName,
            location: fixture.request.location,
            inventory: inventoryWithoutBattlefields,
            identities: fixture.request.identities,
            ruleset: fixture.request.ruleset
        ))

        XCTAssertFalse(result.canSave)
        XCTAssertTrue(result.validationIssues.contains { $0.code == "battlefield_count" && $0.severity == .error })
    }
}

private struct ImportFixture {
    let request: DeckLocationImportRequest
}

private func importFixture() -> ImportFixture {
    let deckID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    let location = LocationPolicy(normalizedName: "scanned deck", displayName: "Scanned Deck", kind: .deck, countsAsAvailable: false)
    var identities: [String: CardIdentity] = [:]
    var printings: [Int64: CardPrinting] = [:]
    var lines: [InventoryLine] = []
    var productID: Int64 = 1

    func add(_ identity: CardIdentity, quantity: Int) {
        identities[identity.nameSlug] = identity
        printings[productID] = CardPrinting(productID: productID, nameSlug: identity.nameSlug, printingSlug: "\(identity.nameSlug)-\(productID)", displayName: identity.displayName)
        lines.append(InventoryLine(inventoryID: "line-\(productID)", productID: productID, finish: "normal", language: "en", quantity: quantity, locationName: "Scanned Deck", updatedAt: .distantPast))
        productID += 1
    }

    add(CardIdentity(nameSlug: "legend", displayName: "Legend", cardType: "Legend", domains: ["Calm"], tags: ["Champion", "Ahri"]), quantity: 1)
    add(CardIdentity(nameSlug: "chosen-champion", displayName: "Chosen Champion", cardType: "Champion Unit", domains: ["Calm"], tags: ["Champion", "Ahri"]), quantity: 1)
    for index in 1 ... 13 {
        add(CardIdentity(nameSlug: "main-\(index)", displayName: "Main \(index)", cardType: "Unit", domains: ["Calm"]), quantity: 3)
    }
    add(CardIdentity(nameSlug: "calm-rune", displayName: "Calm Rune", cardType: "Rune", domains: ["Calm"]), quantity: 12)
    for index in 1 ... 3 {
        add(CardIdentity(nameSlug: "battlefield-\(index)", displayName: "Battlefield \(index)", cardType: "Battlefield"), quantity: 1)
    }

    let ruleset = ConstructedRuleset(
        id: "test-constructed",
        name: "Test Constructed",
        effectiveDate: "2026-08-22",
        sourceURL: URL(string: "https://example.com/rules")!,
        mainDeckCount: 40,
        runeCount: 12,
        battlefieldCount: 3,
        maximumCopiesByName: 3,
        maximumSideboardCount: 10,
        maximumSignatureCards: 6
    )
    return ImportFixture(request: DeckLocationImportRequest(
        deckID: deckID,
        deckName: "Imported Deck",
        location: location,
        inventory: AssemblyInventorySnapshot(lines: lines, printingsByProductID: printings, locationPolicies: [location]),
        identities: identities,
        ruleset: ruleset,
        createdAt: Date(timeIntervalSince1970: 100)
    ))
}

private func quantity(in zone: DeckZone, entries: [DeckEntry]) -> Int {
    entries.filter { $0.zone == zone }.reduce(0) { $0 + $1.quantity }
}

private func logicalEntries(_ entries: [DeckEntry]) -> [String] {
    entries.map { "\($0.zone.rawValue)|\($0.nameSlug)|\($0.quantity)|\($0.preferredProductID ?? -1)|\($0.preferredFinish ?? "")|\($0.preferredLanguage ?? "")" }.sorted()
}
