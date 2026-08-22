import Foundation
import GRDB

public extension GRDBRiftBuilderRepository {
    func deckCardOriginLots(deckID: UUID) async throws -> [DeckCardOriginLot] {
        try await databaseWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM deck_card_origin
                WHERE deck_id = ?
                ORDER BY created_at, previous_location_key, product_id, id
                """, arguments: [deckID.uuidString]).map(Self.deckCardOriginLot(from:))
        }
    }

    func consumeDeckCardOrigins(deckID: UUID, movements: [PlannedInventoryMovement]) async throws {
        try await databaseWriter.write { db in
            for movement in movements where movement.quantity > 0 {
                guard let originLotID = movement.originLotID else { continue }
                try Self.consumeOrigin(id: originLotID, quantity: movement.quantity, in: db)
            }
        }
    }
}

extension GRDBRiftBuilderRepository {
    static func deckCardOriginLot(from row: Row) throws -> DeckCardOriginLot {
        let idValue: String = row["id"]
        let deckIDValue: String = row["deck_id"]
        guard let id = UUID(uuidString: idValue), let deckID = UUID(uuidString: deckIDValue) else {
            throw DatabaseError(message: "Invalid persisted deck card origin")
        }
        return DeckCardOriginLot(
            id: id,
            deckID: deckID,
            nameSlug: row["name_slug"],
            productID: row["product_id"],
            finish: row["finish"],
            language: row["language"],
            previousLocationKey: row["previous_location_key"],
            previousLocationName: row["previous_location_name"],
            quantity: row["quantity"],
            createdAt: PersistenceCoding.date(from: row["created_at"])
        )
    }

    static func recordOrigin(for movement: PlannedInventoryMovement, deckID: UUID, at date: Date, in db: Database) throws {
        let previousKey = InventoryLocation.normalize(movement.sourceLocationName)
        let finish = movement.finish ?? ""
        let existing = try Row.fetchOne(db, sql: """
            SELECT id, quantity FROM deck_card_origin
            WHERE deck_id = ? AND name_slug = ? AND product_id = ? AND finish = ?
              AND IFNULL(language, '') = IFNULL(?, '') AND previous_location_key = ?
            """, arguments: [deckID.uuidString, movement.nameSlug, movement.productID, finish, movement.language, previousKey])
        if let existing {
            let id: String = existing["id"]
            let quantity: Int = existing["quantity"]
            try db.execute(sql: "UPDATE deck_card_origin SET quantity = ? WHERE id = ?", arguments: [quantity + movement.quantity, id])
        } else {
            try db.execute(sql: """
                INSERT INTO deck_card_origin (
                    id, deck_id, name_slug, product_id, finish, language,
                    previous_location_key, previous_location_name, quantity, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    UUID().uuidString, deckID.uuidString, movement.nameSlug, movement.productID,
                    finish, movement.language, previousKey, movement.sourceLocationName,
                    movement.quantity, PersistenceCoding.date(date),
                ])
        }
    }

    static func consumeOrigin(id: UUID, quantity: Int, in db: Database) throws {
        guard quantity > 0, let current = try Int.fetchOne(db, sql: "SELECT quantity FROM deck_card_origin WHERE id = ?", arguments: [id.uuidString]) else { return }
        if current <= quantity {
            try db.execute(sql: "DELETE FROM deck_card_origin WHERE id = ?", arguments: [id.uuidString])
        } else {
            try db.execute(sql: "UPDATE deck_card_origin SET quantity = ? WHERE id = ?", arguments: [current - quantity, id.uuidString])
        }
    }
}
