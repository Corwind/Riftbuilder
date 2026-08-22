import Foundation

public struct TextDeckImportDocument: Equatable, Sendable {
    public let entries: [TextDeckImportEntry]
    public let suggestedDeckName: String?

    public init(entries: [TextDeckImportEntry], suggestedDeckName: String?) {
        self.entries = entries
        self.suggestedDeckName = suggestedDeckName
    }
}

public struct TextDeckImportEntry: Equatable, Sendable {
    public let zone: DeckZone
    public let displayName: String
    public let quantity: Int
    public let lineNumber: Int

    public init(zone: DeckZone, displayName: String, quantity: Int, lineNumber: Int) {
        self.zone = zone
        self.displayName = displayName
        self.quantity = quantity
        self.lineNumber = lineNumber
    }
}

public struct UnresolvedTextDeckCard: Equatable, Sendable {
    public let entry: TextDeckImportEntry

    public init(entry: TextDeckImportEntry) {
        self.entry = entry
    }
}

public struct AmbiguousTextDeckCard: Equatable, Sendable {
    public let entry: TextDeckImportEntry
    public let candidates: [CardIdentity]

    public init(entry: TextDeckImportEntry, candidates: [CardIdentity]) {
        self.entry = entry
        self.candidates = candidates
    }
}

public struct ResolvedTextDeckImport: Equatable, Sendable {
    public let source: TextDeckImportDocument
    public let deckID: UUID
    public let entries: [DeckEntry]
    public let identities: [String: CardIdentity]
    public let unresolvedCards: [UnresolvedTextDeckCard]
    public let ambiguousCards: [AmbiguousTextDeckCard]

    public var isFullyResolved: Bool {
        unresolvedCards.isEmpty && ambiguousCards.isEmpty
    }

    public init(
        source: TextDeckImportDocument,
        deckID: UUID,
        entries: [DeckEntry],
        identities: [String: CardIdentity],
        unresolvedCards: [UnresolvedTextDeckCard],
        ambiguousCards: [AmbiguousTextDeckCard]
    ) {
        self.source = source
        self.deckID = deckID
        self.entries = entries
        self.identities = identities
        self.unresolvedCards = unresolvedCards
        self.ambiguousCards = ambiguousCards
    }
}

public enum TextDeckImportError: Error, Equatable, Sendable {
    case entryBeforeSection(line: Int, content: String)
    case unknownSection(line: Int, heading: String)
    case invalidQuantity(line: Int, token: String)
    case missingCardName(line: Int)
    case quantityOverflow(line: Int, cardName: String, zone: DeckZone)
}

extension TextDeckImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .entryBeforeSection(line, content):
            return "Line \(line): Card entry appears before a recognized section: \(content)"
        case let .unknownSection(line, heading):
            return "Line \(line): Unknown deck section \"\(heading)\"."
        case let .invalidQuantity(line, token):
            return "Line \(line): \"\(token)\" is not a positive card quantity."
        case let .missingCardName(line):
            return "Line \(line): A card name must follow the quantity."
        case let .quantityOverflow(line, cardName, _):
            return "Line \(line): The total quantity for \"\(cardName)\" is too large."
        }
    }
}
