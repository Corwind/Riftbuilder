import GRDB
import XCTest
@testable import RiftBuilderCore

final class DatabaseMigrationTests: XCTestCase {
    func testFreshDatabaseAppliesExactlyTheCanonicalMigrationSequence() throws {
        let databaseQueue = try configuredDatabaseQueue()

        _ = try GRDBRiftBuilderRepository(databaseWriter: databaseQueue)

        let applied = try databaseQueue.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        XCTAssertEqual(applied, RiftBuilderDatabaseSchema.migrationIdentifiers)
    }

    func testEveryHistoricalMigrationBoundaryUpgradesToCurrentAndPreservesData() throws {
        for startingMigration in RiftBuilderDatabaseSchema.migrationIdentifiers.dropLast() {
            let databaseQueue = try configuredDatabaseQueue()
            try RiftBuilderDatabaseSchema.migrator.migrate(
                databaseQueue,
                upTo: startingMigration
            )
            try seedCompatibilityFixture(in: databaseQueue, marker: startingMigration)

            _ = try GRDBRiftBuilderRepository(databaseWriter: databaseQueue)

            let verification = try databaseQueue.read { db in
                (
                    marker: try String.fetchOne(
                        db,
                        sql: "SELECT value FROM app_metadata WHERE key = 'migration-test'"
                    ),
                    printingName: try String.fetchOne(
                        db,
                        sql: "SELECT display_name FROM card_printing WHERE product_id = 42"
                    ),
                    applied: Set(try String.fetchAll(
                        db,
                        sql: "SELECT identifier FROM grdb_migrations"
                    )),
                    integrity: try String.fetchOne(db, sql: "PRAGMA integrity_check"),
                    foreignKeyViolations: try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                )
            }

            XCTAssertEqual(
                verification.marker,
                startingMigration,
                "Data was not preserved when upgrading from \(startingMigration)"
            )
            XCTAssertEqual(verification.printingName, "Migration Sentinel")
            XCTAssertEqual(
                verification.applied,
                Set(RiftBuilderDatabaseSchema.migrationIdentifiers),
                "Migration history is incomplete after upgrading from \(startingMigration)"
            )
            XCTAssertEqual(verification.integrity, "ok")
            XCTAssertTrue(
                verification.foreignKeyViolations.isEmpty,
                "Foreign-key violations were introduced when upgrading from \(startingMigration)"
            )
        }
    }

