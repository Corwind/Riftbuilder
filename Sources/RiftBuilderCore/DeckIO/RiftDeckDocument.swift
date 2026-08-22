import Foundation

public struct RiftDeckDocument: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let exportedAt: Date
    public let deck: DeckDefinition
    public let entries: [Entry]

    public var referencedNameSlugs: Set<String> {
        Set(entries.map(\.nameSlug))
    }

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        exportedAt: Date,
        deck: DeckDefinition,
        entries: [Entry]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.deck = deck
        self.entries = entries
    }

    public struct DeckDefinition: Codable, Equatable, Sendable {
        public let name: String
        public let state: DeckState
        public let rulesetID: String

        public init(name: String, state: DeckState, rulesetID: String) {
            self.name = name
            self.state = state
            self.rulesetID = rulesetID
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let zone: DeckZone
        public let nameSlug: String
        public let quantity: Int
        public let preferredProductID: Int64?
        public let preferredFinish: String?
        public let preferredLanguage: String?

        public init(
            zone: DeckZone,
            nameSlug: String,
            quantity: Int,
            preferredProductID: Int64? = nil,
            preferredFinish: String? = nil,
            preferredLanguage: String? = nil
        ) {
            self.zone = zone
            self.nameSlug = nameSlug
            self.quantity = quantity
            self.preferredProductID = preferredProductID
            self.preferredFinish = preferredFinish
            self.preferredLanguage = preferredLanguage
        }
    }
}

public enum RiftDeckCodecError: Error, Equatable, Sendable {
    case malformedDocument(description: String)
    case unsupportedFormatVersion(found: Int, supported: Int)
    case emptyDeckName
    case emptyRulesetID
    case emptyNameSlug(entryIndex: Int)
    case invalidQuantity(entryIndex: Int, quantity: Int)
    case invalidPreferredProductID(entryIndex: Int, productID: Int64)
    case quantityOverflow(nameSlug: String, zone: DeckZone)
}

extension RiftDeckCodecError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .malformedDocument(description):
            return "The deck document is malformed: \(description)"
        case let .unsupportedFormatVersion(found, supported):
            return "Deck format version \(found) is unsupported; this app supports version \(supported)."
        case .emptyDeckName:
            return "The deck name must not be empty."
        case .emptyRulesetID:
            return "The ruleset identifier must not be empty."
        case let .emptyNameSlug(index):
            return "Deck entry \(index) has an empty same-name card identifier."
        case let .invalidQuantity(index, quantity):
            return "Deck entry \(index) has invalid quantity \(quantity); quantities must be positive."
        case let .invalidPreferredProductID(index, productID):
            return "Deck entry \(index) has invalid preferred product identifier \(productID)."
        case let .quantityOverflow(nameSlug, zone):
            return "Coalescing entries for \(nameSlug) in \(zone.rawValue) exceeded the supported quantity range."
        }
    }
}
