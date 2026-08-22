import Foundation

public enum RiftDeckCodec {
    public static func document(
        from snapshot: DeckSnapshot,
        exportedAt: Date = Date()
    ) throws -> RiftDeckDocument {
        let entries = snapshot.entries.map { entry in
            RiftDeckDocument.Entry(
                zone: entry.zone,
                nameSlug: entry.nameSlug,
                quantity: entry.quantity,
                preferredProductID: entry.preferredProductID,
                preferredFinish: normalizedPreference(entry.preferredFinish),
                preferredLanguage: normalizedPreference(entry.preferredLanguage)
            )
        }
        let document = RiftDeckDocument(
            exportedAt: exportedAt,
            deck: RiftDeckDocument.DeckDefinition(
                name: snapshot.deck.name,
                state: snapshot.deck.state,
                rulesetID: snapshot.deck.rulesetID
            ),
            entries: entries
        )
        return try validatedAndCoalesced(document)
    }

    public static func encode(
        snapshot: DeckSnapshot,
        exportedAt: Date = Date(),
        prettyPrinted: Bool = true
    ) throws -> Data {
        let document = try document(from: snapshot, exportedAt: exportedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    public static func decodeDocument(from data: Data) throws -> RiftDeckDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: RiftDeckDocument
        do {
            decoded = try decoder.decode(RiftDeckDocument.self, from: data)
        } catch {
            throw RiftDeckCodecError.malformedDocument(description: String(describing: error))
        }
        return try validatedAndCoalesced(decoded)
    }

    public static func decodeSnapshot(
        from data: Data,
        deckID: UUID = UUID(),
        importedAt: Date = Date(),
        identities: [String: CardIdentity] = [:]
    ) throws -> DeckSnapshot {
        let document = try decodeDocument(from: data)
        let deck = Deck(
            id: deckID,
            name: document.deck.name,
            state: document.deck.state,
            rulesetID: document.deck.rulesetID,
            createdAt: importedAt,
            updatedAt: importedAt
        )
        let entries = document.entries.map { entry in
            DeckEntry(
                deckID: deckID,
                zone: entry.zone,
                nameSlug: entry.nameSlug,
                quantity: entry.quantity,
                preferredProductID: entry.preferredProductID,
                preferredFinish: entry.preferredFinish,
                preferredLanguage: entry.preferredLanguage
            )
        }
        let referencedIdentities = identities.filter { document.referencedNameSlugs.contains($0.key) }
        return DeckSnapshot(deck: deck, entries: entries, identities: referencedIdentities)
    }
}

private extension RiftDeckCodec {
    struct LogicalEntryKey: Hashable {
        let zone: DeckZone
        let nameSlug: String
        let preferredProductID: Int64?
        let preferredFinish: String?
        let preferredLanguage: String?
    }

    static func validatedAndCoalesced(_ document: RiftDeckDocument) throws -> RiftDeckDocument {
        guard document.formatVersion == RiftDeckDocument.currentFormatVersion else {
            throw RiftDeckCodecError.unsupportedFormatVersion(
                found: document.formatVersion,
                supported: RiftDeckDocument.currentFormatVersion
            )
        }
        let deckName = document.deck.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deckName.isEmpty else { throw RiftDeckCodecError.emptyDeckName }
        let rulesetID = document.deck.rulesetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rulesetID.isEmpty else { throw RiftDeckCodecError.emptyRulesetID }

        var order: [LogicalEntryKey] = []
        var entriesByKey: [LogicalEntryKey: RiftDeckDocument.Entry] = [:]
        for (index, rawEntry) in document.entries.enumerated() {
            let nameSlug = rawEntry.nameSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nameSlug.isEmpty else { throw RiftDeckCodecError.emptyNameSlug(entryIndex: index) }
            guard rawEntry.quantity > 0 else {
                throw RiftDeckCodecError.invalidQuantity(entryIndex: index, quantity: rawEntry.quantity)
            }
            if let productID = rawEntry.preferredProductID, productID <= 0 {
                throw RiftDeckCodecError.invalidPreferredProductID(entryIndex: index, productID: productID)
            }
            let finish = normalizedPreference(rawEntry.preferredFinish)
            let language = normalizedPreference(rawEntry.preferredLanguage)
            let key = LogicalEntryKey(
                zone: rawEntry.zone,
                nameSlug: nameSlug,
                preferredProductID: rawEntry.preferredProductID,
                preferredFinish: finish,
                preferredLanguage: language
            )
            if let existing = entriesByKey[key] {
                let (quantity, overflow) = existing.quantity.addingReportingOverflow(rawEntry.quantity)
                guard !overflow else {
                    throw RiftDeckCodecError.quantityOverflow(nameSlug: nameSlug, zone: rawEntry.zone)
                }
                entriesByKey[key] = RiftDeckDocument.Entry(
                    zone: key.zone,
                    nameSlug: key.nameSlug,
                    quantity: quantity,
                    preferredProductID: key.preferredProductID,
                    preferredFinish: key.preferredFinish,
                    preferredLanguage: key.preferredLanguage
                )
            } else {
                order.append(key)
                entriesByKey[key] = RiftDeckDocument.Entry(
                    zone: key.zone,
                    nameSlug: key.nameSlug,
                    quantity: rawEntry.quantity,
                    preferredProductID: key.preferredProductID,
                    preferredFinish: key.preferredFinish,
                    preferredLanguage: key.preferredLanguage
                )
            }
        }

        return RiftDeckDocument(
            formatVersion: document.formatVersion,
            exportedAt: document.exportedAt,
            deck: RiftDeckDocument.DeckDefinition(
                name: deckName,
                state: document.deck.state,
                rulesetID: rulesetID
            ),
            entries: order.compactMap { entriesByKey[$0] }
        )
    }

    static func normalizedPreference(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
