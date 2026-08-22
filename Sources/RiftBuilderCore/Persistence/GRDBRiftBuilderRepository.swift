import Foundation
import GRDB

public final class GRDBRiftBuilderRepository: RiftBuilderRepository, @unchecked Sendable {
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

    public static func inMemory() throws -> GRDBRiftBuilderRepository {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try GRDBRiftBuilderRepository(databaseWriter: DatabaseQueue(configuration: configuration))
    }

    public func replaceCatalogue(printings: [CardPrinting], checksum: String, completedAt: Date) async throws {
        try await databaseWriter.write { db in
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS incoming_product_ids (product_id INTEGER PRIMARY KEY)")
            try db.execute(sql: "DELETE FROM incoming_product_ids")

            for printing in printings {
                let identity = Self.identity(from: printing)
                try Self.upsert(identity: identity, in: db)
                try Self.upsert(printing: printing, in: db)
                try db.execute(sql: "INSERT INTO incoming_product_ids (product_id) VALUES (?)", arguments: [printing.productID])
            }

            // Cached records still referenced by physical inventory or a printing preference are retained.
            // This avoids losing a usable offline snapshot when a feed temporarily omits an older printing.
            try db.execute(sql: """
                DELETE FROM card_printing
                WHERE product_id NOT IN (SELECT product_id FROM incoming_product_ids)
                  AND product_id NOT IN (SELECT product_id FROM inventory_line)
                  AND product_id NOT IN (
                      SELECT preferred_product_id FROM deck_entry WHERE preferred_product_id IS NOT NULL
                  )
                """)
            try db.execute(sql: """
                DELETE FROM card_identity
                WHERE name_slug NOT IN (SELECT name_slug FROM card_printing)
                  AND name_slug NOT IN (SELECT name_slug FROM deck_entry)
                """)
            try db.execute(sql: "DROP TABLE incoming_product_ids")
            try Self.setMetadata("catalogue_checksum", value: checksum, in: db)
            try Self.setMetadata("catalogue_completed_at", value: PersistenceCoding.date(completedAt), in: db)
        }
    }

