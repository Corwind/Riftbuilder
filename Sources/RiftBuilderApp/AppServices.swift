import Foundation
import RiftBuilderCore

protocol AppDataServicing: Sendable {
    func hasStoredCredential() async throws -> Bool
    func storeAndVerifyCredential(_ apiKey: String) async throws
    func deleteCredential() async throws
    func synchronize() async throws -> Date
    func lastSuccessfulSync() async -> Date?
    func inventoryCards(search: String?, targetDeckID: UUID?) async throws -> [AppInventoryCard]
    func locationPolicies() async throws -> [LocationPolicy]
    func saveLocationPolicy(_ policy: LocationPolicy) async throws
    func decks() async throws -> [Deck]
    func deckLegendDomains() async throws -> [UUID: [String]]
    func deckSnapshot(id: UUID) async throws -> DeckSnapshot?
    func beginDeckDraft(id: UUID) async throws -> DeckDraftSnapshot?
    func deckDraftSnapshot(id: UUID) async throws -> DeckDraftSnapshot?
    func saveDeckDraftEntry(_ entry: DeckEntry) async throws
    func deleteDeckDraftEntry(id: UUID) async throws
    func discardDeckDraft(id: UUID) async throws
    func saveDeck(_ deck: Deck) async throws
    func deleteDeck(id: UUID) async throws
    func saveDeckEntry(_ entry: DeckEntry) async throws
    func deleteDeckEntry(id: UUID) async throws
    func validationIssues(for snapshot: DeckSnapshot) async -> [DeckValidationIssue]
}

