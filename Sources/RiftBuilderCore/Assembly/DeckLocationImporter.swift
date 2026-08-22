import Foundation

public enum DeckLocationImportError: Error, Hashable, Sendable {
    case locationMustBeClassifiedAsDeck(String)
    case locationAlreadyLinked(String, UUID)
    case emptyLocation(String)
    case missingCatalogueProducts([Int64])
}

extension DeckLocationImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .locationMustBeClassifiedAsDeck(name):
            return "The location '\(name)' must be classified as Deck before it can be imported."
        case let .locationAlreadyLinked(name, _):
            return "The location '\(name)' is already linked to a deck."
        case let .emptyLocation(name):
            return "The location '\(name)' does not contain any synchronized cards."
        case let .missingCatalogueProducts(productIDs):
            return "Some cards in this location are missing from the local catalogue (product IDs: \(productIDs.map(String.init).joined(separator: ", "))). Synchronize before importing."
        }
    }
}

public struct DeckLocationImportRequest: Sendable {
    public let deckID: UUID
    public let deckName: String
    public let location: LocationPolicy
    public let inventory: AssemblyInventorySnapshot
    public let identities: [String: CardIdentity]
    public let ruleset: ConstructedRuleset
    public let createdAt: Date

    public init(deckID: UUID = UUID(), deckName: String, location: LocationPolicy, inventory: AssemblyInventorySnapshot, identities: [String: CardIdentity], ruleset: ConstructedRuleset, createdAt: Date = Date()) {
        self.deckID = deckID
        self.deckName = deckName
        self.location = location
        self.inventory = inventory
        self.identities = identities
        self.ruleset = ruleset
        self.createdAt = createdAt
    }
}

public enum DeckLocationImportDisposition: String, Codable, Hashable, Sendable {
    case legal
    case pending
    case invalid
}

public struct DeckLocationImportResult: Sendable {
    public let snapshot: DeckSnapshot
    public let validationIssues: [DeckValidationIssue]
    public let disposition: DeckLocationImportDisposition

    public init(snapshot: DeckSnapshot, validationIssues: [DeckValidationIssue], disposition: DeckLocationImportDisposition) {
        self.snapshot = snapshot
        self.validationIssues = validationIssues
        self.disposition = disposition
    }

    public var canSave: Bool { disposition != .invalid }
}

/// Reconstructs a deterministic deck definition from physical inventory in one
/// CardNexus Deck location. CardNexus does not retain deck-zone metadata, so
/// role-specific zones are inferred and excess non-role cards become Sideboard.
public struct DeckLocationImporter: Sendable {
    public init() {}

    public func makeCandidate(_ request: DeckLocationImportRequest) throws -> DeckLocationImportResult {
        guard request.location.kind == .deck else {
            throw DeckLocationImportError.locationMustBeClassifiedAsDeck(request.location.displayName)
        }
        if let linkedDeckID = request.location.linkedDeckID {
            throw DeckLocationImportError.locationAlreadyLinked(request.location.displayName, linkedDeckID)
        }

        let locationKey = request.location.normalizedName
        let lines = request.inventory.lines.filter {
            $0.quantity > 0 && InventoryLocation.normalize($0.locationName) == locationKey
        }
        guard !lines.isEmpty else { throw DeckLocationImportError.emptyLocation(request.location.displayName) }
        let missingProducts = Set(lines.filter { request.inventory.printingsByProductID[$0.productID] == nil }.map(\.productID)).sorted()
        guard missingProducts.isEmpty else { throw DeckLocationImportError.missingCatalogueProducts(missingProducts) }

        var quantitiesByLot: [ImportLotKey: Int] = [:]
        for line in lines {
            guard let printing = request.inventory.printingsByProductID[line.productID] else { continue }
            quantitiesByLot[ImportLotKey(nameSlug: printing.nameSlug, productID: line.productID, finish: line.finish, language: line.language), default: 0] += line.quantity
        }
        var lots = quantitiesByLot.map { key, quantity in
            ImportLot(nameSlug: key.nameSlug, productID: key.productID, finish: key.finish, language: key.language, quantity: quantity, identity: request.identities[key.nameSlug])
        }
        lots.sort(by: Self.lotLessThan)

        var entries: [DeckEntry] = []
        var ordinaryLots: [ImportLot] = []
        for lot in lots {
            if lot.identity.map(DeckCardEligibility.isLegend) == true {
                append(lot: lot, quantity: lot.quantity, zone: .legend, deckID: request.deckID, to: &entries)
            } else if lot.identity.map(DeckCardEligibility.isRune) == true {
                append(lot: lot, quantity: lot.quantity, zone: .rune, deckID: request.deckID, to: &entries)
            } else if lot.identity.map(DeckCardEligibility.isBattlefield) == true {
                append(lot: lot, quantity: lot.quantity, zone: .battlefield, deckID: request.deckID, to: &entries)
            } else {
                ordinaryLots.append(lot)
            }
        }

        let legend = entries.first(where: { $0.zone == .legend }).flatMap { request.identities[$0.nameSlug] }
        let championIndex = ordinaryLots.indices.first { index in
            guard ordinaryLots[index].quantity > 0, let identity = ordinaryLots[index].identity else { return false }
            return DeckCardEligibility.allows(identity, in: .chosenChampion, legend: legend)
        }
        if let championIndex {
            append(lot: ordinaryLots[championIndex], quantity: 1, zone: .chosenChampion, deckID: request.deckID, to: &entries)
            ordinaryLots[championIndex].quantity -= 1
        }

        // Always reserve the chosen-champion slot. Without a scanned champion,
        // the inferred definition remains a true subset that can be completed by
        // adding one, instead of requiring a main-deck card to be removed first.
        var mainSlots = max(0, request.ruleset.mainDeckCount - 1)
        for lot in ordinaryLots where lot.quantity > 0 {
            let mainQuantity = min(mainSlots, lot.quantity)
            append(lot: lot, quantity: mainQuantity, zone: .main, deckID: request.deckID, to: &entries)
            mainSlots -= mainQuantity
            append(lot: lot, quantity: lot.quantity - mainQuantity, zone: .sideboard, deckID: request.deckID, to: &entries)
        }

        let provisionalDeck = Deck(
            id: request.deckID,
            name: request.deckName.trimmingCharacters(in: .whitespacesAndNewlines),
            state: .planned,
            rulesetID: request.ruleset.id,
            createdAt: request.createdAt,
            updatedAt: request.createdAt
        )
        let provisionalSnapshot = DeckSnapshot(deck: provisionalDeck, entries: entries, identities: request.identities)
        let issues = DeckRulesEngine.validate(snapshot: provisionalSnapshot, ruleset: request.ruleset)
        let disposition: DeckLocationImportDisposition
        if !issues.contains(where: { $0.severity == .error }) {
            disposition = .legal
        } else if Self.isCompletableSubset(entries: entries, issues: issues, ruleset: request.ruleset) {
            disposition = .pending
        } else {
            disposition = .invalid
        }
        var deck = provisionalDeck
        deck.state = disposition == .legal ? .assembled : .planned
        return DeckLocationImportResult(
            snapshot: DeckSnapshot(deck: deck, entries: entries, identities: request.identities),
            validationIssues: issues,
            disposition: disposition
        )
    }
}

