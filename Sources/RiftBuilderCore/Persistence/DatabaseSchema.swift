import Foundation
import GRDB

enum RiftBuilderDatabaseSchema {
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

        return migrator
    }
}
