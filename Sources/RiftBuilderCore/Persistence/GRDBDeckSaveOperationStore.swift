import Foundation
import GRDB

public enum DeckSaveOperationStoreError: Error, Hashable, Sendable {
    case draftNotFound(UUID)
    case draftChanged(UUID)
    case operationNotFound(UUID)
    case operationMismatch(UUID)
}

extension DeckSaveOperationStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .draftNotFound(deckID): return "No editing draft exists for deck \(deckID.uuidString)."
        case let .draftChanged(deckID): return "Deck \(deckID.uuidString) changed after this save review was created. Review the updated movements before saving."
        case let .operationNotFound(operationID): return "Save operation \(operationID.uuidString) is no longer pending."
        case let .operationMismatch(operationID): return "Save operation \(operationID.uuidString) does not match this deck."
        }
    }
}

extension GRDBRiftBuilderRepository: DeckSaveOperationStoring {
    public func saveDeckSaveOperation(_ operation: DeckSaveOperation) async throws {
        try await databaseWriter.write { db in
            let deckID = operation.plan.deckID
            guard let draftUpdatedAtValue = try String.fetchOne(db, sql: "SELECT updated_at FROM deck_draft WHERE deck_id = ?", arguments: [deckID.uuidString]) else {
                throw DeckSaveOperationStoreError.draftNotFound(deckID)
            }
            guard PersistenceCoding.date(from: draftUpdatedAtValue) == operation.draftUpdatedAt else {
                throw DeckSaveOperationStoreError.draftChanged(deckID)
            }
            try db.execute(sql: """
                INSERT INTO deck_save_operation (operation_id, deck_id, draft_updated_at, plan_json, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(deck_id) DO UPDATE SET
                    operation_id = excluded.operation_id,
                    draft_updated_at = excluded.draft_updated_at,
                    plan_json = excluded.plan_json,
                    created_at = excluded.created_at
                """, arguments: [
                    operation.id.uuidString,
                    deckID.uuidString,
                    PersistenceCoding.date(operation.draftUpdatedAt),
                    try PersistenceCoding.encode(operation.plan),
                    PersistenceCoding.date(operation.createdAt),
                ])
        }
    }

    public func deckSaveOperation(deckID: UUID) async throws -> DeckSaveOperation? {
        try await databaseWriter.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM deck_save_operation WHERE deck_id = ?", arguments: [deckID.uuidString]) else { return nil }
            let plan = try PersistenceCoding.decode(DeckSavePlan.self, from: row["plan_json"])
            return DeckSaveOperation(
                plan: plan,
                draftUpdatedAt: PersistenceCoding.date(from: row["draft_updated_at"]),
                createdAt: PersistenceCoding.date(from: row["created_at"])
            )
        }
    }

    public func finalizeDeckSaveOperation(deckID: UUID, operationID: UUID, at date: Date = Date()) async throws -> DeckSnapshot? {
        try await databaseWriter.write { db in
            guard let operation = try Row.fetchOne(db, sql: "SELECT * FROM deck_save_operation WHERE operation_id = ?", arguments: [operationID.uuidString]) else {
                throw DeckSaveOperationStoreError.operationNotFound(operationID)
            }
            let operationDeckID: String = operation["deck_id"]
            guard operationDeckID == deckID.uuidString else { throw DeckSaveOperationStoreError.operationMismatch(operationID) }
            guard let draftUpdatedAtValue = try String.fetchOne(db, sql: "SELECT updated_at FROM deck_draft WHERE deck_id = ?", arguments: [deckID.uuidString]) else {
                throw DeckSaveOperationStoreError.draftNotFound(deckID)
            }
            let reviewedDraftUpdatedAt: String = operation["draft_updated_at"]
            guard draftUpdatedAtValue == reviewedDraftUpdatedAt else { throw DeckSaveOperationStoreError.draftChanged(deckID) }

            try db.execute(sql: "DELETE FROM deck_entry WHERE deck_id = ?", arguments: [deckID.uuidString])
            try db.execute(sql: """
                INSERT INTO deck_entry (
                    id, deck_id, zone, name_slug, quantity, preferred_product_id,
                    preferred_finish, preferred_language
                )
                SELECT id, deck_id, zone, name_slug, quantity, preferred_product_id,
                       preferred_finish, preferred_language
                FROM deck_draft_entry
                WHERE deck_id = ?
                """, arguments: [deckID.uuidString])
            try db.execute(sql: "UPDATE deck SET updated_at = ? WHERE id = ?", arguments: [PersistenceCoding.date(date), deckID.uuidString])
            try db.execute(sql: "DELETE FROM deck_draft WHERE deck_id = ?", arguments: [deckID.uuidString])
            try db.execute(sql: "DELETE FROM deck_save_operation WHERE operation_id = ?", arguments: [operationID.uuidString])
            return try Self.deckSnapshot(id: deckID, in: db)
        }
    }
}