private extension DeckLocationImporter {
    struct ImportLot {
        let nameSlug: String
        let productID: Int64
        let finish: String
        let language: String?
        var quantity: Int
        let identity: CardIdentity?
    }

    struct ImportLotKey: Hashable {
        let nameSlug: String
        let productID: Int64
        let finish: String
        let language: String?
    }

    func append(lot: ImportLot, quantity: Int, zone: DeckZone, deckID: UUID, to entries: inout [DeckEntry]) {
        guard quantity > 0 else { return }
        entries.append(DeckEntry(
            deckID: deckID,
            zone: zone,
            nameSlug: lot.nameSlug,
            quantity: quantity,
            preferredProductID: lot.productID,
            preferredFinish: lot.finish,
            preferredLanguage: lot.language
        ))
    }

    static func lotLessThan(_ lhs: ImportLot, _ rhs: ImportLot) -> Bool {
        let leftName = lhs.identity?.displayName ?? lhs.nameSlug
        let rightName = rhs.identity?.displayName ?? rhs.nameSlug
        let comparison = leftName.localizedCaseInsensitiveCompare(rightName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        if lhs.nameSlug != rhs.nameSlug { return lhs.nameSlug < rhs.nameSlug }
        if lhs.productID != rhs.productID { return lhs.productID < rhs.productID }
        if lhs.finish != rhs.finish { return lhs.finish < rhs.finish }
        return (lhs.language ?? "") < (rhs.language ?? "")
    }

    static func isCompletableSubset(entries: [DeckEntry], issues: [DeckValidationIssue], ruleset: ConstructedRuleset) -> Bool {
        let allowedIncompleteCodes: Set<String> = [
            "main_deck_count",
            "legend_count",
            "chosen_champion_count",
            "rune_count",
            "battlefield_count",
            "battlefield_uniqueness",
        ]
        let errorCodes = Set(issues.filter { $0.severity == .error }.map(\.code))
        guard errorCodes.isSubset(of: allowedIncompleteCodes) else { return false }

        let mainCount = entries.filter { $0.zone == .main || $0.zone == .chosenChampion }.reduce(0) { $0 + $1.quantity }
        let legendCount = entries.filter { $0.zone == .legend }.reduce(0) { $0 + $1.quantity }
        let championCount = entries.filter { $0.zone == .chosenChampion }.reduce(0) { $0 + $1.quantity }
        let runeCount = entries.filter { $0.zone == .rune }.reduce(0) { $0 + $1.quantity }
        let battlefields = entries.filter { $0.zone == .battlefield }
        let battlefieldCount = battlefields.reduce(0) { $0 + $1.quantity }
        let battlefieldsAreUniqueSingles = battlefields.allSatisfy { $0.quantity == 1 }
            && Set(battlefields.map(\.nameSlug)).count == battlefields.count

        return mainCount <= ruleset.mainDeckCount
            && legendCount <= 1
            && championCount <= 1
            && runeCount <= ruleset.runeCount
            && battlefieldCount <= ruleset.battlefieldCount
            && battlefieldsAreUniqueSingles
    }
}
