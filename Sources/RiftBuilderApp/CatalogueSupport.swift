import Foundation
import RiftBuilderCore

struct AppCatalogueCard: Identifiable, Hashable, Sendable {
    let identity: CardIdentity
    let preferredImageURL: URL?
    let printingCount: Int
    let expansionSlugs: [String]
    let rarities: [String]
    let preferredPrinting: CataloguePrintingMetadata?
    let availability: CardAvailability

    var id: String { identity.nameSlug }

    var inventoryCard: AppInventoryCard {
        AppInventoryCard(
            identity: identity,
            imageURL: preferredImageURL,
            availability: availability,
            locations: [],
            expansion: preferredPrinting?.expansionSlug,
            rarity: preferredPrinting?.rarity
        )
    }
}

protocol CatalogueServicing: AppDataServicing {
    func appCatalogueCards(search: String?) async throws -> [AppCatalogueCard]
    func cardIdentities(nameSlugs: Set<String>) async throws -> [String: CardIdentity]
}

extension CatalogueServicing {
    func appCatalogueCards(search: String?) async throws -> [AppCatalogueCard] {
        try await inventoryCards(search: search, targetDeckID: nil).map {
            AppCatalogueCard(
                identity: $0.identity,
                preferredImageURL: $0.imageURL,
                printingCount: 1,
                expansionSlugs: [$0.expansion].compactMap { $0 },
                rarities: [$0.rarity].compactMap { $0 },
                preferredPrinting: nil,
                availability: $0.availability
            )
        }
    }

    func cardIdentities(nameSlugs: Set<String>) async throws -> [String: CardIdentity] {
        let cards = try await inventoryCards(search: nil, targetDeckID: nil)
        return Dictionary(uniqueKeysWithValues: cards.filter { nameSlugs.contains($0.id) }.map { ($0.id, $0.identity) })
    }
}

extension LiveAppDataService {
    func appCatalogueCards(search: String?) async throws -> [AppCatalogueCard] {
        async let catalogueTask = repository.catalogueCards(search: search)
        async let inventoryTask = repository.inventoryCards(search: nil, targetDeckID: nil)
        let (catalogue, inventory) = try await (catalogueTask, inventoryTask)
        let availability = Dictionary(uniqueKeysWithValues: inventory.map { ($0.identity.nameSlug, $0.availability) })
        return catalogue.map { card in
            AppCatalogueCard(
                identity: card.identity,
                preferredImageURL: card.preferredImageURL,
                printingCount: card.printingCount,
                expansionSlugs: card.expansionSlugs,
                rarities: card.rarities,
                preferredPrinting: card.preferredPrinting,
                availability: availability[card.identity.nameSlug] ?? CardAvailability(totalOwned: 0, availableInStorage: 0)
            )
        }
    }

    func cardIdentities(nameSlugs: Set<String>) async throws -> [String: CardIdentity] {
        try await repository.cardIdentities(nameSlugs: nameSlugs)
    }
}

extension AppModel {
    func catalogueCards(search: String?) async throws -> [AppCatalogueCard] {
        guard let catalogueService = service as? any CatalogueServicing else {
            throw AppServiceError.unavailable("The card catalogue is unavailable.")
        }
        return try await catalogueService.appCatalogueCards(search: search)
    }
}
