import Foundation
import GRDB

/// Read access for line-level assembly planning plus a durable execution journal.
/// It shares the application's GRDB writer but deliberately does not mutate the
/// cached inventory; CardNexus remains the source of truth until the next sync.
public final class GRDBAssemblyStore: AssemblyInventoryProviding, AssemblyExecutionJournaling, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) throws {
        self.databaseWriter = databaseWriter
        try RiftBuilderDatabaseSchema.migrator.migrate(databaseWriter)
    }

    public convenience init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        try self.init(databaseWriter: DatabasePool(path: path, configuration: configuration))
    }

    public func assemblyInventorySnapshot() async throws -> AssemblyInventorySnapshot {
        try await databaseWriter.read { db in
            let lines = try Row.fetchAll(db, sql: "SELECT * FROM inventory_line ORDER BY inventory_id").map(Self.inventoryLine(from:))
            let printings = try Row.fetchAll(db, sql: "SELECT * FROM card_printing ORDER BY product_id").map(Self.printing(from:))
            let policies = try Row.fetchAll(db, sql: "SELECT * FROM location_policy ORDER BY location_key").map(Self.locationPolicy(from:))
            return AssemblyInventorySnapshot(
                lines: lines,
                printingsByProductID: Dictionary(uniqueKeysWithValues: printings.map { ($0.productID, $0) }),
                locationPolicies: policies
            )
        }
    }

    public func saveAssemblyExecution(_ report: AssemblyExecutionReport) async throws {
        let encoded = try PersistenceCoding.encode(report)
        try await databaseWriter.write { db in
            try db.execute(sql: """
                INSERT INTO assembly_execution (plan_id, deck_id, report_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(plan_id) DO UPDATE SET
                    deck_id = excluded.deck_id,
                    report_json = excluded.report_json,
                    updated_at = excluded.updated_at
                """, arguments: [
                    report.planID.uuidString,
                    report.deckID.uuidString,
                    encoded,
                    PersistenceCoding.date(report.updatedAt),
                ])
        }
    }

    public func assemblyExecution(planID: UUID) async throws -> AssemblyExecutionReport? {
        try await databaseWriter.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT report_json FROM assembly_execution WHERE plan_id = ?", arguments: [planID.uuidString]) else {
                return nil
            }
            return try PersistenceCoding.decode(AssemblyExecutionReport.self, from: json)
        }
    }

    public func markAssemblyExecutionReconciled(planID: UUID) async throws {
        try await databaseWriter.write { db in
            try db.execute(sql: "DELETE FROM assembly_execution WHERE plan_id = ?", arguments: [planID.uuidString])
        }
    }
}

private extension GRDBAssemblyStore {
    static func inventoryLine(from row: Row) throws -> InventoryLine {
        InventoryLine(
            inventoryID: row["inventory_id"],
            customID: row["custom_id"],
            productID: row["product_id"],
            finish: row["finish"],
            condition: row["condition"],
            language: row["language"],
            quantity: row["quantity"],
            graded: try (row["graded_json"] as String?).map { try PersistenceCoding.decode(JSONValue.self, from: $0) },
            locationName: row["location_display_name"],
            tags: try PersistenceCoding.decode([String].self, from: row["tags_json"]),
            comment: row["comment"],
            notes: row["notes"],
            isForSale: row["for_sale"],
            listing: try (row["listing_json"] as String?).map { try PersistenceCoding.decode(JSONValue.self, from: $0) },
            updatedAt: PersistenceCoding.date(from: row["remote_updated_at"])
        )
    }

    static func printing(from row: Row) throws -> CardPrinting {
        CardPrinting(
            productID: row["product_id"],
            nameSlug: row["name_slug"],
            printingSlug: row["printing_slug"],
            displayName: row["display_name"],
            expansionID: row["expansion_id"],
            expansionSlug: row["expansion_slug"],
            printNumber: row["print_number"],
            variant: row["variant"],
            rarity: row["rarity"],
            finishes: try PersistenceCoding.decode([String].self, from: row["finishes_json"]),
            languages: try PersistenceCoding.decode([String].self, from: row["languages_json"]),
            imageURL: (row["image_url"] as String?).flatMap(URL.init(string:)),
            imageBackURL: (row["image_back_url"] as String?).flatMap(URL.init(string:)),
            attributes: try PersistenceCoding.decode([String: JSONValue].self, from: row["attributes_json"])
        )
    }

    static func locationPolicy(from row: Row) throws -> LocationPolicy {
        let rawKind: String = row["kind"]
        guard let kind = LocationKind(rawValue: rawKind) else {
            throw DatabaseError(message: "Invalid location kind: \(rawKind)")
        }
        return LocationPolicy(
            normalizedName: row["location_key"],
            displayName: row["display_name"],
            kind: kind,
            countsAsAvailable: row["counts_as_available"],
            linkedDeckID: (row["linked_deck_id"] as String?).flatMap(UUID.init(uuidString:))
        )
    }
}
