import Foundation
import RiftBuilderCore

actor LiveAppDataService: AppDataServicing {
    private static let lastSyncDefaultsKey = "riftbuilder.lastSuccessfulSync"

    private let credentialStore: SessionCredentialStore
    let cardNexus: CardNexusClient
    let repository: GRDBRiftBuilderRepository
    let assemblyStore: GRDBAssemblyStore
    let assemblyExecutor: AssemblyExecutor
    let ruleset: ConstructedRuleset
    private let defaults: UserDefaults

    init(
        credentialStore: any CredentialStoring = KeychainCredentialStore(),
        defaults: UserDefaults = .standard
    ) throws {
        let applicationSupport = try Self.applicationSupportDirectory()
        let databasePath = applicationSupport.appending(path: "riftbuilder.sqlite").path
        let repository = try GRDBRiftBuilderRepository(path: databasePath)
        let sessionCredentialStore = SessionCredentialStore(backingStore: credentialStore)

        let cardNexus = CardNexusClient(credentialStore: sessionCredentialStore)
        let assemblyStore = try GRDBAssemblyStore(path: databasePath)
        self.credentialStore = sessionCredentialStore
        self.cardNexus = cardNexus
        self.repository = repository
        self.assemblyStore = assemblyStore
        self.assemblyExecutor = AssemblyExecutor(writer: cardNexus, journal: assemblyStore)
        self.ruleset = try ConstructedRulesetLoader.bundled()
        self.defaults = defaults
    }

    func hasStoredCredential() async throws -> Bool {
        guard let value = try credentialStore.loadAPIKey() else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func storeAndVerifyCredential(_ apiKey: String) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppServiceError.invalidCredential }
        let previous = try credentialStore.loadAPIKey()
        try credentialStore.saveAPIKey(trimmed)
        do {
            try await cardNexus.verifyCredential()
        } catch {
            if let previous {
                try? credentialStore.saveAPIKey(previous)
            } else {
                try? credentialStore.deleteAPIKey()
            }
            throw error
        }
    }

    func deleteCredential() async throws {
        try credentialStore.deleteAPIKey()
    }

    func synchronize() async throws -> Date {
        let metadata = try await cardNexus.fetchCatalogueMetadata(game: "riftbound")
        if try await repository.catalogueChecksum() != metadata.checksum {
            let stream = try await cardNexus.downloadCatalogue(from: metadata.url)
            var printings: [CardPrinting] = []
            printings.reserveCapacity(metadata.recordCount)
            for try await printing in stream {
                try Task.checkCancellation()
                printings.append(printing)
            }
            try await repository.replaceCatalogue(
                printings: printings,
                checksum: metadata.checksum,
                completedAt: Date()
            )
        }

        async let inventoryTask = cardNexus.fetchAllInventoryLines(game: "riftbound")
        async let locationsTask = cardNexus.fetchLocations()
        let (lines, locations) = try await (inventoryTask, locationsTask)
        try Task.checkCancellation()
        let completedAt = Date()
        try await repository.synchronizeInventory(
            lines: lines,
            locations: locations,
            generation: UUID(),
            completedAt: completedAt
        )

        defaults.set(completedAt, forKey: Self.lastSyncDefaultsKey)
        return completedAt
    }

    func lastSuccessfulSync() async -> Date? {
        defaults.object(forKey: Self.lastSyncDefaultsKey) as? Date
    }

    func inventoryCards(search: String?, targetDeckID: UUID?) async throws -> [AppInventoryCard] {
        try await repository.inventoryCards(search: search, targetDeckID: targetDeckID).map(AppInventoryCard.init(summary:))
    }

    func locationPolicies() async throws -> [LocationPolicy] {
        try await repository.locationPolicies()
    }

    func saveLocationPolicy(_ policy: LocationPolicy) async throws {
        try await repository.saveLocationPolicy(policy)
    }

    func decks() async throws -> [Deck] {
        try await repository.decks()
    }

    func deckLegendDomains() async throws -> [UUID: [String]] {
        try await repository.deckLegendDomains()
    }

    func deckSnapshot(id: UUID) async throws -> DeckSnapshot? {
        try await repository.deckSnapshot(id: id)
    }

    func beginDeckDraft(id: UUID) async throws -> DeckDraftSnapshot? {
        try await repository.beginDeckDraft(id: id)
    }

    func deckDraftSnapshot(id: UUID) async throws -> DeckDraftSnapshot? {
        try await repository.deckDraftSnapshot(id: id)
    }

    func saveDeckDraftEntry(_ entry: DeckEntry) async throws {
        try await repository.saveDeckDraftEntry(entry)
    }

    func deleteDeckDraftEntry(id: UUID) async throws {
        try await repository.deleteDeckDraftEntry(id: id)
    }

    func discardDeckDraft(id: UUID) async throws {
        try await repository.discardDeckDraft(id: id)
    }

    func saveDeck(_ deck: Deck) async throws {
        try await repository.saveDeck(deck)
    }

    func deleteDeck(id: UUID) async throws {
        try await repository.deleteDeck(id: id)
    }

    func saveDeckEntry(_ entry: DeckEntry) async throws {
        try await repository.saveDeckEntry(entry)
    }

    func deleteDeckEntry(id: UUID) async throws {
        try await repository.deleteDeckEntry(id: id)
    }

    func validationIssues(for snapshot: DeckSnapshot) async -> [DeckValidationIssue] {
        DeckRulesEngine.validate(snapshot: snapshot, ruleset: ruleset)
    }

    private static func applicationSupportDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw AppServiceError.unavailable("The Application Support directory is unavailable.")
        }
        let directory = base.appending(path: "RiftBuilder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

actor UnavailableAppDataService: AppDataServicing {
    private let startupError: String

    init(error: any Error) {
        self.startupError = error.localizedDescription
    }

    func hasStoredCredential() async throws -> Bool { throw failure }
    func storeAndVerifyCredential(_ apiKey: String) async throws { throw failure }
    func deleteCredential() async throws { throw failure }
    func synchronize() async throws -> Date { throw failure }
    func lastSuccessfulSync() async -> Date? { nil }
    func inventoryCards(search: String?, targetDeckID: UUID?) async throws -> [AppInventoryCard] { throw failure }
    func locationPolicies() async throws -> [LocationPolicy] { throw failure }
    func saveLocationPolicy(_ policy: LocationPolicy) async throws { throw failure }
    func decks() async throws -> [Deck] { throw failure }
    func deckLegendDomains() async throws -> [UUID: [String]] { throw failure }
    func deckSnapshot(id: UUID) async throws -> DeckSnapshot? { throw failure }
    func beginDeckDraft(id: UUID) async throws -> DeckDraftSnapshot? { throw failure }
    func deckDraftSnapshot(id: UUID) async throws -> DeckDraftSnapshot? { throw failure }
    func saveDeckDraftEntry(_ entry: DeckEntry) async throws { throw failure }
    func deleteDeckDraftEntry(id: UUID) async throws { throw failure }
    func discardDeckDraft(id: UUID) async throws { throw failure }
    func saveDeck(_ deck: Deck) async throws { throw failure }
    func deleteDeck(id: UUID) async throws { throw failure }
    func saveDeckEntry(_ entry: DeckEntry) async throws { throw failure }
    func deleteDeckEntry(id: UUID) async throws { throw failure }
    func validationIssues(for snapshot: DeckSnapshot) async -> [DeckValidationIssue] { [] }

    private var failure: AppServiceError {
        .unavailable("RiftBuilder could not initialize its local database: \(startupError)")
    }
}
