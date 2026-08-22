import Foundation
import RiftBuilderCore

enum AppDeckLocationImportError: LocalizedError {
    case emptyDeckName
    case illegalDeck([DeckValidationIssue])

    var errorDescription: String? {
        switch self {
        case .emptyDeckName:
            return "Enter a name for the imported deck."
        case let .illegalDeck(issues):
            let errors = issues.filter { $0.severity == .error }.map(\.message)
            return "This location could not be imported because the inferred deck is not legal:\n• \(errors.joined(separator: "\n• "))"
        }
    }
}

protocol DeckLocationImportServicing: AppDataServicing {
    func importDeck(fromLocationKey locationKey: String, named deckName: String) async throws -> DeckSnapshot
}

extension DeckLocationImportServicing {
    func importDeck(fromLocationKey locationKey: String, named deckName: String) async throws -> DeckSnapshot {
        throw AppServiceError.unavailable("Deck import from a location is unavailable.")
    }
}

extension LiveAppDataService {
    func importDeck(fromLocationKey locationKey: String, named requestedName: String) async throws -> DeckSnapshot {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppDeckLocationImportError.emptyDeckName }
        let inventory = try await assemblyStore.assemblyInventorySnapshot()
        guard let location = inventory.locationPolicies.first(where: { $0.normalizedName == locationKey }) else {
            throw DeckLocationImportPersistenceError.locationNotFound(locationKey)
        }
        let productIDs = Set(inventory.lines.filter { InventoryLocation.normalize($0.locationName) == locationKey && $0.quantity > 0 }.map(\.productID))
        let nameSlugs = Set(productIDs.compactMap { inventory.printingsByProductID[$0]?.nameSlug })
        let identities = try await repository.cardIdentities(nameSlugs: nameSlugs)
        let result = try DeckLocationImporter().makeCandidate(DeckLocationImportRequest(
            deckName: name,
            location: location,
            inventory: inventory,
            identities: identities,
            ruleset: ruleset
        ))
        guard result.canSave else { throw AppDeckLocationImportError.illegalDeck(result.validationIssues) }
        try await repository.importDeckSnapshot(result.snapshot, fromLocationKey: locationKey)
        return result.snapshot
    }
}

extension LiveAppDataService: DeckLocationImportServicing {}
extension DemoAppDataService: DeckLocationImportServicing {}
extension UnavailableAppDataService: DeckLocationImportServicing {}

extension AppModel {
    func importDeck(from location: LocationPolicy, named name: String) async -> Bool {
        guard let importer = service as? any DeckLocationImportServicing else {
            notice = "Deck import from a location is unavailable."
            return false
        }
        do {
            let snapshot = try await importer.importDeck(fromLocationKey: location.normalizedName, named: name)
            await loadLocations()
            await loadDecks()
            selectedDeckID = snapshot.deck.id
            destination = .decks
            await loadSelectedDeck()
            if snapshot.deck.state == .assembled {
                notice = "Imported \(snapshot.deck.name) and linked it to \(location.displayName)."
            } else {
                notice = "Imported \(snapshot.deck.name) as a pending deck and linked it to \(location.displayName). Complete the missing requirements in the deck editor."
            }
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
}
