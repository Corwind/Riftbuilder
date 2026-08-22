import Foundation
import Observation
import RiftBuilderCore

@MainActor
@Observable
final class AppModel {
    private static let alwaysAvailableRunesKey = "riftbuilder.deckInventory.alwaysAvailableRunes"
    private static let alwaysAvailableBattlefieldsKey = "riftbuilder.deckInventory.alwaysAvailableBattlefields"

    var destination: AppDestination? = .inventory
    var inventoryPresentation: InventoryPresentation = .grid
    var inventoryScope: InventoryScope = .all
    var inventorySearch = ""
    var inventoryLocationFilter: String?
    var inventory: [AppInventoryCard] = []
    var inventoryLoadState: ContentLoadState = .idle
    var catalogue: [AppCatalogueCard] = []
    var catalogueByNameSlug: [String: AppCatalogueCard] = [:]
    var catalogueLoadState: ContentLoadState = .idle
    var selectedInventoryCardID: String?
    var locations: [LocationPolicy] = []
    var locationLoadState: ContentLoadState = .idle
    var decks: [Deck] = []
    var deckDomains: [UUID: [String]] = [:]
    var deckLoadState: ContentLoadState = .idle
    var selectedDeckID: UUID?
    var selectedDeckSnapshot: DeckSnapshot?
    var validationIssues: [DeckValidationIssue] = []
    var credentialState: CredentialState = .missing
    var syncState: SyncState = .idle
    var lastSuccessfulSync: Date?
    var isOffline = false
    var notice: String?
    var searchFocusRequest = 0
    var isCardPickerPresented = false
    var isCardAdditionInFlight = false
    var pickerSearch = ""
    var pickerZone: DeckZone = .main
    var deckNamingRequest: DeckNamingRequest?
    var alwaysAvailableRunes: Bool {
        didSet { defaults.set(alwaysAvailableRunes, forKey: Self.alwaysAvailableRunesKey) }
    }
    var alwaysAvailableBattlefields: Bool {
        didSet { defaults.set(alwaysAvailableBattlefields, forKey: Self.alwaysAvailableBattlefieldsKey) }
    }

    let service: any AppDataServicing
    @ObservationIgnored private let defaults: UserDefaults
    private var didBootstrap = false

    init(service: any AppDataServicing, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        alwaysAvailableRunes = defaults.object(forKey: Self.alwaysAvailableRunesKey) as? Bool ?? true
        alwaysAvailableBattlefields = defaults.object(forKey: Self.alwaysAvailableBattlefieldsKey) as? Bool ?? true
    }

    var deckInventoryAvailability: DeckInventoryAvailability {
        DeckInventoryAvailability(
            alwaysAvailableRunes: alwaysAvailableRunes,
            alwaysAvailableBattlefields: alwaysAvailableBattlefields
        )
    }

    var filteredInventory: [AppInventoryCard] {
        let query = inventorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return inventory.filter { card in
            let matchesScope = inventoryScope == .all || card.availability.availableInStorage > 0
            let matchesLocation = inventoryLocationFilter.map { selected in
                card.locations.contains { $0.normalizedName == selected && $0.quantity > 0 }
            } ?? true
            guard matchesScope, matchesLocation else { return false }
            guard !query.isEmpty else { return true }
            let searchableText = [card.identity.appSearchText, card.expansion ?? "", card.rarity ?? ""].joined(separator: " ")
            return searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    var visibleLocations: [LocationPolicy] {
        locations.filter { $0.kind != .unavailable }
    }

    var selectedInventoryCard: AppInventoryCard? {
        inventory.first { $0.id == selectedInventoryCardID }
    }

    var selectedDeck: Deck? {
        decks.first { $0.id == selectedDeckID }
    }

    func linkableDecks(for location: LocationPolicy) -> [Deck] {
        let linkedElsewhere = Set(locations.compactMap { candidate -> UUID? in
            guard candidate.normalizedName != location.normalizedName else { return nil }
            return candidate.linkedDeckID
        })
        return decks.filter { !linkedElsewhere.contains($0.id) || $0.id == location.linkedDeckID }
    }

    var selectedLegendIdentity: CardIdentity? {
        guard let snapshot = selectedDeckSnapshot,
              let legendEntry = snapshot.entries.first(where: { $0.zone == .legend })
        else { return nil }
        return snapshot.identities[legendEntry.nameSlug] ?? catalogueByNameSlug[legendEntry.nameSlug]?.identity
    }

    var selectedLegendDomains: [String] {
        selectedLegendIdentity?.domains ?? []
    }

    func deckZoneQuantity(_ zone: DeckZone) -> Int {
        DeckZoneCapacity.totalQuantity(in: zone, entries: selectedDeckSnapshot?.entries ?? [])
    }

    func canAddCard(_ card: AppInventoryCard, to zone: DeckZone) -> Bool {
        !isCardAdditionInFlight
            && DeckCardEligibility.allows(card.identity, in: zone, legend: selectedLegendIdentity)
            && DeckZoneCapacity.canAdd(nameSlug: card.id, to: zone, entries: selectedDeckSnapshot?.entries ?? [])
    }

    var inventoryTotal: Int { inventory.reduce(0) { $0 + $1.availability.totalOwned } }
    var availableTotal: Int { inventory.reduce(0) { $0 + $1.availability.availableInStorage } }
    var deckTotal: Int { inventory.reduce(0) { $0 + $1.availability.inTargetDeck + $1.availability.inOtherDecks } }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            credentialState = try await service.hasStoredCredential() ? .stored : .missing
        } catch {
            credentialState = .invalid(error.localizedDescription)
        }
        lastSuccessfulSync = await service.lastSuccessfulSync()
        await reloadAll()
    }

