import Foundation
import GRDB

public enum DeckLocationImportPersistenceError: Error, Hashable, Sendable {
    case locationNotFound(String)
    case locationMustBeClassifiedAsDeck(String)
    case locationAlreadyLinked(String, UUID)
}

extension DeckLocationImportPersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .locationNotFound(name): return "The location '\(name)' is no longer available. Synchronize and try again."
        case let .locationMustBeClassifiedAsDeck(name): return "The location '\(name)' must be classified as Deck before it can be imported."
        case let .locationAlreadyLinked(name, _): return "The location '\(name)' is already linked to a deck."
        }
    }
}

public extension GRDBRiftBuilderRepository {
    /// Saves the inferred legal definition and links its source location in one
    /// transaction, so neither object can survive without the other.
    func importDeckSnapshot(_ snapshot: DeckSnapshot, fromLocationKey locationKey: String) async throws {
        try await databaseWriter.write { db in
            guard let location = try Row.fetchOne(db, sql: "SELECT display_name, kind, linked_deck_id FROM location_policy WHERE location_key = ?", arguments: [locationKey]) else {
                throw DeckLocationImportPersistenceError.locationNotFound(locationKey)
            }
            let displayName: String = location["display_name"]
            let kind: String = location["kind"]
            guard kind == LocationKind.deck.rawValue else {
                throw DeckLocationImportPersistenceError.locationMustBeClassifiedAsDeck(displayName)
            }
            if let linkedValue: String = location["linked_deck_id"], let linkedDeckID = UUID(uuidString: linkedValue) {
                throw DeckLocationImportPersistenceError.locationAlreadyLinked(displayName, linkedDeckID)
            }

            let deck = snapshot.deck
            try db.execute(sql: """
                INSERT INTO deck (id, name, state, ruleset_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    deck.id.uuidString,
                    deck.name,
                    deck.state.rawValue,
                    deck.rulesetID,
                    PersistenceCoding.date(deck.createdAt),
                    PersistenceCoding.date(deck.updatedAt),
                ])
            for entry in snapshot.entries {
                try db.execute(sql: """
                    INSERT INTO deck_entry (
                        id, deck_id, zone, name_slug, quantity, preferred_product_id,
                        preferred_finish, preferred_language
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        entry.id.uuidString,
                        deck.id.uuidString,
                        entry.zone.rawValue,
                        entry.nameSlug,
                        entry.quantity,
                        entry.preferredProductID,
                        entry.preferredFinish,
                        entry.preferredLanguage,
                    ])
            }
            try db.execute(sql: """
                UPDATE location_policy
                SET linked_deck_id = ?, counts_as_available = 0
                WHERE location_key = ?
                """, arguments: [deck.id.uuidString, locationKey])
        }
    }
}
