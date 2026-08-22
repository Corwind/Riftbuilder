import Foundation

public struct CatalogueFeedMetadata: Codable, Hashable, Sendable {
    public let url: URL
    public let checksum: String
    public let recordCount: Int
    public let generatedAt: Date

    public init(url: URL, checksum: String, recordCount: Int, generatedAt: Date) {
        self.url = url
        self.checksum = checksum
        self.recordCount = recordCount
        self.generatedAt = generatedAt
    }
}

public protocol CardNexusServicing: Sendable {
    func verifyCredential() async throws
    func fetchAllInventoryLines(game: String) async throws -> [InventoryLine]
    func fetchLocations() async throws -> [InventoryLocation]
    func fetchCatalogueMetadata(game: String) async throws -> CatalogueFeedMetadata
    func downloadCatalogue(from url: URL) async throws -> AsyncThrowingStream<CardPrinting, any Error>
}

public protocol CredentialStoring: Sendable {
    func loadAPIKey() throws -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}

public protocol RiftBuilderRepository: Sendable {
    func synchronizeInventory(lines: [InventoryLine], locations: [InventoryLocation], generation: UUID, completedAt: Date) async throws
    func replaceCatalogue(printings: [CardPrinting], checksum: String, completedAt: Date) async throws
    func cardIdentities(nameSlugs: Set<String>) async throws -> [String: CardIdentity]
    func catalogueIdentities(search: String?) async throws -> [CardIdentity]
    func catalogueCards(search: String?) async throws -> [CatalogueCardSummary]



    func catalogueChecksum() async throws -> String?
    func inventoryCards(search: String?, targetDeckID: UUID?) async throws -> [InventoryCardSummary]
    func locationPolicies() async throws -> [LocationPolicy]
    func saveLocationPolicy(_ policy: LocationPolicy) async throws
    func decks() async throws -> [Deck]
    func deckLegendDomains() async throws -> [UUID: [String]]
    func deckSnapshot(id: UUID) async throws -> DeckSnapshot?
    func deckDraftSnapshot(id: UUID) async throws -> DeckDraftSnapshot?
    func beginDeckDraft(id: UUID, at date: Date) async throws -> DeckDraftSnapshot?
    func saveDeckDraftEntry(_ entry: DeckEntry, at date: Date) async throws
    func deleteDeckDraftEntry(id: UUID, at date: Date) async throws
    func discardDeckDraft(id: UUID) async throws
    func commitDeckDraft(id: UUID, at date: Date) async throws -> DeckSnapshot?
    func saveDeck(_ deck: Deck) async throws
    func deleteDeck(id: UUID) async throws
    func saveDeckEntry(_ entry: DeckEntry) async throws
    func deleteDeckEntry(id: UUID) async throws
}