    func reloadAll(forceCatalogueReload: Bool = false) async {
        async let inventoryResult: Void = loadInventory()
        async let locationResult: Void = loadLocations()
        async let deckResult: Void = loadDecks()
        async let catalogueResult: Void = loadCatalogue(force: forceCatalogueReload)
        _ = await (inventoryResult, locationResult, deckResult, catalogueResult)
    }

    func loadCatalogue(force: Bool = false) async {
        if !force, catalogueLoadState == .loaded, !catalogue.isEmpty { return }
        catalogueLoadState = .loading
        do {
            let cards = try await catalogueCards(search: nil)
            catalogue = cards
            catalogueByNameSlug = Dictionary(uniqueKeysWithValues: cards.map { ($0.identity.nameSlug, $0) })
            catalogueLoadState = .loaded
        } catch {
            catalogueLoadState = .failed(error.localizedDescription)
        }
    }

    func loadInventory() async {
        inventoryLoadState = .loading
        do {
            inventory = try await service.inventoryCards(search: nil, targetDeckID: selectedDeckID)
            inventoryLoadState = .loaded
            if selectedInventoryCardID == nil { selectedInventoryCardID = inventory.first?.id }
        } catch {
            inventoryLoadState = .failed(error.localizedDescription)
        }
    }

    func loadLocations() async {
        locationLoadState = .loading
        do {
            locations = try await service.locationPolicies().sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            if let inventoryLocationFilter, !locations.contains(where: { $0.normalizedName == inventoryLocationFilter && $0.kind != .unavailable }) {
                self.inventoryLocationFilter = nil
            }
            locationLoadState = .loaded
        } catch {
            locationLoadState = .failed(error.localizedDescription)
        }
    }

    func loadDecks() async {
        deckLoadState = .loading
        do {
            async let decksTask = service.decks()
            async let domainsTask = service.deckLegendDomains()
            let (loadedDecks, loadedDomains) = try await (decksTask, domainsTask)
            decks = loadedDecks
            deckDomains = loadedDomains
            deckLoadState = .loaded
            if selectedDeckID == nil { selectedDeckID = decks.first?.id }
            await loadSelectedDeck()
        } catch {
            deckLoadState = .failed(error.localizedDescription)
        }
    }

    func loadSelectedDeck() async {
        guard let selectedDeckID else {
            selectedDeckSnapshot = nil
            validationIssues = []
            return
        }
        do {
            selectedDeckSnapshot = try await service.beginDeckDraft(id: selectedDeckID)?.deckSnapshot
            if let selectedDeckSnapshot {
                validationIssues = await service.validationIssues(for: selectedDeckSnapshot)
                let domains = selectedDeckSnapshot.entries
                    .filter { $0.zone == .legend }
                    .flatMap { selectedDeckSnapshot.identities[$0.nameSlug]?.appVisibleDomains ?? [] }
                deckDomains[selectedDeckID] = domains
            }
            await loadInventory()
        } catch {
            notice = error.localizedDescription
        }
    }

    func saveCredential(_ key: String) async -> Bool {
        credentialState = .validating
        do {
            try await service.storeAndVerifyCredential(key)
            credentialState = .stored
            notice = "API key accepted for inventory reading and stored securely. CardNexus will check inventory:write access when a physical move is attempted."
            return true
        } catch {
            credentialState = .invalid(error.localizedDescription)
            return false
        }
    }

    func deleteCredential() async {
        do {
            try await service.deleteCredential()
            credentialState = .missing
            notice = "Stored API key removed."
        } catch {
            notice = error.localizedDescription
        }
    }

