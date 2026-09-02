import Foundation
import GRDB

enum RiftBuilderDatabaseSchema {
    static let migrationIdentifiers = [
        "v1_initial",
        "v2_assembly_execution",
        "v2_location_appearance",
        "v3_deck_drafts",
        "v4_deck_save_operations",
        "v5_deck_card_origins",
        "v6_unique_deck_location_links",
        "v7_cardmarket_listings",
    ]

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "app_metadata") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }

            try db.create(table: "card_identity") { table in
                table.column("name_slug", .text).primaryKey()
                table.column("game_id", .text).notNull()
                table.column("display_name", .text).notNull()
                table.column("card_type", .text)
                table.column("super_type", .text)
                table.column("domains_json", .text).notNull()
                table.column("tags_json", .text).notNull()
                table.column("energy_cost", .integer)
                table.column("might_cost", .integer)
                table.column("attributes_json", .text).notNull()
            }

            try db.create(table: "card_printing") { table in
                table.column("product_id", .integer).primaryKey()
                table.column("name_slug", .text).notNull().references("card_identity", onDelete: .restrict)
                table.column("printing_slug", .text).notNull().unique()
                table.column("display_name", .text).notNull()
                table.column("expansion_id", .integer)
                table.column("expansion_slug", .text)
                table.column("print_number", .text)
                table.column("variant", .text)
                table.column("rarity", .text)
                table.column("finishes_json", .text).notNull()
                table.column("languages_json", .text).notNull()
                table.column("image_url", .text)
                table.column("image_back_url", .text)
                table.column("attributes_json", .text).notNull()
            }

            try db.create(table: "deck") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("state", .text).notNull().check { ["planned", "assembled"].contains($0) }
                table.column("ruleset_id", .text).notNull()
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
            }

            try db.create(table: "observed_location") { table in
                table.column("location_key", .text).primaryKey()
                table.column("display_name", .text).notNull()
                table.column("last_seen_at", .text).notNull()
            }

            try db.create(table: "location_policy") { table in
                table.column("location_key", .text).primaryKey()
                table.column("display_name", .text).notNull()
                table.column("kind", .text).notNull().check { ["storage", "deck", "unavailable"].contains($0) }
                table.column("counts_as_available", .boolean).notNull()
                table.column("linked_deck_id", .text).references("deck", onDelete: .setNull)
                table.column("last_seen_at", .text)
            }

            try db.create(table: "inventory_line") { table in
                table.column("inventory_id", .text).primaryKey()
                table.column("product_id", .integer).notNull().references("card_printing", onDelete: .restrict)
                table.column("custom_id", .text)
                table.column("finish", .text).notNull()
                table.column("condition", .text)
                table.column("language", .text)
                table.column("quantity", .integer).notNull().check { $0 >= 0 }
                table.column("graded_json", .text)
                table.column("location_key", .text).notNull().references("location_policy", onDelete: .restrict)
                table.column("location_display_name", .text)
                table.column("tags_json", .text).notNull()
                table.column("comment", .text)
                table.column("notes", .text)
                table.column("for_sale", .boolean).notNull()
                table.column("listing_json", .text)
                table.column("remote_updated_at", .text).notNull()
                table.column("sync_generation", .text).notNull()
            }

            try db.create(table: "deck_entry") { table in
                table.column("id", .text).primaryKey()
                table.column("deck_id", .text).notNull().references("deck", onDelete: .cascade)
                table.column("zone", .text).notNull()
                table.column("name_slug", .text).notNull().references("card_identity", onDelete: .restrict)
                table.column("quantity", .integer).notNull().check { $0 > 0 }
                table.column("preferred_product_id", .integer).references("card_printing", onDelete: .setNull)
                table.column("preferred_finish", .text)
                table.column("preferred_language", .text)
            }

            try db.create(index: "idx_printing_name_slug", on: "card_printing", columns: ["name_slug"])
            try db.create(index: "idx_inventory_product", on: "inventory_line", columns: ["product_id"])
            try db.create(index: "idx_inventory_location", on: "inventory_line", columns: ["location_key"])
            try db.create(index: "idx_inventory_updated", on: "inventory_line", columns: ["remote_updated_at"])
            try db.create(index: "idx_deck_entry_deck", on: "deck_entry", columns: ["deck_id"])
            try db.create(index: "idx_deck_entry_zone", on: "deck_entry", columns: ["zone"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_deck_entry_logical_unique
                ON deck_entry(
                    deck_id,
                    zone,
                    name_slug,
                    IFNULL(preferred_product_id, -1),
                    IFNULL(preferred_finish, ''),
                    IFNULL(preferred_language, '')
                )
                """)
        }

        // This identifier shipped in v0.1.0 through a separate migrator. It is
        // intentionally retained and folded into the canonical sequence.
        migrator.registerMigration("v2_assembly_execution") { db in
            try db.create(table: "assembly_execution") { table in
                table.column("plan_id", .text).primaryKey()
                table.column("deck_id", .text).notNull().references("deck", onDelete: .cascade)
                table.column("report_json", .text).notNull()
                table.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_assembly_execution_deck", on: "assembly_execution", columns: ["deck_id"])
        }

        migrator.registerMigration("v2_location_appearance") { db in
            try db.alter(table: "observed_location") { table in
                table.add(column: "color", .text)
                table.add(column: "icon", .text)
            }
            try db.alter(table: "location_policy") { table in
                table.add(column: "color", .text)
                table.add(column: "icon", .text)
            }
        }

        migrator.registerMigration("v3_deck_drafts") { db in
            try db.create(table: "deck_draft") { table in
                table.column("deck_id", .text).primaryKey().references("deck", onDelete: .cascade)
                table.column("base_deck_updated_at", .text).notNull()
                table.column("created_at", .text).notNull()
                table.column("updated_at", .text).notNull()
            }

            try db.create(table: "deck_draft_entry") { table in
                table.column("id", .text).primaryKey()
                table.column("deck_id", .text).notNull().references("deck_draft", column: "deck_id", onDelete: .cascade)
                table.column("zone", .text).notNull()
                table.column("name_slug", .text).notNull().references("card_identity", onDelete: .restrict)
                table.column("quantity", .integer).notNull().check { $0 > 0 }
                table.column("preferred_product_id", .integer).references("card_printing", onDelete: .setNull)
                table.column("preferred_finish", .text)
                table.column("preferred_language", .text)
            }

            try db.create(index: "idx_deck_draft_entry_deck", on: "deck_draft_entry", columns: ["deck_id"])
            try db.create(index: "idx_deck_draft_entry_zone", on: "deck_draft_entry", columns: ["zone"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_deck_draft_entry_logical_unique
                ON deck_draft_entry(
                    deck_id,
                    zone,
                    name_slug,
                    IFNULL(preferred_product_id, -1),
                    IFNULL(preferred_finish, ''),
                    IFNULL(preferred_language, '')
                )
                """)
        }

        migrator.registerMigration("v4_deck_save_operations") { db in
            try db.create(table: "deck_save_operation") { table in
                table.column("operation_id", .text).primaryKey()
                table.column("deck_id", .text).notNull().unique().references("deck", onDelete: .cascade)
                table.column("draft_updated_at", .text).notNull()
                table.column("plan_json", .text).notNull()
                table.column("created_at", .text).notNull()
            }
        }

        migrator.registerMigration("v5_deck_card_origins") { db in
            try db.create(table: "deck_card_origin") { table in
                table.column("id", .text).primaryKey()
                table.column("deck_id", .text).notNull().references("deck", onDelete: .cascade)
                table.column("name_slug", .text).notNull().references("card_identity", onDelete: .restrict)
                table.column("product_id", .integer).notNull().references("card_printing", onDelete: .restrict)
                table.column("finish", .text).notNull()
                table.column("language", .text)
                table.column("previous_location_key", .text).notNull()
                table.column("previous_location_name", .text)
                table.column("quantity", .integer).notNull().check { $0 > 0 }
                table.column("created_at", .text).notNull()
            }
            try db.create(index: "idx_deck_card_origin_deck", on: "deck_card_origin", columns: ["deck_id"])
            try db.create(index: "idx_deck_card_origin_card", on: "deck_card_origin", columns: ["deck_id", "name_slug", "product_id"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_deck_card_origin_lot_unique
                ON deck_card_origin(
                    deck_id,
                    name_slug,
                    product_id,
                    finish,
                    IFNULL(language, ''),
                    previous_location_key
                )
                """)
        }

        migrator.registerMigration("v6_unique_deck_location_links") { db in
            // Older builds allowed more than one location to point at a deck.
            // Retain the first stable location and unlink any duplicates before
            // enforcing the one-to-one relationship.
            try db.execute(sql: """
                UPDATE location_policy
                SET linked_deck_id = NULL
                WHERE linked_deck_id IS NOT NULL
                  AND location_key NOT IN (
                      SELECT MIN(location_key)
                      FROM location_policy
                      WHERE linked_deck_id IS NOT NULL
                      GROUP BY linked_deck_id
                  )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_location_policy_linked_deck_unique
                ON location_policy(linked_deck_id)
                WHERE linked_deck_id IS NOT NULL
                """)
        }

        migrator.registerMigration("v7_cardmarket_listings") { db in
            // Cardmarket data belongs to an exact printing, not the shared card
            // identity: the same card can have a different price in each set or
            // variant. Catalogue refreshes leave this imported data untouched.
            try db.create(table: "cardmarket_listing") { table in
                table.column("product_id", .integer)
                    .primaryKey()
                    .references("card_printing", onDelete: .cascade)
                table.column("url", .text).notNull().unique()
                table.column("trend_price_eur_cents", .integer).check { $0 >= 0 }
                table.column("average_7_days_price_eur_cents", .integer).check { $0 >= 0 }
                table.column("average_30_days_price_eur_cents", .integer).check { $0 >= 0 }
                table.column("scraped_at", .text).notNull()
            }

            // Give every reader the same price-selection policy while retaining
            // each source value for auditing and future policy changes.
            try db.execute(sql: """
                CREATE VIEW cardmarket_price AS
                SELECT
                    product_id,
                    url,
                    CASE
                        WHEN COALESCE(
                            trend_price_eur_cents,
                            average_7_days_price_eur_cents,
                            average_30_days_price_eur_cents
                        ) IS NULL THEN NULL
                        ELSE 'EUR'
                    END AS currency,
                    COALESCE(
                        trend_price_eur_cents,
                        average_7_days_price_eur_cents,
                        average_30_days_price_eur_cents
                    ) AS price_cents,
                    CASE
                        WHEN trend_price_eur_cents IS NOT NULL THEN 'trend'
                        WHEN average_7_days_price_eur_cents IS NOT NULL THEN 'average_7_days'
                        WHEN average_30_days_price_eur_cents IS NOT NULL THEN 'average_30_days'
                        ELSE NULL
                    END AS price_source,
                    scraped_at
                FROM cardmarket_listing
                """)
        }

        return migrator
    }
}
