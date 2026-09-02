import Foundation

public struct CardIdentity: Codable, Hashable, Identifiable, Sendable {
    public var id: String { nameSlug }
    public let nameSlug: String
    public let gameID: String
    public let displayName: String
    public let cardType: String?
    public let superType: String?
    public let domains: [String]
    public let tags: [String]
    public let energyCost: Int?
    public let mightCost: Int?
    public let attributes: [String: JSONValue]

    public init(nameSlug: String, gameID: String = "riftbound", displayName: String, cardType: String? = nil, superType: String? = nil, domains: [String] = [], tags: [String] = [], energyCost: Int? = nil, mightCost: Int? = nil, attributes: [String: JSONValue] = [:]) {
        self.nameSlug = nameSlug
        self.gameID = gameID
        self.displayName = displayName
        self.cardType = cardType
        self.superType = superType
        self.domains = domains
        self.tags = tags
        self.energyCost = energyCost
        self.mightCost = mightCost
        self.attributes = attributes
    }
}

public struct CardPrinting: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64 { productID }
    public let productID: Int64
    public let nameSlug: String
    public let printingSlug: String
    public let displayName: String
    public let expansionID: Int64?
    public let expansionSlug: String?
    public let printNumber: String?
    public let variant: String?
    public let rarity: String?
    public let finishes: [String]
    public let languages: [String]
    public let imageURL: URL?
    public let imageBackURL: URL?
    public let attributes: [String: JSONValue]

    public init(productID: Int64, nameSlug: String, printingSlug: String, displayName: String, expansionID: Int64? = nil, expansionSlug: String? = nil, printNumber: String? = nil, variant: String? = nil, rarity: String? = nil, finishes: [String] = [], languages: [String] = [], imageURL: URL? = nil, imageBackURL: URL? = nil, attributes: [String: JSONValue] = [:]) {
        self.productID = productID
        self.nameSlug = nameSlug
        self.printingSlug = printingSlug
        self.displayName = displayName
        self.expansionID = expansionID
        self.expansionSlug = expansionSlug
        self.printNumber = printNumber
        self.variant = variant
        self.rarity = rarity
        self.finishes = finishes
        self.languages = languages
        self.imageURL = imageURL
        self.imageBackURL = imageBackURL
        self.attributes = attributes
    }
}

public struct InventoryLine: Codable, Hashable, Identifiable, Sendable {
    public var id: String { inventoryID }
    public let inventoryID: String
    public let customID: String?
    public let productID: Int64
    public let finish: String
    public let condition: String?
    public let language: String?
    public let quantity: Int
    public let graded: JSONValue?
    public let locationName: String?
    public let tags: [String]
    public let comment: String?
    public let notes: String?
    public let isForSale: Bool
    public let listing: JSONValue?
    public let updatedAt: Date

    public init(inventoryID: String, customID: String? = nil, productID: Int64, finish: String, condition: String? = nil, language: String? = nil, quantity: Int, graded: JSONValue? = nil, locationName: String? = nil, tags: [String] = [], comment: String? = nil, notes: String? = nil, isForSale: Bool = false, listing: JSONValue? = nil, updatedAt: Date) {
        self.inventoryID = inventoryID
        self.customID = customID
        self.productID = productID
        self.finish = finish
        self.condition = condition
        self.language = language
        self.quantity = quantity
        self.graded = graded
        self.locationName = locationName
        self.tags = tags
        self.comment = comment
        self.notes = notes
        self.isForSale = isForSale
        self.listing = listing
        self.updatedAt = updatedAt
    }
}

public struct InventoryLocation: Codable, Hashable, Identifiable, Sendable {
    public var id: String { normalizedName }
    public let name: String
    public let normalizedName: String
    public let color: String?
    public let icon: String?

    public init(name: String, color: String? = nil, icon: String? = nil) {
        self.name = name
        self.normalizedName = Self.normalize(name)
        self.color = color
        self.icon = icon
    }

    public static func normalize(_ value: String?) -> String {
        guard let value else { return "__unlocated__" }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "__unlocated__" : normalized
    }
}

public enum LocationKind: String, Codable, CaseIterable, Sendable {
    case storage
    case deck
    case unavailable
}

public struct LocationPolicy: Codable, Hashable, Identifiable, Sendable {
    public var id: String { normalizedName }
    public let normalizedName: String
    public var displayName: String
    public var color: String?
    public var icon: String?
    public var kind: LocationKind
    public var countsAsAvailable: Bool
    public var linkedDeckID: UUID?

