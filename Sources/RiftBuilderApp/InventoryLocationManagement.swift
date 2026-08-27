import Foundation
import RiftBuilderCore

struct AppInventoryLocationEdit: Sendable {
    let original: LocationPolicy
    let name: String
    let color: String?
    let icon: String?
    let kind: LocationKind
    let linkedDeckID: UUID?
}

struct AppInventoryLocationMutationResult: Sendable {
    let policy: LocationPolicy?
    let synchronizationWarning: String?
}

enum AppInventoryLocationManagementError: LocalizedError {
    case emptyName
    case unlocatedCannotBeManaged
    case deckNotFound
    case deckAlreadyLinked(locationName: String)
    case locationNotEmpty(name: String, cardCount: Int)
    case remoteUpdatedButLocalSaveFailed(name: String, reason: String)
    case remoteDeletedButLocalCleanupFailed(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a CardNexus location name."
        case .unlocatedCannotBeManaged:
            "Unlocated cards are not a CardNexus location and cannot be edited or deleted."
        case .deckNotFound:
            "The selected local deck no longer exists."
        case let .deckAlreadyLinked(locationName):
            "That deck is already linked to '\(locationName)'. A location can only be linked to one deck."
        case let .locationNotEmpty(name, cardCount):
            "'\(name)' contains \(cardCount) card\(cardCount == 1 ? "" : "s"). Move every card elsewhere before deleting the location."
        case let .remoteUpdatedButLocalSaveFailed(name, reason):
            "CardNexus updated '\(name)', but RiftBuilder could not migrate its local settings: \(reason). Synchronize before retrying."
        case let .remoteDeletedButLocalCleanupFailed(name, reason):
            "CardNexus deleted '\(name)', but RiftBuilder could not finish its local cleanup: \(reason). Synchronize to reconcile it."
        }
    }
}

protocol InventoryLocationManaging: AppDataServicing {
    func editInventoryLocation(_ edit: AppInventoryLocationEdit) async throws -> AppInventoryLocationMutationResult
    func deleteEmptyInventoryLocation(_ location: LocationPolicy) async throws -> AppInventoryLocationMutationResult
}

extension LiveAppDataService {
    func editInventoryLocation(_ edit: AppInventoryLocationEdit) async throws -> AppInventoryLocationMutationResult {
        let trimmedName = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AppInventoryLocationManagementError.emptyName }
        guard edit.original.normalizedName != "__unlocated__" else { throw AppInventoryLocationManagementError.unlocatedCannotBeManaged }
        _ = try await refreshInventoryOnly()
        if let linkedDeckID = edit.kind == .deck ? edit.linkedDeckID : nil {
            guard try await repository.decks().contains(where: { $0.id == linkedDeckID }) else {
                throw AppInventoryLocationManagementError.deckNotFound
            }
            if let conflict = try await repository.locationPolicies().first(where: {
                $0.normalizedName != edit.original.normalizedName && $0.linkedDeckID == linkedDeckID
            }) {
                throw AppInventoryLocationManagementError.deckAlreadyLinked(locationName: conflict.displayName)
            }
        }

        let remote = try await cardNexus.updateInventoryLocation(InventoryLocationUpdateRequest(
            currentName: edit.original.displayName,
            name: trimmedName,
            color: edit.color,
            icon: edit.icon
        ))
        let policy: LocationPolicy
        do {
            policy = try await repository.replaceLocationPolicy(
                currentNormalizedName: edit.original.normalizedName,
                with: remote,
                kind: edit.kind,
                linkedDeckID: edit.kind == .deck ? edit.linkedDeckID : nil
            )
        } catch {
            throw AppInventoryLocationManagementError.remoteUpdatedButLocalSaveFailed(name: remote.name, reason: error.localizedDescription)
        }

        do {
            _ = try await refreshInventoryOnly()
            return AppInventoryLocationMutationResult(policy: policy, synchronizationWarning: nil)
        } catch {
            return AppInventoryLocationMutationResult(
                policy: policy,
                synchronizationWarning: "The location was updated, but the inventory refresh failed: \(error.localizedDescription)"
            )
        }
    }

    func deleteEmptyInventoryLocation(_ location: LocationPolicy) async throws -> AppInventoryLocationMutationResult {
        guard location.normalizedName != "__unlocated__" else { throw AppInventoryLocationManagementError.unlocatedCannotBeManaged }
        let lines = try await refreshInventoryOnly()
        let cardCount = lines
            .filter { InventoryLocation.normalize($0.locationName) == location.normalizedName }
            .reduce(0) { $0 + $1.quantity }
        guard cardCount == 0 else {
            throw AppInventoryLocationManagementError.locationNotEmpty(name: location.displayName, cardCount: cardCount)
        }

        try await cardNexus.deleteInventoryLocation(named: location.displayName)
        do {
            _ = try await refreshInventoryOnly()
            try await repository.deleteEmptyLocationPolicy(normalizedName: location.normalizedName)
            return AppInventoryLocationMutationResult(policy: nil, synchronizationWarning: nil)
        } catch {
            throw AppInventoryLocationManagementError.remoteDeletedButLocalCleanupFailed(name: location.displayName, reason: error.localizedDescription)
        }
    }

    func refreshInventoryOnly() async throws -> [InventoryLine] {
        async let linesTask = cardNexus.fetchAllInventoryLines(game: "riftbound")
        async let locationsTask = cardNexus.fetchLocations()
        let (lines, locations) = try await (linesTask, locationsTask)
        try await repository.synchronizeInventory(lines: lines, locations: locations, generation: UUID(), completedAt: .now)
        return lines
    }
}

