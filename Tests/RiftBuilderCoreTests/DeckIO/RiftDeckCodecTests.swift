import Foundation
import XCTest
@testable import RiftBuilderCore

final class RiftDeckCodecTests: XCTestCase {
    func testRoundTripUsesPortableDeckFieldsAndFreshLocalIdentifiers() throws {
        let originalDeckID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let importedDeckID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let importedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = CardIdentity(nameSlug: "ahri-charmer", displayName: "Ahri, Charmer")
        let snapshot = DeckSnapshot(
            deck: Deck(id: originalDeckID, name: "Ahri Control", state: .assembled, rulesetID: "constructed-test"),
            entries: [
                DeckEntry(
                    deckID: originalDeckID,
                    zone: .main,
                    nameSlug: identity.nameSlug,
                    quantity: 3,
                    preferredProductID: 42,
                    preferredFinish: "foil",
                    preferredLanguage: "en"
                ),
            ],
            identities: [identity.nameSlug: identity]
        )

        let data = try RiftDeckCodec.encode(snapshot: snapshot, exportedAt: exportedAt)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(originalDeckID.uuidString))
        XCTAssertFalse(json.contains(snapshot.entries[0].id.uuidString))
        XCTAssertTrue(json.contains("ahri-charmer"))

        let decoded = try RiftDeckCodec.decodeSnapshot(
            from: data,
            deckID: importedDeckID,
            importedAt: importedAt,
            identities: snapshot.identities
        )
        XCTAssertEqual(decoded.deck.id, importedDeckID)
        XCTAssertEqual(decoded.deck.name, "Ahri Control")
        XCTAssertEqual(decoded.deck.state, .assembled)
        XCTAssertEqual(decoded.deck.rulesetID, "constructed-test")
        XCTAssertEqual(decoded.deck.createdAt, importedAt)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries[0].deckID, importedDeckID)
        XCTAssertEqual(decoded.entries[0].nameSlug, "ahri-charmer")
        XCTAssertEqual(decoded.entries[0].preferredProductID, 42)
        XCTAssertEqual(decoded.identities, snapshot.identities)
    }

    func testDuplicateLogicalEntriesAreCoalescedAndPreferencesAreNormalized() throws {
        let document = RiftDeckDocument(
            exportedAt: .now,
            deck: .init(name: " Deck ", state: .planned, rulesetID: " rules "),
            entries: [
                .init(zone: .main, nameSlug: " ahri ", quantity: 1, preferredFinish: " foil ", preferredLanguage: " en "),
                .init(zone: .main, nameSlug: "ahri", quantity: 2, preferredFinish: "foil", preferredLanguage: "en"),
                .init(zone: .main, nameSlug: "ahri", quantity: 1, preferredFinish: "standard", preferredLanguage: "en"),
            ]
        )
        let data = try encode(document)
        let decoded = try RiftDeckCodec.decodeDocument(from: data)
        XCTAssertEqual(decoded.deck.name, "Deck")
        XCTAssertEqual(decoded.deck.rulesetID, "rules")
        XCTAssertEqual(decoded.entries.count, 2)
        XCTAssertEqual(decoded.entries[0].quantity, 3)
        XCTAssertEqual(decoded.entries[0].preferredFinish, "foil")
        XCTAssertEqual(decoded.entries[1].quantity, 1)
    }

    func testUnsupportedVersionProducesStructuredError() throws {
        let document = RiftDeckDocument(
            formatVersion: 99,
            exportedAt: .now,
            deck: .init(name: "Deck", state: .planned, rulesetID: "rules"),
            entries: []
        )
        XCTAssertThrowsError(try RiftDeckCodec.decodeDocument(from: encode(document))) { error in
            XCTAssertEqual(
                error as? RiftDeckCodecError,
                .unsupportedFormatVersion(found: 99, supported: RiftDeckDocument.currentFormatVersion)
            )
        }
    }

    func testInvalidQuantitiesAndIdentifiersProduceStructuredErrors() throws {
        let invalidQuantity = RiftDeckDocument(
            exportedAt: .now,
            deck: .init(name: "Deck", state: .planned, rulesetID: "rules"),
            entries: [.init(zone: .main, nameSlug: "ahri", quantity: 0)]
        )
        XCTAssertThrowsError(try RiftDeckCodec.decodeDocument(from: encode(invalidQuantity))) { error in
            XCTAssertEqual(error as? RiftDeckCodecError, .invalidQuantity(entryIndex: 0, quantity: 0))
        }

        let invalidProduct = RiftDeckDocument(
            exportedAt: .now,
            deck: .init(name: "Deck", state: .planned, rulesetID: "rules"),
            entries: [.init(zone: .main, nameSlug: "ahri", quantity: 1, preferredProductID: -1)]
        )
        XCTAssertThrowsError(try RiftDeckCodec.decodeDocument(from: encode(invalidProduct))) { error in
            XCTAssertEqual(error as? RiftDeckCodecError, .invalidPreferredProductID(entryIndex: 0, productID: -1))
        }
    }

    func testMalformedJSONProducesStructuredError() {
        XCTAssertThrowsError(try RiftDeckCodec.decodeDocument(from: Data("not json".utf8))) { error in
            guard case .malformedDocument = error as? RiftDeckCodecError else {
                return XCTFail("Expected malformedDocument, received \(error)")
            }
        }
    }

    func testUnresolvedCardsRemainEntriesAndAreDiscoverableFromDocument() throws {
        let document = RiftDeckDocument(
            exportedAt: .now,
            deck: .init(name: "Deck", state: .planned, rulesetID: "rules"),
            entries: [
                .init(zone: .main, nameSlug: "known", quantity: 1),
                .init(zone: .main, nameSlug: "missing", quantity: 1),
            ]
        )
        let data = try encode(document)
        let known = CardIdentity(nameSlug: "known", displayName: "Known")
        let snapshot = try RiftDeckCodec.decodeSnapshot(from: data, identities: [known.nameSlug: known])
        XCTAssertEqual(Set(snapshot.entries.map(\.nameSlug)), ["known", "missing"])
        XCTAssertEqual(Set(snapshot.identities.keys), ["known"])
        let decodedDocument = try RiftDeckCodec.decodeDocument(from: data)
        XCTAssertEqual(decodedDocument.referencedNameSlugs.subtracting(snapshot.identities.keys), ["missing"])
    }
}

private func encode(_ document: RiftDeckDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(document)
}
