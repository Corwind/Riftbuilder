import Foundation
import RiftBuilderCore
import SwiftUI

struct AppDeckLocationCreationResult: Sendable {
    let policy: LocationPolicy
    let synchronizationWarning: String?
}

enum AppDeckLocationCreationError: LocalizedError {
    case emptyName
    case deckNotFound
    case remoteCreatedButLocalSaveFailed(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a CardNexus location name."
        case .deckNotFound: "Select an existing local deck to link."
        case let .remoteCreatedButLocalSaveFailed(name, reason): "CardNexus created or updated '\(name)', but RiftBuilder could not save its local deck link: \(reason)"
        }
    }
}

protocol DeckLocationCreating: AppDataServicing {
    func createDeckLocation(name: String, color: String?, linkedDeckID: UUID) async throws -> AppDeckLocationCreationResult
}

extension DeckLocationCreating {
    func createDeckLocation(name: String, color: String?, linkedDeckID: UUID) async throws -> AppDeckLocationCreationResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppDeckLocationCreationError.emptyName }
        guard try await decks().contains(where: { $0.id == linkedDeckID }) else { throw AppDeckLocationCreationError.deckNotFound }
        let policy = LocationPolicy(
            normalizedName: InventoryLocation.normalize(trimmed),
            displayName: trimmed,
            color: color,
            kind: .deck,
            countsAsAvailable: false,
            linkedDeckID: linkedDeckID
        )
        try await saveLocationPolicy(policy)
        return AppDeckLocationCreationResult(policy: policy, synchronizationWarning: nil)
    }
}

extension LiveAppDataService {
    func createDeckLocation(name: String, color: String?, linkedDeckID: UUID) async throws -> AppDeckLocationCreationResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppDeckLocationCreationError.emptyName }
        guard try await repository.decks().contains(where: { $0.id == linkedDeckID }) else { throw AppDeckLocationCreationError.deckNotFound }

        let remote = try await cardNexus.upsertInventoryLocation(InventoryLocationUpsertRequest(name: trimmed, color: color))
        let policy = LocationPolicy(
            normalizedName: remote.normalizedName,
            displayName: remote.name,
            color: remote.color,
            icon: remote.icon,
            kind: .deck,
            countsAsAvailable: false,
            linkedDeckID: linkedDeckID
        )
        do {
            try await repository.saveLocationPolicy(policy)
        } catch {
            throw AppDeckLocationCreationError.remoteCreatedButLocalSaveFailed(name: remote.name, reason: error.localizedDescription)
        }

        do {
            _ = try await synchronize()
            try await repository.saveLocationPolicy(policy)
            return AppDeckLocationCreationResult(policy: policy, synchronizationWarning: nil)
        } catch {
            return AppDeckLocationCreationResult(
                policy: policy,
                synchronizationWarning: "The remote location and local deck link were saved, but inventory refresh failed: \(error.localizedDescription)"
            )
        }
    }
}

extension LiveAppDataService: DeckLocationCreating {}
extension DemoAppDataService: DeckLocationCreating {}
extension UnavailableAppDataService: DeckLocationCreating {}

extension AppModel {
    func createDeckLocation(name: String, color: String?, linkedDeckID: UUID?) async -> Bool {
        guard let linkedDeckID else {
            notice = AppDeckLocationCreationError.deckNotFound.localizedDescription
            return false
        }
        guard let creator = service as? any DeckLocationCreating else {
            notice = "CardNexus location creation is unavailable."
            return false
        }
        do {
            let result = try await creator.createDeckLocation(name: name, color: color, linkedDeckID: linkedDeckID)
            await reloadAll()
            if let warning = result.synchronizationWarning {
                notice = warning
            } else {
                notice = "Created or updated '\(result.policy.displayName)' in CardNexus and linked it to the selected deck."
            }
            return true
        } catch {
            notice = "Deck location creation failed: \(error.localizedDescription)"
            return false
        }
    }
}

struct CreateDeckLocationView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedDeckID: UUID?
    @State private var color: Color = .blue
    @State private var understandsRemoteWrite = false
    @State private var isSaving = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Deck Location").font(.title2.weight(.semibold))
                Text("Create or update a physical location in CardNexus and link it to one local deck.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Location name", text: $name, prompt: Text("Deck: Ahri"))
                    .accessibilityHint("This exact name will be written to CardNexus")
                ColorPicker("Location color", selection: $color, supportsOpacity: false)
                Picker("Local deck", selection: $selectedDeckID) {
                    Text("Select a deck").tag(UUID?.none)
                    ForEach(model.decks) { deck in Text(deck.name).tag(Optional(deck.id)) }
                }
            }
            .formStyle(.grouped)

            Label("This writes to CardNexus using inventory:write. If a case-insensitive location match already exists, CardNexus updates or returns that location instead of creating a duplicate.", systemImage: "exclamationmark.shield.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("I understand this creates or updates a CardNexus location.", isOn: $understandsRemoteWrite)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isSaving ? "Writing to CardNexus…" : "Create and Link") {
                    Task {
                        isSaving = true
                        let saved = await model.createDeckLocation(name: trimmedName, color: color.cardNexusLocationHex, linkedDeckID: selectedDeckID)
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || selectedDeckID == nil || !understandsRemoteWrite || isSaving)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { selectedDeckID = model.selectedDeckID ?? model.decks.first?.id }
    }
}