    func synchronize() async {
        guard !syncState.isSyncing else { return }
        syncState = .syncing(progress: 0.15, message: "Connecting to CardNexus…")
        do {
            syncState = .syncing(progress: 0.55, message: "Refreshing catalogue and inventory…")
            let completedAt = try await service.synchronize()
            syncState = .syncing(progress: 0.9, message: "Updating local views…")
            await reloadAll(forceCatalogueReload: true)
            lastSuccessfulSync = completedAt
            isOffline = false
            syncState = .idle
            notice = "Inventory is up to date."
        } catch {
            isOffline = true
            syncState = .failed(message: error.localizedDescription, cachedDataAvailable: !inventory.isEmpty)
        }
    }

    func updateLocation(_ original: LocationPolicy, kind: LocationKind, linkedDeckID: UUID? = nil) async {
        var policy = original
        policy.kind = kind
        policy.countsAsAvailable = kind == .storage
        policy.linkedDeckID = kind == .deck ? linkedDeckID : nil
        do {
            try await service.saveLocationPolicy(policy)
            await loadLocations()
            await loadInventory()
        } catch {
            notice = error.localizedDescription
        }
    }

    func requestNewDeckNaming() {
        deckNamingRequest = DeckNamingRequest(purpose: .create, initialName: "")
        destination = .decks
    }

    func requestRenameSelectedDeck() {
        guard let deck = selectedDeck else { return }
        deckNamingRequest = DeckNamingRequest(purpose: .rename(deckID: deck.id), initialName: deck.name)
    }

    func commitDeckName(_ name: String, request: DeckNamingRequest) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        do {
            switch request.purpose {
            case .create:
                let deck = Deck(name: trimmedName)
                try await service.saveDeck(deck)
                await loadDecks()
                selectedDeckID = deck.id
                destination = .decks
                await loadSelectedDeck()
            case let .rename(deckID):
                guard var deck = decks.first(where: { $0.id == deckID }) else { return }
                deck.name = trimmedName
                deck.updatedAt = Date()
                try await service.saveDeck(deck)
                selectedDeckID = deckID
                await loadDecks()
            }
            deckNamingRequest = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func renameSelectedDeck(_ name: String) async {
        guard var deck = selectedDeck, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        deck.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        deck.updatedAt = Date()
        do {
            try await service.saveDeck(deck)
            await loadDecks()
        } catch {
            notice = error.localizedDescription
        }
    }

    func setSelectedDeckState(_ state: DeckState) async {
        guard var deck = selectedDeck else { return }
        deck.state = state
        deck.updatedAt = Date()
        do {
            try await service.saveDeck(deck)
            await loadDecks()
        } catch {
            notice = error.localizedDescription
        }
    }

    func deleteSelectedDeck() async {
        guard let id = selectedDeckID else { return }
        do {
            try await service.deleteDeck(id: id)
            selectedDeckID = nil
            await loadDecks()
        } catch {
            notice = error.localizedDescription
        }
    }

    func changeQuantity(_ entry: DeckEntry, delta: Int) async {
        var changed = entry
        changed.quantity += delta
        do {
            if changed.quantity <= 0 {
                try await service.deleteDeckDraftEntry(id: changed.id)
            } else {
                try await service.saveDeckDraftEntry(changed)
            }
            await loadSelectedDeck()
        } catch {
            notice = error.localizedDescription
        }
    }

    func addCard(_ card: AppInventoryCard, zone: DeckZone) async {
        guard let deckID = selectedDeckID, !isCardAdditionInFlight else { return }
        guard DeckCardEligibility.allows(card.identity, in: zone, legend: selectedLegendIdentity) else {
            notice = "\(card.identity.displayName) is not eligible for the \(zone.appTitle) zone."
            return
        }
        guard DeckZoneCapacity.canAdd(nameSlug: card.id, to: zone, entries: selectedDeckSnapshot?.entries ?? []) else {
            if let maximum = DeckZoneCapacity.maximumTotalQuantity(for: zone), deckZoneQuantity(zone) >= maximum {
                notice = "The \(zone.appTitle) zone is limited to \(maximum) card\(maximum == 1 ? "" : "s")."
            } else {
                notice = "\(card.identity.displayName) is already present in the \(zone.appTitle) zone."
            }
            return
        }
        isCardAdditionInFlight = true
        defer { isCardAdditionInFlight = false }
        if let existing = selectedDeckSnapshot?.entries.first(where: { $0.nameSlug == card.id && $0.zone == zone }) {
            await changeQuantity(existing, delta: 1)
            return
        }
        do {
            try await service.saveDeckDraftEntry(DeckEntry(deckID: deckID, zone: zone, nameSlug: card.id, quantity: 1))
            isCardPickerPresented = false
            await loadSelectedDeck()
        } catch {
            notice = error.localizedDescription
        }
    }

    func focusSearch() {
        destination = .inventory
        searchFocusRequest += 1
    }

}
