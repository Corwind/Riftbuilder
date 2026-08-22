import Foundation
import GRDB

public extension GRDBRiftBuilderRepository {
    func deckDraftSnapshot(id: UUID) async throws -> DeckDraftSnapshot? {
        try await databaseWriter.read { db in
            try Self.deckDraftSnapshot(id: id, in: db)
        }
    }

    func beginDeckDraft(id: UUID, at date: Date = Date()) async throws -> DeckDraftSnapshot? {
        try await databaseWriter.write { db in
            if try Row.fetchOne(db, sql: "SELECT deck_id FROM deck_draft WHERE deck_id = ?", arguments: [id.uuidString]) == nil {
                guard let deckRow = try Row.fetchOne(db, sql: "SELECT * FROM deck WHERE id = ?", arguments: [id.uuidString]) else {
                    return nil
                }
                let deck = try Self.deck(from: deckRow)
                let timestamp = PersistenceCoding.date(date)
                try db.execute(sql: """
                    INSERT INTO deck_draft (deck_id, base_deck_updated_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [id.uuidString, PersistenceCoding.date(deck.updatedAt), timestamp, timestamp])
                try db.execute(sql: """
                    INSERT INTO deck_draft_entry (
                        id, deck_id, zone, name_slug, quantity, preferred_product_id,
                        preferred_finish, preferred_language
                    )
                    SELECT id, deck_id, zone, name_slug, quantity, preferred_product_id,
                           preferred_finish, preferred_language
                    FROM deck_entry
                    WHERE deck_id = ?
                    """, arguments: [id.uuidString])
            }
            return try Self.deckDraftSnapshot(id: id, in: db)
        }
    }

    func saveDeckDraftEntry(_ entry: DeckEntry, at date: Date = Date()) async throws {
        try await databaseWriter.write { db in
            guard try Row.fetchOne(db, sql: "SELECT deck_id FROM deck_draft WHERE deck_id = ?", arguments: [entry.deckID.uuidString]) != nil else {
                throw DatabaseError(message: "A deck draft must be started before it can be edited")
            }
            try Self.upsertDraftEntry(entry, in: db)
            try Self.touchDraft(deckID: entry.deckID, at: date, in: db)
        }
    }

    func deleteDeckDraftEntry(id: UUID, at date: Date = Date()) async throws {
        try await databaseWriter.write { db in
            let deckIDValue = try String.fetchOne(db, sql: "SELECT deck_id FROM deck_draft_entry WHERE id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM deck_draft_entry WHERE id = ?", arguments: [id.uuidString])
            if let deckIDValue, let deckID = UUID(uuidString: deckIDValue) {
                try Self.touchDraft(deckID: deckID, at: date, in: db)
            }
        }
    }

    func discardDeckDraft(id: UUID) async throws {
        try await databaseWriter.write { db in
            try db.execute(sql: "DELETE FROM deck_draft WHERE deck_id = ?", arguments: [id.uuidString])
        }
    }

    func commitDeckDraft(id: UUID, at date: Date = Date()) async throws -> DeckSnapshot? {
        try await databaseWriter.write { db in
            guard try Row.fetchOne(db, sql: "SELECT deck_id FROM deck_draft WHERE deck_id = ?", arguments: [id.uuidString]) != nil else {
                return nil
            }
            try db.execute(sql: "DELETE FROM deck_entry WHERE deck_id = ?", arguments: [id.uuidString])
            try db.execute(sql: """
                INSERT INTO deck_entry (
                    id, deck_id, zone, name_slug, quantity, preferred_product_id,
                    preferred_finish, preferred_language
                )
                SELECT id, deck_id, zone, name_slug, quantity, preferred_product_id,
                       preferred_finish, preferred_language
                FROM deck_draft_entry
                WHERE deck_id = ?
                """, arguments: [id.uuidString])
            try db.execute(sql: "UPDATE deck SET updated_at = ? WHERE id = ?", arguments: [PersistenceCoding.date(date), id.uuidString])
            try db.execute(sql: "DELETE FROM deck_draft WHERE deck_id = ?", arguments: [id.uuidString])
            return try Self.deckSnapshot(id: id, in: db)
        }
    }
}

extension GRDBRiftBuilderRepository {
    static func deckSnapshot(id: UUID, in db: Database) throws -> DeckSnapshot? {
        guard let deckRow = try Row.fetchOne(db, sql: "SELECT * FROM deck WHERE id = ?", arguments: [id.uuidString]) else {
            return nil
        }
        let deck = try deck(from: deckRow)
        let entries = try Row.fetchAll(db, sql: """
            SELECT * FROM deck_entry
            WHERE deck_id = ?
            ORDER BY zone, name_slug, id
            """, arguments: [id.uuidString]).map(deckEntry(from:))
        return DeckSnapshot(deck: deck, entries: entries, identities: try identities(for: entries, in: db))
    }

    static func deckDraftSnapshot(id: UUID, in db: Database) throws -> DeckDraftSnapshot? {
        guard let draftRow = try Row.fetchOne(db, sql: "SELECT * FROM deck_draft WHERE deck_id = ?", arguments: [id.uuidString]),
              let deckRow = try Row.fetchOne(db, sql: "SELECT * FROM deck WHERE id = ?", arguments: [id.uuidString])
        else {
            return nil
        }
        let entries = try Row.fetchAll(db, sql: """
            SELECT * FROM deck_draft_entry
            WHERE deck_id = ?
            ORDER BY zone, name_slug, id
            """, arguments: [id.uuidString]).map(deckEntry(from:))
        return DeckDraftSnapshot(
            deck: try deck(from: deckRow),
            entries: entries,
            identities: try identities(for: entries, in: db),
            baseDeckUpdatedAt: PersistenceCoding.date(from: draftRow["base_deck_updated_at"]),
            createdAt: PersistenceCoding.date(from: draftRow["created_at"]),
            updatedAt: PersistenceCoding.date(from: draftRow["updated_at"])
        )
    }

    static func identities(for entries: [DeckEntry], in db: Database) throws -> [String: CardIdentity] {
        var result: [String: CardIdentity] = [:]
        for slug in Set(entries.map(\.nameSlug)) {
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card_identity WHERE name_slug = ?", arguments: [slug]) else { continue }
            result[slug] = try identity(from: row)
        }
        return result
    }

    static func upsertDraftEntry(_ entry: DeckEntry, in db: Database) throws {
        let oldRow = try Row.fetchOne(db, sql: "SELECT * FROM deck_draft_entry WHERE id = ?", arguments: [entry.id.uuidString])
        let matchingRow = try Row.fetchOne(db, sql: """
            SELECT * FROM deck_draft_entry
            WHERE deck_id = ? AND zone = ? AND name_slug = ?
              AND IFNULL(preferred_product_id, -1) = IFNULL(?, -1)
              AND IFNULL(preferred_finish, '') = IFNULL(?, '')
              AND IFNULL(preferred_language, '') = IFNULL(?, '')
              AND id <> ?
            LIMIT 1
            """, arguments: [
                entry.deckID.uuidString, entry.zone.rawValue, entry.nameSlug,
                entry.preferredProductID, entry.preferredFinish, entry.preferredLanguage,
                entry.id.uuidString,
            ])
        if let matchingRow {
            let matchingID: String = matchingRow["id"]
            let matchingQuantity: Int = matchingRow["quantity"]
            if oldRow != nil {
                try db.execute(sql: "DELETE FROM deck_draft_entry WHERE id = ?", arguments: [entry.id.uuidString])
            }
            try db.execute(sql: "UPDATE deck_draft_entry SET quantity = ? WHERE id = ?", arguments: [matchingQuantity + entry.quantity, matchingID])
            return
        }
        try db.execute(sql: """
            INSERT INTO deck_draft_entry (
                id, deck_id, zone, name_slug, quantity, preferred_product_id,
                preferred_finish, preferred_language
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                deck_id = excluded.deck_id,
                zone = excluded.zone,
                name_slug = excluded.name_slug,
                quantity = excluded.quantity,
                preferred_product_id = excluded.preferred_product_id,
                preferred_finish = excluded.preferred_finish,
                preferred_language = excluded.preferred_language
            """, arguments: [
                entry.id.uuidString, entry.deckID.uuidString, entry.zone.rawValue,
                entry.nameSlug, entry.quantity, entry.preferredProductID,
                entry.preferredFinish, entry.preferredLanguage,
            ])
    }

    static func touchDraft(deckID: UUID, at date: Date, in db: Database) throws {
        try db.execute(sql: "UPDATE deck_draft SET updated_at = ? WHERE deck_id = ?", arguments: [PersistenceCoding.date(date), deckID.uuidString])
    }
}