actor DemoAppDataService: AppDataServicing {
    private var credentialStored = false
    private var lastSync: Date?
    private var policies: [LocationPolicy]
    private var storedDecks: [Deck]
    private var snapshots: [UUID: DeckSnapshot]
    private var drafts: [UUID: DeckDraftSnapshot] = [:]
    private let cards: [AppInventoryCard]

    init() {
        let ahri = CardIdentity(nameSlug: "ahri-charmer", displayName: "Ahri, Charmer", cardType: "Unit", domains: ["Calm", "Chaos"], tags: ["Champion"], energyCost: 3, mightCost: 2)
        let battlefield = CardIdentity(nameSlug: "spirit-realm", displayName: "Spirit Realm", cardType: "Battlefield", domains: ["Calm"])
        let rune = CardIdentity(nameSlug: "calm-rune", displayName: "Calm Rune", cardType: "Rune", domains: ["Calm"])
        let jinx = CardIdentity(nameSlug: "jinx-rebel", displayName: "Jinx, Rebel", cardType: "Unit", domains: ["Chaos"], tags: ["Champion"], energyCost: 4, mightCost: 3)
        let deckID = UUID(uuidString: "8A82DFEC-3C44-43B2-94A5-BA0244327E35")!
        let locations = [
            LocationPolicy(normalizedName: "box a", displayName: "Box A", kind: .storage, countsAsAvailable: true),
            LocationPolicy(normalizedName: "box b", displayName: "Box B", kind: .storage, countsAsAvailable: true),
            LocationPolicy(normalizedName: "deck: ahri", displayName: "Deck: Ahri", kind: .deck, countsAsAvailable: false, linkedDeckID: deckID),
            LocationPolicy(normalizedName: "trade binder", displayName: "Trade Binder", kind: .unavailable, countsAsAvailable: false),
        ]
        policies = locations
        let deck = Deck(id: deckID, name: "Ahri Tempo", state: .assembled)
        let entries = [
            DeckEntry(deckID: deckID, zone: .chosenChampion, nameSlug: ahri.nameSlug, quantity: 1),
            DeckEntry(deckID: deckID, zone: .battlefield, nameSlug: battlefield.nameSlug, quantity: 1),
            DeckEntry(deckID: deckID, zone: .rune, nameSlug: rune.nameSlug, quantity: 8),
            DeckEntry(deckID: deckID, zone: .main, nameSlug: ahri.nameSlug, quantity: 2),
        ]
        storedDecks = [deck, Deck(name: "Jinx Burn", state: .planned)]
        snapshots = [deckID: DeckSnapshot(deck: deck, entries: entries, identities: [ahri.nameSlug: ahri, battlefield.nameSlug: battlefield, rune.nameSlug: rune])]
        cards = [
            AppInventoryCard(
                identity: ahri,
                availability: CardAvailability(totalOwned: 6, availableInStorage: 4, inTargetDeck: 2, required: 3),
                locations: [
                    AppLocationBreakdown(normalizedName: "box a", displayName: "Box A", kind: .storage, quantity: 3, isAvailable: true, linkedDeckID: nil),
                    AppLocationBreakdown(normalizedName: "box b", displayName: "Box B", kind: .storage, quantity: 1, isAvailable: true, linkedDeckID: nil),
                    AppLocationBreakdown(normalizedName: "deck: ahri", displayName: "Deck: Ahri", kind: .deck, quantity: 2, isAvailable: false, linkedDeckID: deckID),
                ],
                expansion: "Origins",
                rarity: "Epic",
                finish: "Normal",
                language: "English"
            ),
            AppInventoryCard(
                identity: battlefield,
                availability: CardAvailability(totalOwned: 4, availableInStorage: 3, inTargetDeck: 1, required: 1),
                locations: [
                    AppLocationBreakdown(normalizedName: "box a", displayName: "Box A", kind: .storage, quantity: 3, isAvailable: true, linkedDeckID: nil),
                    AppLocationBreakdown(normalizedName: "deck: ahri", displayName: "Deck: Ahri", kind: .deck, quantity: 1, isAvailable: false, linkedDeckID: deckID),
                ],
                expansion: "Origins",
                rarity: "Rare",
                finish: "Normal",
                language: "English"
            ),
            AppInventoryCard(
                identity: rune,
                availability: CardAvailability(totalOwned: 16, availableInStorage: 8, inTargetDeck: 8, required: 12),
                locations: [
                    AppLocationBreakdown(normalizedName: "box b", displayName: "Box B", kind: .storage, quantity: 8, isAvailable: true, linkedDeckID: nil),
                    AppLocationBreakdown(normalizedName: "deck: ahri", displayName: "Deck: Ahri", kind: .deck, quantity: 8, isAvailable: false, linkedDeckID: deckID),
                ],
                expansion: "Origins",
                rarity: "Common",
                finish: "Normal",
                language: "English"
            ),
            AppInventoryCard(
                identity: jinx,
                availability: CardAvailability(totalOwned: 3, availableInStorage: 2, otherwiseUnavailable: 1, required: 0),
                locations: [
                    AppLocationBreakdown(normalizedName: "box a", displayName: "Box A", kind: .storage, quantity: 2, isAvailable: true, linkedDeckID: nil),
                    AppLocationBreakdown(normalizedName: "trade binder", displayName: "Trade Binder", kind: .unavailable, quantity: 1, isAvailable: false, linkedDeckID: nil),
                ],
                expansion: "Spiritforged",
                rarity: "Rare",
                finish: "Foil",
                language: "English"
            ),
        ]
    }

    func hasStoredCredential() async throws -> Bool { credentialStored }

    func storeAndVerifyCredential(_ apiKey: String) async throws {
        guard apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else { throw AppServiceError.invalidCredential }
        credentialStored = true
    }

    func deleteCredential() async throws { credentialStored = false }

    func synchronize() async throws -> Date {
        guard credentialStored else { throw AppServiceError.invalidCredential }
        try await Task.sleep(for: .milliseconds(500))
        let date = Date()
        lastSync = date
        return date
    }

    func lastSuccessfulSync() async -> Date? { lastSync }

    func inventoryCards(search: String?, targetDeckID: UUID?) async throws -> [AppInventoryCard] {
        guard let search, !search.isEmpty else { return cards }
        return cards.filter { card in
            card.identity.displayName.localizedCaseInsensitiveContains(search)
                || card.identity.nameSlug.localizedCaseInsensitiveContains(search)
                || card.identity.domains.contains(where: { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    func locationPolicies() async throws -> [LocationPolicy] { policies }

    func saveLocationPolicy(_ policy: LocationPolicy) async throws {
        if let index = policies.firstIndex(where: { $0.normalizedName == policy.normalizedName }) {
            policies[index] = policy
        } else {
            policies.append(policy)
        }
    }

    func decks() async throws -> [Deck] { storedDecks.sorted { $0.updatedAt > $1.updatedAt } }

    func deckLegendDomains() async throws -> [UUID: [String]] {
        Dictionary(uniqueKeysWithValues: snapshots.compactMap { deckID, snapshot in
            let domains = snapshot.entries.filter { $0.zone == .legend }.flatMap { snapshot.identities[$0.nameSlug]?.domains ?? [] }
            return domains.isEmpty ? nil : (deckID, domains)
        })
    }

    func deckSnapshot(id: UUID) async throws -> DeckSnapshot? {
        if let snapshot = snapshots[id] { return snapshot }
        guard let deck = storedDecks.first(where: { $0.id == id }) else { return nil }
        return DeckSnapshot(deck: deck, entries: [], identities: [:])
    }

    func beginDeckDraft(id: UUID) async throws -> DeckDraftSnapshot? {
        if let draft = drafts[id] { return draft }
        guard let saved = try await deckSnapshot(id: id) else { return nil }
        let now = Date()
        let draft = DeckDraftSnapshot(deck: saved.deck, entries: saved.entries, identities: saved.identities, baseDeckUpdatedAt: saved.deck.updatedAt, createdAt: now, updatedAt: now)
        drafts[id] = draft
        return draft
    }

    func deckDraftSnapshot(id: UUID) async throws -> DeckDraftSnapshot? { drafts[id] }

    func saveDeckDraftEntry(_ entry: DeckEntry) async throws {
        guard let current = drafts[entry.deckID] else { return }
        var entries = current.entries.filter { $0.id != entry.id }
        if let match = entries.firstIndex(where: {
            $0.zone == entry.zone && $0.nameSlug == entry.nameSlug && $0.preferredProductID == entry.preferredProductID
                && $0.preferredFinish == entry.preferredFinish && $0.preferredLanguage == entry.preferredLanguage
        }) {
            entries[match].quantity += entry.quantity
        } else {
            entries.append(entry)
        }
        var identities = current.identities
        if identities[entry.nameSlug] == nil, let identity = cards.first(where: { $0.id == entry.nameSlug })?.identity { identities[entry.nameSlug] = identity }
        drafts[entry.deckID] = DeckDraftSnapshot(deck: current.deck, entries: entries, identities: identities, baseDeckUpdatedAt: current.baseDeckUpdatedAt, createdAt: current.createdAt, updatedAt: Date())
    }

    func deleteDeckDraftEntry(id: UUID) async throws {
        guard let pair = drafts.first(where: { $0.value.entries.contains(where: { $0.id == id }) }) else { return }
        let current = pair.value
        drafts[pair.key] = DeckDraftSnapshot(deck: current.deck, entries: current.entries.filter { $0.id != id }, identities: current.identities, baseDeckUpdatedAt: current.baseDeckUpdatedAt, createdAt: current.createdAt, updatedAt: Date())
    }

    func discardDeckDraft(id: UUID) async throws { drafts[id] = nil }

    func saveDeck(_ deck: Deck) async throws {
        if let index = storedDecks.firstIndex(where: { $0.id == deck.id }) {
            storedDecks[index] = deck
        } else {
            storedDecks.append(deck)
        }
        let current = snapshots[deck.id]
        snapshots[deck.id] = DeckSnapshot(deck: deck, entries: current?.entries ?? [], identities: current?.identities ?? [:])
    }

    func deleteDeck(id: UUID) async throws {
        storedDecks.removeAll { $0.id == id }
        snapshots[id] = nil
        drafts[id] = nil
    }

    func saveDeckEntry(_ entry: DeckEntry) async throws {
        guard let current = snapshots[entry.deckID] else { return }
        var entries = current.entries.filter { $0.id != entry.id }
        entries.append(entry)
        var identities = current.identities
        if identities[entry.nameSlug] == nil, let identity = cards.first(where: { $0.id == entry.nameSlug })?.identity {
            identities[entry.nameSlug] = identity
        }
        snapshots[entry.deckID] = DeckSnapshot(deck: current.deck, entries: entries, identities: identities)
    }

    func deleteDeckEntry(id: UUID) async throws {
        guard let pair = snapshots.first(where: { $0.value.entries.contains(where: { $0.id == id }) }) else { return }
        let current = pair.value
        snapshots[pair.key] = DeckSnapshot(deck: current.deck, entries: current.entries.filter { $0.id != id }, identities: current.identities)
    }

    func validationIssues(for snapshot: DeckSnapshot) async -> [DeckValidationIssue] {
        var issues: [DeckValidationIssue] = []
        let mainCount = snapshot.entries.filter { $0.zone == .main || $0.zone == .chosenChampion }.reduce(0) { $0 + $1.quantity }
        let runeCount = snapshot.entries.filter { $0.zone == .rune }.reduce(0) { $0 + $1.quantity }
        let legendCount = snapshot.entries.filter { $0.zone == .legend }.reduce(0) { $0 + $1.quantity }
        let battlefieldNames = Set(snapshot.entries.filter { $0.zone == .battlefield }.map(\.nameSlug))
        if mainCount != 40 { issues.append(DeckValidationIssue(severity: .error, code: "main-count", message: "Main deck needs exactly 40 cards (currently \(mainCount)).")) }
        if runeCount != 12 { issues.append(DeckValidationIssue(severity: .error, code: "rune-count", message: "Rune deck needs exactly 12 cards (currently \(runeCount)).")) }
        if legendCount != 1 { issues.append(DeckValidationIssue(severity: .error, code: "legend-count", message: "Choose exactly one Champion Legend.")) }
        if battlefieldNames.count != 3 { issues.append(DeckValidationIssue(severity: .warning, code: "battlefields", message: "Choose three uniquely named battlefields.")) }
        return issues
    }
}
