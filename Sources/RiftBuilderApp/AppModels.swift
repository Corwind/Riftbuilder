import Foundation
import RiftBuilderCore

enum AppDestination: String, CaseIterable, Identifiable {
    case inventory
    case catalogue
    case decks
    case locations
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .inventory: "Inventory"
        case .catalogue: "Catalogue"
        case .decks: "Decks"
        case .locations: "Locations"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .inventory: "square.grid.2x2"
        case .catalogue: "books.vertical"
        case .decks: "rectangle.stack"
        case .locations: "shippingbox"
        case .settings: "gearshape"
        }
    }
}

enum InventoryPresentation: String, CaseIterable, Identifiable {
    case table
    case grid

    var id: Self { self }
    var systemImage: String { self == .table ? "list.bullet" : "square.grid.2x2" }
}

enum InventoryScope: String, CaseIterable, Identifiable {
    case all
    case available

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct AppLocationBreakdown: Identifiable, Hashable, Sendable {
    let normalizedName: String
    let displayName: String
    let color: String?
    let icon: String?
    let kind: LocationKind
    let quantity: Int
    let isAvailable: Bool
    let linkedDeckID: UUID?

    var id: String { normalizedName }

    init(normalizedName: String, displayName: String, color: String? = nil, icon: String? = nil, kind: LocationKind, quantity: Int, isAvailable: Bool, linkedDeckID: UUID?) {
        self.normalizedName = normalizedName
        self.displayName = displayName
        self.color = color
        self.icon = icon
        self.kind = kind
        self.quantity = quantity
        self.isAvailable = isAvailable
        self.linkedDeckID = linkedDeckID
    }
}

struct AppInventoryCard: Identifiable, Hashable, Sendable {
    let identity: CardIdentity
    let imageURL: URL?
    let availability: CardAvailability
    let locations: [AppLocationBreakdown]
    let expansion: String?
    let rarity: String?
    let finish: String?
    let language: String?

    var id: String { identity.nameSlug }

    init(summary: InventoryCardSummary) {
        identity = summary.identity
        imageURL = summary.preferredImageURL
        availability = summary.availability
        locations = summary.locations.map {
            AppLocationBreakdown(
                normalizedName: $0.normalizedLocationName,
                displayName: $0.displayName,
                color: $0.color,
                icon: $0.icon,
                kind: $0.kind,
                quantity: $0.quantity,
                isAvailable: $0.isAvailable,
                linkedDeckID: $0.linkedDeckID
            )
        }
        expansion = nil
        rarity = nil
        finish = nil
        language = nil
    }

    init(identity: CardIdentity, imageURL: URL? = nil, availability: CardAvailability, locations: [AppLocationBreakdown], expansion: String? = nil, rarity: String? = nil, finish: String? = nil, language: String? = nil) {
        self.identity = identity
        self.imageURL = imageURL
        self.availability = availability
        self.locations = locations
        self.expansion = expansion
        self.rarity = rarity
        self.finish = finish
        self.language = language
    }
}

extension AppInventoryCard {
    func visibleLocations(filteredBy normalizedLocationName: String?) -> [AppLocationBreakdown] {
        locations
            .filter { location in
                location.quantity > 0
                    && location.kind != .unavailable
                    && normalizedLocationName.map { $0 == location.normalizedName } != false
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    func displayedInventoryQuantity(filteredBy normalizedLocationName: String?) -> Int {
        guard normalizedLocationName != nil else { return availability.totalOwned }
        return visibleLocations(filteredBy: normalizedLocationName).reduce(0) { $0 + $1.quantity }
    }

    var usedInDecksQuantity: Int {
        availability.inTargetDeck + availability.inOtherDecks
    }
}

struct DeckNamingRequest: Identifiable, Hashable {
    enum Purpose: Hashable {
        case create
        case rename(deckID: UUID)
    }

    let id = UUID()
    let purpose: Purpose
    let initialName: String

    var title: String {
        switch purpose {
        case .create: "New Deck"
        case .rename: "Rename Deck"
        }
    }

    var confirmationTitle: String {
        switch purpose {
        case .create: "Create Deck"
        case .rename: "Rename"
        }
    }
}

enum CredentialState: Equatable, Sendable {
    case missing
    case stored
    case validating
    case invalid(String)
}

enum SyncState: Equatable, Sendable {
    case idle
    case syncing(progress: Double, message: String)
    case failed(message: String, cachedDataAvailable: Bool)

    var isSyncing: Bool {
        if case .syncing = self { true } else { false }
    }
}

enum ContentLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum AppServiceError: LocalizedError {
    case invalidCredential
    case offline
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "CardNexus rejected this API key. Create one with exactly inventory:read and inventory:write access; no other scope is needed."
        case .offline: "CardNexus is unreachable. Cached data is still available."
        case let .unavailable(message): message
        }
    }
}

extension CardIdentity {
    var appSearchText: String {
        [
            displayName,
            nameSlug,
            cardType ?? "",
            superType ?? "",
            domains.joined(separator: " "),
            tags.joined(separator: " "),
            attributes.values.map(\.appSearchText).joined(separator: " "),
        ].joined(separator: " ")
    }
}

private extension JSONValue {
    var appSearchText: String {
        switch self {
        case let .string(value): value
        case let .number(value): String(value)
        case let .bool(value): value ? "true" : "false"
        case let .object(value): value.values.map(\.appSearchText).joined(separator: " ")
        case let .array(value): value.map(\.appSearchText).joined(separator: " ")
        case .null: ""
        }
    }
}

extension DeckZone {
    var appTitle: String {
        switch self {
        case .legend: "Legend"
        case .chosenChampion: "Chosen Champion"
        case .main: "Main Deck"
        case .rune: "Runes"
        case .battlefield: "Battlefields"
        case .sideboard: "Sideboard"
        }
    }

    var appSortOrder: Int {
        switch self {
        case .legend: 0
        case .chosenChampion: 1
        case .battlefield: 2
        case .rune: 3
        case .main: 4
        case .sideboard: 5
        }
    }
}

extension LocationKind {
    var appTitle: String {
        switch self {
        case .storage: "Storage"
        case .deck: "Deck"
        case .unavailable: "Unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .storage: "shippingbox"
        case .deck: "rectangle.stack"
        case .unavailable: "nosign"
        }
    }
}