    public init(normalizedName: String, displayName: String, color: String? = nil, icon: String? = nil, kind: LocationKind = .storage, countsAsAvailable: Bool = true, linkedDeckID: UUID? = nil) {
        self.normalizedName = normalizedName
        self.displayName = displayName
        self.color = color
        self.icon = icon
        self.kind = kind
        self.countsAsAvailable = countsAsAvailable
        self.linkedDeckID = linkedDeckID
    }
}

public enum DeckState: String, Codable, CaseIterable, Sendable {
    case planned
    case assembled
}

public enum DeckZone: String, Codable, CaseIterable, Sendable {
    case legend
    case chosenChampion
    case main
    case rune
    case battlefield
    case sideboard
}

public struct Deck: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var state: DeckState
    public var rulesetID: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, state: DeckState = .planned, rulesetID: String = "constructed-2026-07-16", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.state = state
        self.rulesetID = rulesetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct DeckEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let deckID: UUID
    public var zone: DeckZone
    public let nameSlug: String
    public var quantity: Int
    public var preferredProductID: Int64?
    public var preferredFinish: String?
    public var preferredLanguage: String?

    public init(id: UUID = UUID(), deckID: UUID, zone: DeckZone, nameSlug: String, quantity: Int, preferredProductID: Int64? = nil, preferredFinish: String? = nil, preferredLanguage: String? = nil) {
        self.id = id
        self.deckID = deckID
        self.zone = zone
        self.nameSlug = nameSlug
        self.quantity = quantity
        self.preferredProductID = preferredProductID
        self.preferredFinish = preferredFinish
        self.preferredLanguage = preferredLanguage
    }
}

public struct LocationQuantity: Codable, Hashable, Identifiable, Sendable {
    public var id: String { normalizedLocationName }
    public let normalizedLocationName: String
    public let displayName: String
    public let color: String?
    public let icon: String?
    public let kind: LocationKind
    public let quantity: Int
    public let isAvailable: Bool
    public let linkedDeckID: UUID?

    public init(normalizedLocationName: String, displayName: String, color: String? = nil, icon: String? = nil, kind: LocationKind, quantity: Int, isAvailable: Bool, linkedDeckID: UUID?) {
        self.normalizedLocationName = normalizedLocationName
        self.displayName = displayName
        self.color = color
        self.icon = icon
        self.kind = kind
        self.quantity = quantity
        self.isAvailable = isAvailable
        self.linkedDeckID = linkedDeckID
    }
}

public struct CardAvailability: Codable, Hashable, Sendable {
    public let totalOwned: Int
    public let availableInStorage: Int
    public let inTargetDeck: Int
    public let inOtherDecks: Int
    public let otherwiseUnavailable: Int
    public let required: Int

    public var usableForTargetDeck: Int { availableInStorage + inTargetDeck }
    public var missing: Int { max(0, required - usableForTargetDeck) }

    public init(totalOwned: Int, availableInStorage: Int, inTargetDeck: Int = 0, inOtherDecks: Int = 0, otherwiseUnavailable: Int = 0, required: Int = 0) {
        self.totalOwned = totalOwned
        self.availableInStorage = availableInStorage
        self.inTargetDeck = inTargetDeck
        self.inOtherDecks = inOtherDecks
        self.otherwiseUnavailable = otherwiseUnavailable
        self.required = required
    }
}

public struct InventoryCardSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String { identity.nameSlug }
    public let identity: CardIdentity
    public let preferredImageURL: URL?
    public let availability: CardAvailability
    public let locations: [LocationQuantity]
    public let marketListings: [CardMarketListing]

    public init(identity: CardIdentity, preferredImageURL: URL?, availability: CardAvailability, locations: [LocationQuantity], marketListings: [CardMarketListing] = []) {
        self.identity = identity
        self.preferredImageURL = preferredImageURL
        self.availability = availability
        self.locations = locations
        self.marketListings = marketListings
    }
}

public struct DeckSnapshot: Codable, Hashable, Sendable {
    public let deck: Deck
    public let entries: [DeckEntry]
    public let identities: [String: CardIdentity]

    public init(deck: Deck, entries: [DeckEntry], identities: [String: CardIdentity]) {
        self.deck = deck
        self.entries = entries
        self.identities = identities
    }
}

public enum ValidationSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct DeckValidationIssue: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let severity: ValidationSeverity
    public let code: String
    public let message: String
    public let affectedNameSlugs: [String]

    public init(id: String = UUID().uuidString, severity: ValidationSeverity, code: String, message: String, affectedNameSlugs: [String] = []) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
        self.affectedNameSlugs = affectedNameSlugs
    }
}