    public func synchronizeInventory(lines: [InventoryLine], locations: [InventoryLocation], generation: UUID, completedAt: Date) async throws {
        try await databaseWriter.write { db in
            let generationValue = generation.uuidString
            let completedAtValue = PersistenceCoding.date(completedAt)
            let authoritativeLocationKeys = Set(locations.map(\.normalizedName))
            var observed: [String: InventoryLocation] = Dictionary(
                uniqueKeysWithValues: locations.map { ($0.normalizedName, $0) }
            )
            for line in lines {
                let key = InventoryLocation.normalize(line.locationName)
                if observed[key] == nil {
                    let fallback = key == "__unlocated__" ? "Unlocated" : (line.locationName ?? key)
                    observed[key] = InventoryLocation(name: fallback)
                }
            }

            for (key, location) in observed {
                let displayName = location.name
                let isAuthoritative = authoritativeLocationKeys.contains(key)
                try db.execute(sql: """
                    INSERT INTO observed_location (location_key, display_name, color, icon, last_seen_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(location_key) DO UPDATE SET
                        display_name = excluded.display_name,
                        color = excluded.color,
                        icon = excluded.icon,
                        last_seen_at = excluded.last_seen_at
                    """, arguments: [key, displayName, location.color, location.icon, completedAtValue])
                try db.execute(sql: """
                    INSERT INTO location_policy (
                        location_key, display_name, color, icon, kind, counts_as_available, linked_deck_id, last_seen_at
                    ) VALUES (?, ?, ?, ?, 'storage', 1, NULL, ?)
                    ON CONFLICT(location_key) DO UPDATE SET
                        display_name = CASE WHEN ? THEN excluded.display_name ELSE location_policy.display_name END,
                        color = CASE WHEN ? THEN excluded.color ELSE location_policy.color END,
                        icon = CASE WHEN ? THEN excluded.icon ELSE location_policy.icon END,
                        last_seen_at = excluded.last_seen_at
                    """, arguments: [
                        key,
                        displayName,
                        location.color,
                        location.icon,
                        completedAtValue,
                        isAuthoritative,
                        isAuthoritative,
                        isAuthoritative,
                    ])
            }

            for line in lines {
                let key = InventoryLocation.normalize(line.locationName)
                try db.execute(sql: """
                    INSERT INTO inventory_line (
                        inventory_id, product_id, custom_id, finish, condition, language, quantity,
                        graded_json, location_key, location_display_name, tags_json, comment, notes,
                        for_sale, listing_json, remote_updated_at, sync_generation
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(inventory_id) DO UPDATE SET
                        product_id = excluded.product_id,
                        custom_id = excluded.custom_id,
                        finish = excluded.finish,
                        condition = excluded.condition,
                        language = excluded.language,
                        quantity = excluded.quantity,
                        graded_json = excluded.graded_json,
                        location_key = excluded.location_key,
                        location_display_name = excluded.location_display_name,
                        tags_json = excluded.tags_json,
                        comment = excluded.comment,
                        notes = excluded.notes,
                        for_sale = excluded.for_sale,
                        listing_json = excluded.listing_json,
                        remote_updated_at = excluded.remote_updated_at,
                        sync_generation = excluded.sync_generation
                    """, arguments: [
                        line.inventoryID,
                        line.productID,
                        line.customID,
                        line.finish,
                        line.condition,
                        line.language,
                        line.quantity,
                        try line.graded.map(PersistenceCoding.encode),
                        key,
                        line.locationName,
                        try PersistenceCoding.encode(line.tags),
                        line.comment,
                        line.notes,
                        line.isForSale,
                        try line.listing.map(PersistenceCoding.encode),
                        PersistenceCoding.date(line.updatedAt),
                        generationValue,
                    ])
            }

            // This statement runs only after every incoming line has successfully upserted in the
            // same transaction. Any decoding, constraint, or cancellation error rolls back the sweep.
            try db.execute(sql: "DELETE FROM inventory_line WHERE sync_generation <> ?", arguments: [generationValue])
            try Self.setMetadata("inventory_generation", value: generationValue, in: db)
            try Self.setMetadata("inventory_completed_at", value: completedAtValue, in: db)
        }
    }