extension LiveAppDataService: InventoryLocationManaging {}

extension DemoAppDataService: InventoryLocationManaging {
    func editInventoryLocation(_ edit: AppInventoryLocationEdit) async throws -> AppInventoryLocationMutationResult {
        let trimmedName = edit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AppInventoryLocationManagementError.emptyName }
        guard edit.original.normalizedName != "__unlocated__" else { throw AppInventoryLocationManagementError.unlocatedCannotBeManaged }
        if let linkedDeckID = edit.kind == .deck ? edit.linkedDeckID : nil,
           let conflict = policies.first(where: { $0.normalizedName != edit.original.normalizedName && $0.linkedDeckID == linkedDeckID })
        {
            throw AppInventoryLocationManagementError.deckAlreadyLinked(locationName: conflict.displayName)
        }
        let replacement = LocationPolicy(
            normalizedName: InventoryLocation.normalize(trimmedName),
            displayName: trimmedName,
            color: edit.color,
            icon: edit.icon,
            kind: edit.kind,
            countsAsAvailable: edit.kind == .storage,
            linkedDeckID: edit.kind == .deck ? edit.linkedDeckID : nil
        )
        if replacement.normalizedName != edit.original.normalizedName,
           policies.contains(where: { $0.normalizedName == replacement.normalizedName })
        {
            throw LocationPolicyPersistenceError.locationNameConflict(trimmedName)
        }
        policies.removeAll { $0.normalizedName == edit.original.normalizedName }
        policies.append(replacement)
        return AppInventoryLocationMutationResult(policy: replacement, synchronizationWarning: nil)
    }

    func deleteEmptyInventoryLocation(_ location: LocationPolicy) async throws -> AppInventoryLocationMutationResult {
        let count = cards.flatMap(\.locations)
            .filter { $0.normalizedName == location.normalizedName }
            .reduce(0) { $0 + $1.quantity }
        guard count == 0 else {
            throw AppInventoryLocationManagementError.locationNotEmpty(name: location.displayName, cardCount: count)
        }
        policies.removeAll { $0.normalizedName == location.normalizedName }
        return AppInventoryLocationMutationResult(policy: nil, synchronizationWarning: nil)
    }
}

extension UnavailableAppDataService: InventoryLocationManaging {
    func editInventoryLocation(_ edit: AppInventoryLocationEdit) async throws -> AppInventoryLocationMutationResult {
        throw AppServiceError.unavailable("CardNexus location editing is unavailable.")
    }

    func deleteEmptyInventoryLocation(_ location: LocationPolicy) async throws -> AppInventoryLocationMutationResult {
        throw AppServiceError.unavailable("CardNexus location deletion is unavailable.")
    }
}

extension AppModel {
    func editInventoryLocation(_ edit: AppInventoryLocationEdit) async -> Bool {
        guard let manager = service as? any InventoryLocationManaging else {
            notice = "CardNexus location editing is unavailable."
            return false
        }
        do {
            let result = try await manager.editInventoryLocation(edit)
            if inventoryLocationFilter == edit.original.normalizedName {
                inventoryLocationFilter = result.policy?.normalizedName
            }
            await loadLocations()
            await loadInventory()
            await loadDecks()
            notice = result.synchronizationWarning ?? "Updated '\(result.policy?.displayName ?? edit.name)' in CardNexus."
            return true
        } catch {
            notice = "Location update failed: \(error.localizedDescription)"
            return false
        }
    }

    func deleteEmptyInventoryLocation(_ location: LocationPolicy) async -> Bool {
        guard let manager = service as? any InventoryLocationManaging else {
            notice = "CardNexus location deletion is unavailable."
            return false
        }
        do {
            let result = try await manager.deleteEmptyInventoryLocation(location)
            if inventoryLocationFilter == location.normalizedName { inventoryLocationFilter = nil }
            await loadLocations()
            await loadInventory()
            await loadDecks()
            notice = result.synchronizationWarning ?? "Deleted the empty location '\(location.displayName)' from CardNexus."
            return true
        } catch {
            notice = "Location deletion failed: \(error.localizedDescription)"
            return false
        }
    }
}
