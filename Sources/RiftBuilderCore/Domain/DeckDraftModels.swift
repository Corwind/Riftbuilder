import Foundation

public struct DeckDraftSnapshot: Codable, Hashable, Sendable {
    public let deck: Deck
    public let entries: [DeckEntry]
    public let identities: [String: CardIdentity]
    public let baseDeckUpdatedAt: Date
    public let createdAt: Date
    public let updatedAt: Date

    public init(deck: Deck, entries: [DeckEntry], identities: [String: CardIdentity], baseDeckUpdatedAt: Date, createdAt: Date, updatedAt: Date) {
        self.deck = deck
        self.entries = entries
        self.identities = identities
        self.baseDeckUpdatedAt = baseDeckUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var deckSnapshot: DeckSnapshot {
        DeckSnapshot(deck: deck, entries: entries, identities: identities)
    }
}

public struct DeckEntryLogicalKey: Codable, Hashable, Sendable {
    public let zone: DeckZone
    public let nameSlug: String
    public let preferredProductID: Int64?
    public let preferredFinish: String?
    public let preferredLanguage: String?

    public init(zone: DeckZone, nameSlug: String, preferredProductID: Int64? = nil, preferredFinish: String? = nil, preferredLanguage: String? = nil) {
        self.zone = zone
        self.nameSlug = nameSlug
        self.preferredProductID = preferredProductID
        self.preferredFinish = preferredFinish
        self.preferredLanguage = preferredLanguage
    }

    public init(entry: DeckEntry) {
        self.init(
            zone: entry.zone,
            nameSlug: entry.nameSlug,
            preferredProductID: entry.preferredProductID,
            preferredFinish: entry.preferredFinish,
            preferredLanguage: entry.preferredLanguage
        )
    }
}

public struct DeckEntryDelta: Codable, Hashable, Sendable {
    public let key: DeckEntryLogicalKey
    public let savedQuantity: Int
    public let draftQuantity: Int

    public init(key: DeckEntryLogicalKey, savedQuantity: Int, draftQuantity: Int) {
        self.key = key
        self.savedQuantity = savedQuantity
        self.draftQuantity = draftQuantity
    }

    public var quantityChange: Int { draftQuantity - savedQuantity }
}

public struct DeckDraftDiff: Codable, Hashable, Sendable {
    public let changes: [DeckEntryDelta]

    public init(savedEntries: [DeckEntry], draftEntries: [DeckEntry]) {
        let saved = Self.quantities(entries: savedEntries)
        let draft = Self.quantities(entries: draftEntries)
        changes = Set(saved.keys).union(draft.keys).compactMap { key in
            let savedQuantity = saved[key, default: 0]
            let draftQuantity = draft[key, default: 0]
            guard savedQuantity != draftQuantity else { return nil }
            return DeckEntryDelta(key: key, savedQuantity: savedQuantity, draftQuantity: draftQuantity)
        }.sorted(by: Self.sortChanges)
    }

    public var additions: [DeckEntryDelta] { changes.filter { $0.quantityChange > 0 } }
    public var removals: [DeckEntryDelta] { changes.filter { $0.quantityChange < 0 } }
    public var isEmpty: Bool { changes.isEmpty }

    private static func quantities(entries: [DeckEntry]) -> [DeckEntryLogicalKey: Int] {
        entries.reduce(into: [:]) { result, entry in
            result[DeckEntryLogicalKey(entry: entry), default: 0] += entry.quantity
        }
    }

    private static func sortChanges(_ lhs: DeckEntryDelta, _ rhs: DeckEntryDelta) -> Bool {
        let left = lhs.key
        let right = rhs.key
        if left.zone.rawValue != right.zone.rawValue { return left.zone.rawValue < right.zone.rawValue }
        if left.nameSlug != right.nameSlug { return left.nameSlug < right.nameSlug }
        if left.preferredProductID != right.preferredProductID { return (left.preferredProductID ?? -1) < (right.preferredProductID ?? -1) }
        if left.preferredFinish != right.preferredFinish { return (left.preferredFinish ?? "") < (right.preferredFinish ?? "") }
        return (left.preferredLanguage ?? "") < (right.preferredLanguage ?? "")
    }
}