    func testRunningCurrentMigrationsAgainIsIdempotent() throws {
        let databaseQueue = try configuredDatabaseQueue()
        _ = try GRDBRiftBuilderRepository(databaseWriter: databaseQueue)
        try seedCompatibilityFixture(in: databaseQueue, marker: "current")

        _ = try GRDBRiftBuilderRepository(databaseWriter: databaseQueue)

        let marker = try databaseQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM app_metadata WHERE key = 'migration-test'"
            )
        }
        XCTAssertEqual(marker, "current")
    }

    func testRepositoryLaunchUpgradesV1DatabaseAndPreservesExistingData() throws {
        let databaseQueue = try configuredDatabaseQueue()
        try RiftBuilderDatabaseSchema.migrator.migrate(databaseQueue, upTo: "v1_initial")
        try databaseQueue.write { db in
            try db.execute(
                sql: "INSERT INTO app_metadata (key, value) VALUES (?, ?)",
                arguments: ["legacy-key", "legacy-value"]
            )
        }

        _ = try GRDBRiftBuilderRepository(databaseWriter: databaseQueue)

        let migrated = try databaseQueue.read { db in
            (
                metadata: try String.fetchOne(
                    db,
                    sql: "SELECT value FROM app_metadata WHERE key = ?",
                    arguments: ["legacy-key"]
                ),
                hasCardmarketListing: try db.tableExists("cardmarket_listing"),
                hasCardmarketPrice: try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'view' AND name = 'cardmarket_price')"
                ) ?? false,
                listingColumns: Set(try db.columns(in: "cardmarket_listing").map(\.name))
            )
        }

        XCTAssertEqual(migrated.metadata, "legacy-value")
        XCTAssertTrue(migrated.hasCardmarketListing)
        XCTAssertTrue(migrated.hasCardmarketPrice)
        XCTAssertEqual(
            migrated.listingColumns,
            [
                "product_id",
                "url",
                "trend_price_eur_cents",
                "average_7_days_price_eur_cents",
                "average_30_days_price_eur_cents",
                "scraped_at",
            ]
        )
    }

    func testCardmarketPricesAreStoredAndSelectedPerExactPrinting() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [
                printing(productID: 101, expansionSlug: "origins-main-set"),
                printing(productID: 202, expansionSlug: "spiritforged"),
                printing(productID: 303, expansionSlug: "vendetta"),
            ],
            checksum: "catalogue",
            completedAt: .now
        )
        try await repository.databaseWriter.write { db in
            try insertListing(
                in: db,
                productID: 101,
                set: "Origins",
                trend: 199,
                average7Days: 180,
                average30Days: 170
            )
            try insertListing(
                in: db,
                productID: 202,
                set: "Spiritforged",
                trend: nil,
                average7Days: 250,
                average30Days: 230
            )
            try insertListing(
                in: db,
                productID: 303,
                set: "Vendetta",
                trend: nil,
                average7Days: nil,
                average30Days: 310
            )
        }

        let prices = try await repository.databaseWriter.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT product_id, price_cents, price_source FROM cardmarket_price ORDER BY product_id"
            ).map { row in
                SelectedPrice(
                    productID: row["product_id"],
                    priceCents: row["price_cents"],
                    source: row["price_source"]
                )
            }
        }

        XCTAssertEqual(
            prices,
            [
                SelectedPrice(productID: 101, priceCents: 199, source: "trend"),
                SelectedPrice(productID: 202, priceCents: 250, source: "average_7_days"),
                SelectedPrice(productID: 303, priceCents: 310, source: "average_30_days"),
            ]
        )
    }

    func testRepositoryExposesListingsPerPrintingToCatalogueAndOnlyOwnedPrintingToInventory() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [
                printing(productID: 401, expansionSlug: "origins-main-set"),
                printing(productID: 402, expansionSlug: "spiritforged"),
            ],
            checksum: "catalogue",
            completedAt: .now
        )
        try await repository.synchronizeInventory(
            lines: [
                InventoryLine(
                    inventoryID: "owned-origins",
                    productID: 401,
                    finish: "normal",
                    quantity: 1,
                    locationName: "Binder",
                    updatedAt: .now
                ),
            ],
            locations: [InventoryLocation(name: "Binder")],
            generation: UUID(),
            completedAt: .now
        )
        try await repository.databaseWriter.write { db in
            try insertListing(
                in: db,
                productID: 401,
                set: "Origins",
                trend: 199,
                average7Days: 180,
                average30Days: 170
            )
            try insertListing(
                in: db,
                productID: 402,
                set: "Spiritforged",
                trend: nil,
                average7Days: 250,
                average30Days: 230
            )
        }

        let inventoryCards = try await repository.inventoryCards(search: nil, targetDeckID: nil)
        let inventoryCard = try XCTUnwrap(inventoryCards.first)
        XCTAssertEqual(inventoryCard.marketListings.map(\.productID), [401])
        XCTAssertEqual(inventoryCard.marketListings.first?.priceCents, 199)
        XCTAssertEqual(inventoryCard.marketListings.first?.priceSource, .trend)

        let catalogueCards = try await repository.catalogueCards(search: nil)
        let catalogueCard = try XCTUnwrap(catalogueCards.first)
        XCTAssertEqual(catalogueCard.marketListings.map(\.productID), [401, 402])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: catalogueCard.marketListings.map { ($0.productID, $0.priceCents) }),
            [401: 199, 402: 250]
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: catalogueCard.marketListings.map { ($0.productID, $0.priceSource) }),
            [401: .trend, 402: .average7Days]
        )
    }

    func testLegacyDatabaseWithoutSeparateAssemblyMigrationStillUpgrades() throws {
        let databaseQueue = try configuredDatabaseQueue()
        try RiftBuilderDatabaseSchema.migrator.migrate(
            databaseQueue,
            upTo: "v6_unique_deck_location_links"
        )
        try databaseQueue.write { db in
            try db.execute(sql: "DROP TABLE assembly_execution")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v2_assembly_execution"]
            )
            try db.execute(
                sql: "INSERT INTO app_metadata (key, value) VALUES (?, ?)",
                arguments: ["legacy-without-assembly", "preserved"]
            )
        }

        _ = try GRDBRiftBuilderRepository(databaseWriter: databaseQueue)

        let verification = try databaseQueue.read { db in
            (
                marker: try String.fetchOne(
                    db,
                    sql: "SELECT value FROM app_metadata WHERE key = ?",
                    arguments: ["legacy-without-assembly"]
                ),
                hasAssemblyTable: try db.tableExists("assembly_execution"),
                hasCardmarketTable: try db.tableExists("cardmarket_listing"),
                applied: Set(try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations"
                ))
            )
        }
        XCTAssertEqual(verification.marker, "preserved")
        XCTAssertTrue(verification.hasAssemblyTable)
        XCTAssertTrue(verification.hasCardmarketTable)
        XCTAssertEqual(
            verification.applied,
            Set(RiftBuilderDatabaseSchema.migrationIdentifiers)
        )
    }

}

private struct SelectedPrice: Equatable, Sendable {
    let productID: Int64
    let priceCents: Int
    let source: String
}

private func configuredDatabaseQueue() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    return try DatabaseQueue(configuration: configuration)
}

private func seedCompatibilityFixture(
    in databaseQueue: DatabaseQueue,
    marker: String
) throws {
    try databaseQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO app_metadata (key, value)
                VALUES ('migration-test', ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [marker]
        )
        try db.execute(sql: """
            INSERT OR IGNORE INTO card_identity (
                name_slug, game_id, display_name, domains_json, tags_json, attributes_json
            ) VALUES ('migration-sentinel', 'riftbound', 'Migration Sentinel', '[]', '[]', '{}')
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO card_printing (
                product_id, name_slug, printing_slug, display_name, finishes_json,
                languages_json, attributes_json
            ) VALUES (
                42, 'migration-sentinel', 'migration-sentinel-42', 'Migration Sentinel',
                '[]', '[]', '{}'
            )
            """)
    }
}

private func printing(productID: Int64, expansionSlug: String) -> CardPrinting {
    CardPrinting(
        productID: productID,
        nameSlug: "same-card",
        printingSlug: "\(expansionSlug)-same-card-001",
        displayName: "Same Card",
        expansionSlug: expansionSlug,
        printNumber: "001"
    )
}

private func insertListing(
    in db: Database,
    productID: Int64,
    set: String,
    trend: Int?,
    average7Days: Int?,
    average30Days: Int?
) throws {
    try db.execute(
        sql: """
            INSERT INTO cardmarket_listing (
                product_id, url, trend_price_eur_cents,
                average_7_days_price_eur_cents, average_30_days_price_eur_cents, scraped_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
        arguments: [
            productID,
            "https://www.cardmarket.com/en/Riftbound/Products/Singles/\(set)/Card",
            trend,
            average7Days,
            average30Days,
            "2026-08-29T12:00:00Z",
        ]
    )
}