    public func inventoryCards(search: String?, targetDeckID: UUID?) async throws -> [InventoryCardSummary] {
        try await databaseWriter.read { db in
            var arguments = StatementArguments()
            var searchClause = ""
            if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                searchClause = "AND (LOWER(ci.display_name) LIKE ? ESCAPE '\\' OR LOWER(ci.name_slug) LIKE ? ESCAPE '\\')"
                let escaped = search.lowercased()
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                arguments += ["%\(escaped)%", "%\(escaped)%"]
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT ci.*,
                       (SELECT cp.image_url
                          FROM card_printing cp
                         WHERE cp.name_slug = ci.name_slug AND cp.image_url IS NOT NULL
                         ORDER BY cp.product_id
                         LIMIT 1) AS preferred_image_url
                FROM card_identity ci
                WHERE EXISTS (
                    SELECT 1
                    FROM card_printing cp
                    JOIN inventory_line il ON il.product_id = cp.product_id
                    WHERE cp.name_slug = ci.name_slug AND il.quantity > 0
                )
                \(searchClause)
                ORDER BY ci.display_name COLLATE NOCASE, ci.name_slug
                """, arguments: arguments)

            return try rows.map { row in
                let identity = try Self.identity(from: row)
                let locations = try Self.locationQuantities(
                    nameSlug: identity.nameSlug,
                    targetDeckID: targetDeckID,
                    in: db
                )
                let required = try Self.requiredQuantity(
                    nameSlug: identity.nameSlug,
                    targetDeckID: targetDeckID,
                    in: db
                )
                let availability = Self.availability(from: locations, required: required, targetDeckID: targetDeckID)
                let imageURL: URL? = (row["preferred_image_url"] as String?).flatMap(URL.init(string:))
                return InventoryCardSummary(
                    identity: identity,
                    preferredImageURL: imageURL,
                    availability: availability,
                    locations: locations
                )
            }
        }
    }


    public func cardIdentities(nameSlugs: Set<String>) async throws -> [String: CardIdentity] {
        guard !nameSlugs.isEmpty else { return [:] }
        return try await databaseWriter.read { db in
            let sortedSlugs = nameSlugs.sorted()
            let placeholders = Array(repeating: "?", count: sortedSlugs.count).joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM card_identity WHERE name_slug IN (\(placeholders))",
                arguments: StatementArguments(sortedSlugs)
            )
            var identities: [String: CardIdentity] = [:]
            for row in rows {
                let identity = try Self.identity(from: row)
                identities[identity.nameSlug] = identity
            }
            return identities
        }
    }

    public func catalogueCards(search: String?) async throws -> [CatalogueCardSummary] {
        try await databaseWriter.read { db in
            var arguments = StatementArguments()
            var identitySearchClause = ""
            var printingSearchClause = ""
            if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                let escaped = search.lowercased()
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                identitySearchClause = "WHERE LOWER(display_name) LIKE ? ESCAPE '\\' OR LOWER(name_slug) LIKE ? ESCAPE '\\'"
                printingSearchClause = "WHERE LOWER(ci.display_name) LIKE ? ESCAPE '\\' OR LOWER(ci.name_slug) LIKE ? ESCAPE '\\'"
                arguments += ["%\(escaped)%", "%\(escaped)%"]
            }

            let identityRows = try Row.fetchAll(db, sql: """
                SELECT * FROM card_identity
                \(identitySearchClause)
                ORDER BY display_name COLLATE NOCASE, name_slug
                """, arguments: arguments)
            guard !identityRows.isEmpty else { return [] }

            let printingRows = try Row.fetchAll(db, sql: """
                SELECT cp.name_slug,
                       cp.product_id,
                       cp.printing_slug,
                       cp.expansion_slug,
                       cp.print_number,
                       cp.rarity,
                       cp.image_url
                FROM card_printing cp
                JOIN card_identity ci ON ci.name_slug = cp.name_slug
                \(printingSearchClause)
                ORDER BY cp.name_slug,
                         CASE WHEN cp.image_url IS NULL OR TRIM(cp.image_url) = '' THEN 1 ELSE 0 END,
                         cp.product_id
                """, arguments: arguments)

            var printingsByNameSlug: [String: [CataloguePrintingMetadata]] = [:]
            for row in printingRows {
                let nameSlug: String = row["name_slug"]
                let imageValue: String? = row["image_url"]
                printingsByNameSlug[nameSlug, default: []].append(CataloguePrintingMetadata(
                    productID: row["product_id"],
                    printingSlug: row["printing_slug"],
                    expansionSlug: row["expansion_slug"],
                    printNumber: row["print_number"],
                    rarity: row["rarity"],
                    imageURL: imageValue.flatMap(URL.init(string:))
                ))
            }

            return try identityRows.map { row in
                let identity = try Self.identity(from: row)
                let printings = printingsByNameSlug[identity.nameSlug] ?? []
                return CatalogueCardSummary(
                    identity: identity,
                    preferredPrinting: printings.first,
                    printingCount: printings.count,
                    expansionSlugs: Self.stableUnique(printings.compactMap(\.expansionSlug)),
                    rarities: Self.stableUnique(printings.compactMap(\.rarity))
                )
            }
        }
    }

    public func catalogueIdentities(search: String?) async throws -> [CardIdentity] {
        try await databaseWriter.read { db in
            var arguments = StatementArguments()
            var searchClause = ""
            if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                let escaped = search.lowercased()
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                searchClause = "WHERE LOWER(display_name) LIKE ? ESCAPE '\\' OR LOWER(name_slug) LIKE ? ESCAPE '\\'"
                arguments += ["%\(escaped)%", "%\(escaped)%"]
            }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM card_identity
                \(searchClause)
                ORDER BY display_name COLLATE NOCASE, name_slug
                """, arguments: arguments).map(Self.identity(from:))
        }
    }

    public func catalogueChecksum() async throws -> String? {
        try await databaseWriter.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: ["catalogue_checksum"])
        }
    }

    public func locationPolicies() async throws -> [LocationPolicy] {
        try await databaseWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT location_key, display_name, color, icon, kind, counts_as_available, linked_deck_id
                FROM location_policy
                ORDER BY display_name COLLATE NOCASE, location_key
                """).map(Self.locationPolicy(from:))
        }
    }

    public func saveLocationPolicy(_ policy: LocationPolicy) async throws {
        try await databaseWriter.write { db in
            try db.execute(sql: """
                INSERT INTO location_policy (
                    location_key, display_name, color, icon, kind, counts_as_available, linked_deck_id, last_seen_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(location_key) DO UPDATE SET
                    display_name = excluded.display_name,
                    color = excluded.color,
                    icon = excluded.icon,
                    kind = excluded.kind,
                    counts_as_available = excluded.counts_as_available,
                    linked_deck_id = excluded.linked_deck_id
                """, arguments: [
                    policy.normalizedName,
                    policy.displayName,
                    policy.color,
                    policy.icon,
                    policy.kind.rawValue,
                    policy.countsAsAvailable,
                    policy.linkedDeckID?.uuidString,
                ])
        }
    }

    public func decks() async throws -> [Deck] {
        try await databaseWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM deck ORDER BY updated_at DESC, name COLLATE NOCASE")
                .map(Self.deck(from:))
        }
    }

    public func deckLegendDomains() async throws -> [UUID: [String]] {
        try await databaseWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT de.deck_id, ci.domains_json
                FROM deck_entry de
                JOIN card_identity ci ON ci.name_slug = de.name_slug
                WHERE de.zone = ?
                ORDER BY de.deck_id, de.id
                """, arguments: [DeckZone.legend.rawValue])
            var result: [UUID: [String]] = [:]
            for row in rows {
                let deckIDValue: String = row["deck_id"]
                guard let deckID = UUID(uuidString: deckIDValue) else { continue }
                let domains = try PersistenceCoding.decode([String].self, from: row["domains_json"])
                for domain in domains where !result[deckID, default: []].contains(where: { $0.localizedCaseInsensitiveCompare(domain) == .orderedSame }) {
                    result[deckID, default: []].append(domain)
                }
            }
            return result
        }
    }

    public func deckSnapshot(id: UUID) async throws -> DeckSnapshot? {
        try await databaseWriter.read { db in
            guard let deckRow = try Row.fetchOne(db, sql: "SELECT * FROM deck WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            let deck = try Self.deck(from: deckRow)
            let entries = try Row.fetchAll(db, sql: """
                SELECT * FROM deck_entry
                WHERE deck_id = ?
                ORDER BY zone, name_slug, id
                """, arguments: [id.uuidString]).map(Self.deckEntry(from:))
            var identities: [String: CardIdentity] = [:]
            if !entries.isEmpty {
                for slug in Set(entries.map(\.nameSlug)) {
                    guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card_identity WHERE name_slug = ?", arguments: [slug]) else {
                        continue
                    }
                    identities[slug] = try Self.identity(from: row)
                }
            }
            return DeckSnapshot(deck: deck, entries: entries, identities: identities)
        }
    }

    public func saveDeck(_ deck: Deck) async throws {
        try await databaseWriter.write { db in
            try db.execute(sql: """
                INSERT INTO deck (id, name, state, ruleset_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    state = excluded.state,
                    ruleset_id = excluded.ruleset_id,
                    updated_at = excluded.updated_at
                """, arguments: [
                    deck.id.uuidString,
                    deck.name,
                    deck.state.rawValue,
                    deck.rulesetID,
                    PersistenceCoding.date(deck.createdAt),
                    PersistenceCoding.date(deck.updatedAt),
                ])
        }
    }

    public func deleteDeck(id: UUID) async throws {
        try await databaseWriter.write { db in
            try db.execute(sql: "DELETE FROM deck WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func saveDeckEntry(_ entry: DeckEntry) async throws {
        try await databaseWriter.write { db in
            let oldRow = try Row.fetchOne(db, sql: "SELECT * FROM deck_entry WHERE id = ?", arguments: [entry.id.uuidString])
            let matchingRow = try Row.fetchOne(db, sql: """
                SELECT * FROM deck_entry
                WHERE deck_id = ? AND zone = ? AND name_slug = ?
                  AND IFNULL(preferred_product_id, -1) = IFNULL(?, -1)
                  AND IFNULL(preferred_finish, '') = IFNULL(?, '')
                  AND IFNULL(preferred_language, '') = IFNULL(?, '')
                  AND id <> ?
                LIMIT 1
                """, arguments: [
                    entry.deckID.uuidString,
                    entry.zone.rawValue,
                    entry.nameSlug,
                    entry.preferredProductID,
                    entry.preferredFinish,
                    entry.preferredLanguage,
                    entry.id.uuidString,
                ])

            if let matchingRow {
                let matchingID: String = matchingRow["id"]
                let matchingQuantity: Int = matchingRow["quantity"]
                let mergedQuantity = matchingQuantity + entry.quantity
                if oldRow != nil {
                    try db.execute(sql: "DELETE FROM deck_entry WHERE id = ?", arguments: [entry.id.uuidString])
                }
                try db.execute(sql: "UPDATE deck_entry SET quantity = ? WHERE id = ?", arguments: [mergedQuantity, matchingID])
            } else {
                try db.execute(sql: """
                    INSERT INTO deck_entry (
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
                        entry.id.uuidString,
                        entry.deckID.uuidString,
                        entry.zone.rawValue,
                        entry.nameSlug,
                        entry.quantity,
                        entry.preferredProductID,
                        entry.preferredFinish,
                        entry.preferredLanguage,
                    ])
            }

            try db.execute(sql: "UPDATE deck SET updated_at = ? WHERE id = ?", arguments: [
                PersistenceCoding.date(Date()), entry.deckID.uuidString,
            ])
        }
    }

    public func deleteDeckEntry(id: UUID) async throws {
        try await databaseWriter.write { db in
            let deckID = try String.fetchOne(db, sql: "SELECT deck_id FROM deck_entry WHERE id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM deck_entry WHERE id = ?", arguments: [id.uuidString])
            if let deckID {
                try db.execute(sql: "UPDATE deck SET updated_at = ? WHERE id = ?", arguments: [PersistenceCoding.date(Date()), deckID])
            }
        }
    }
}

private extension GRDBRiftBuilderRepository {
    static func identity(from printing: CardPrinting) -> CardIdentity {
        let attributes = printing.attributes
        return CardIdentity(
            nameSlug: printing.nameSlug,
            gameID: attributes.string(for: ["gameId", "gameID", "game_id"]) ?? "riftbound",
            displayName: printing.displayName,
            cardType: attributes.string(for: ["cardType", "card_type", "type"]),
            superType: attributes.string(for: ["superType", "super_type"]),
            domains: attributes.strings(for: ["domains", "domain"]),
            tags: attributes.strings(for: ["tags"]),
            energyCost: attributes.integer(for: ["energyCost", "energy_cost", "energy"]),
            mightCost: attributes.integer(for: ["mightCost", "might_cost", "might"]),
            attributes: attributes
        )
    }

    static func upsert(identity: CardIdentity, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO card_identity (
                name_slug, game_id, display_name, card_type, super_type, domains_json,
                tags_json, energy_cost, might_cost, attributes_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(name_slug) DO UPDATE SET
                game_id = excluded.game_id,
                display_name = excluded.display_name,
                card_type = excluded.card_type,
                super_type = excluded.super_type,
                domains_json = excluded.domains_json,
                tags_json = excluded.tags_json,
                energy_cost = excluded.energy_cost,
                might_cost = excluded.might_cost,
                attributes_json = excluded.attributes_json
            """, arguments: [
                identity.nameSlug,
                identity.gameID,
                identity.displayName,
                identity.cardType,
                identity.superType,
                try PersistenceCoding.encode(identity.domains),
                try PersistenceCoding.encode(identity.tags),
                identity.energyCost,
                identity.mightCost,
                try PersistenceCoding.encode(identity.attributes),
            ])
    }

    static func upsert(printing: CardPrinting, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO card_printing (
                product_id, name_slug, printing_slug, display_name, expansion_id, expansion_slug,
                print_number, variant, rarity, finishes_json, languages_json, image_url,
                image_back_url, attributes_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(product_id) DO UPDATE SET
                name_slug = excluded.name_slug,
                printing_slug = excluded.printing_slug,
                display_name = excluded.display_name,
                expansion_id = excluded.expansion_id,
                expansion_slug = excluded.expansion_slug,
                print_number = excluded.print_number,
                variant = excluded.variant,
                rarity = excluded.rarity,
                finishes_json = excluded.finishes_json,
                languages_json = excluded.languages_json,
                image_url = excluded.image_url,
                image_back_url = excluded.image_back_url,
                attributes_json = excluded.attributes_json
            """, arguments: [
                printing.productID,
                printing.nameSlug,
                printing.printingSlug,
                printing.displayName,
                printing.expansionID,
                printing.expansionSlug,
                printing.printNumber,
                printing.variant,
                printing.rarity,
                try PersistenceCoding.encode(printing.finishes),
                try PersistenceCoding.encode(printing.languages),
                printing.imageURL?.absoluteString,
                printing.imageBackURL?.absoluteString,
                try PersistenceCoding.encode(printing.attributes),
            ])
    }

    static func setMetadata(_ key: String, value: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO app_metadata (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [key, value])
    }

    static func identity(from row: Row) throws -> CardIdentity {
        CardIdentity(
            nameSlug: row["name_slug"],
            gameID: row["game_id"],
            displayName: row["display_name"],
            cardType: row["card_type"],
            superType: row["super_type"],
            domains: try PersistenceCoding.decode([String].self, from: row["domains_json"]),
            tags: try PersistenceCoding.decode([String].self, from: row["tags_json"]),
            energyCost: row["energy_cost"],
            mightCost: row["might_cost"],
            attributes: try PersistenceCoding.decode([String: JSONValue].self, from: row["attributes_json"])
        )
    }

    static func locationPolicy(from row: Row) throws -> LocationPolicy {
        let kindValue: String = row["kind"]
        guard let kind = LocationKind(rawValue: kindValue) else {
            throw DatabaseError(message: "Invalid location kind: \(kindValue)")
        }
        let linkedID = (row["linked_deck_id"] as String?).flatMap(UUID.init(uuidString:))
        return LocationPolicy(
            normalizedName: row["location_key"],
            displayName: row["display_name"],
            color: row["color"],
            icon: row["icon"],
            kind: kind,
            countsAsAvailable: row["counts_as_available"],
            linkedDeckID: linkedID
        )
    }

    static func deck(from row: Row) throws -> Deck {
        let idValue: String = row["id"]
        let stateValue: String = row["state"]
        guard let id = UUID(uuidString: idValue), let state = DeckState(rawValue: stateValue) else {
            throw DatabaseError(message: "Invalid persisted deck")
        }
        return Deck(
            id: id,
            name: row["name"],
            state: state,
            rulesetID: row["ruleset_id"],
            createdAt: PersistenceCoding.date(from: row["created_at"]),
            updatedAt: PersistenceCoding.date(from: row["updated_at"])
        )
    }

    static func deckEntry(from row: Row) throws -> DeckEntry {
        let idValue: String = row["id"]
        let deckIDValue: String = row["deck_id"]
        let zoneValue: String = row["zone"]
        guard let id = UUID(uuidString: idValue),
              let deckID = UUID(uuidString: deckIDValue),
              let zone = DeckZone(rawValue: zoneValue)
        else {
            throw DatabaseError(message: "Invalid persisted deck entry")
        }
        return DeckEntry(
            id: id,
            deckID: deckID,
            zone: zone,
            nameSlug: row["name_slug"],
            quantity: row["quantity"],
            preferredProductID: row["preferred_product_id"],
            preferredFinish: row["preferred_finish"],
            preferredLanguage: row["preferred_language"]
        )
    }

    static func locationQuantities(nameSlug: String, targetDeckID: UUID?, in db: Database) throws -> [LocationQuantity] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT lp.location_key,
                   lp.display_name,
                   lp.color,
                   lp.icon,
                   lp.kind,
                   lp.counts_as_available,
                   lp.linked_deck_id,
                   SUM(il.quantity) AS quantity
            FROM inventory_line il
            JOIN card_printing cp ON cp.product_id = il.product_id
            JOIN location_policy lp ON lp.location_key = il.location_key
            WHERE cp.name_slug = ?
            GROUP BY lp.location_key, lp.display_name, lp.color, lp.icon, lp.kind, lp.counts_as_available, lp.linked_deck_id
            ORDER BY lp.display_name COLLATE NOCASE, lp.location_key
            """, arguments: [nameSlug])

        return try rows.map { row in
            let kindValue: String = row["kind"]
            guard let kind = LocationKind(rawValue: kindValue) else {
                throw DatabaseError(message: "Invalid location kind: \(kindValue)")
            }
            let linkedDeckID = (row["linked_deck_id"] as String?).flatMap(UUID.init(uuidString:))
            let countsAsAvailable: Bool = row["counts_as_available"]
            let isAvailable = (kind == .storage && countsAsAvailable)
                || (kind == .deck && linkedDeckID != nil && linkedDeckID == targetDeckID)
            return LocationQuantity(
                normalizedLocationName: row["location_key"],
                displayName: row["display_name"],
                color: row["color"],
                icon: row["icon"],
                kind: kind,
                quantity: row["quantity"],
                isAvailable: isAvailable,
                linkedDeckID: linkedDeckID
            )
        }
    }

    static func requiredQuantity(nameSlug: String, targetDeckID: UUID?, in db: Database) throws -> Int {
        guard let targetDeckID else { return 0 }
        return try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(quantity), 0)
            FROM deck_entry
            WHERE deck_id = ? AND name_slug = ?
            """, arguments: [targetDeckID.uuidString, nameSlug]) ?? 0
    }

    static func availability(from locations: [LocationQuantity], required: Int, targetDeckID: UUID?) -> CardAvailability {
        var storage = 0
        var target = 0
        var otherDecks = 0
        var unavailable = 0

        for location in locations {
            switch location.kind {
            case .storage where location.isAvailable:
                storage += location.quantity
            case .deck where location.linkedDeckID != nil && location.linkedDeckID == targetDeckID:
                target += location.quantity
            case .deck:
                otherDecks += location.quantity
            case .storage, .unavailable:
                unavailable += location.quantity
            }
        }

        return CardAvailability(
            totalOwned: locations.reduce(0) { $0 + $1.quantity },
            availableInStorage: storage,
            inTargetDeck: target,
            inOtherDecks: otherDecks,
            otherwiseUnavailable: unavailable,
            required: required
        )
    }
}
