import Foundation
import RiftBuilderCore
import SwiftUI

struct AppDeckLocationCreationResult: Sendable {
    let policy: LocationPolicy
    let synchronizationWarning: String?
}

enum AppLocationCreationError: LocalizedError {
    case emptyName
    case deckNotFound
    case remoteCreatedButLocalSaveFailed(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a CardNexus location name."
        case .deckNotFound: "Deck locations must link to an existing local deck."
        case let .remoteCreatedButLocalSaveFailed(name, reason): "CardNexus created or updated '\(name)', but RiftBuilder could not save its local deck link: \(reason)"
        }
    }
}

protocol InventoryLocationCreating: AppDataServicing {
    func createInventoryLocation(name: String, color: String?, icon: String?, kind: LocationKind, linkedDeckID: UUID?) async throws -> AppDeckLocationCreationResult
}

extension InventoryLocationCreating {
    func createInventoryLocation(name: String, color: String?, icon: String?, kind: LocationKind, linkedDeckID: UUID?) async throws -> AppDeckLocationCreationResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppLocationCreationError.emptyName }
        if kind == .deck {
            guard let linkedDeckID, try await decks().contains(where: { $0.id == linkedDeckID }) else { throw AppLocationCreationError.deckNotFound }
        }
        let policy = LocationPolicy(
            normalizedName: InventoryLocation.normalize(trimmed),
            displayName: trimmed,
            color: color,
            icon: icon,
            kind: kind,
            countsAsAvailable: kind == .storage,
            linkedDeckID: kind == .deck ? linkedDeckID : nil
        )
        try await saveLocationPolicy(policy)
        return AppDeckLocationCreationResult(policy: policy, synchronizationWarning: nil)
    }
}

extension LiveAppDataService {
    func createInventoryLocation(name: String, color: String?, icon: String?, kind: LocationKind, linkedDeckID: UUID?) async throws -> AppDeckLocationCreationResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AppLocationCreationError.emptyName }
        if kind == .deck {
            guard let linkedDeckID, try await repository.decks().contains(where: { $0.id == linkedDeckID }) else { throw AppLocationCreationError.deckNotFound }
        }

        let remote = try await cardNexus.upsertInventoryLocation(InventoryLocationUpsertRequest(name: trimmed, color: color, icon: icon))
        let policy = LocationPolicy(
            normalizedName: remote.normalizedName,
            displayName: remote.name,
            color: remote.color,
            icon: remote.icon,
            kind: kind,
            countsAsAvailable: kind == .storage,
            linkedDeckID: kind == .deck ? linkedDeckID : nil
        )
        do {
            try await repository.saveLocationPolicy(policy)
        } catch {
            throw AppLocationCreationError.remoteCreatedButLocalSaveFailed(name: remote.name, reason: error.localizedDescription)
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

extension LiveAppDataService: InventoryLocationCreating {}
extension DemoAppDataService: InventoryLocationCreating {}
extension UnavailableAppDataService: InventoryLocationCreating {}

extension AppModel {
    func createInventoryLocation(name: String, color: String?, icon: String?, kind: LocationKind, linkedDeckID: UUID?) async -> Bool {
        guard let creator = service as? any InventoryLocationCreating else {
            notice = "CardNexus location creation is unavailable."
            return false
        }
        do {
            let result = try await creator.createInventoryLocation(name: name, color: color, icon: icon, kind: kind, linkedDeckID: linkedDeckID)
            await reloadAll()
            if let warning = result.synchronizationWarning {
                notice = warning
            } else {
                notice = "Created or updated '\(result.policy.displayName)' in CardNexus as \(result.policy.kind.appTitle.lowercased())."
            }
            return true
        } catch {
            notice = "Location creation failed: \(error.localizedDescription)"
            return false
        }
    }
}

struct CreateLocationView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedDeckID: UUID?
    @State private var kind: LocationKind = .storage
    @State private var icon = "shippingbox"
    @State private var color: Color = .blue
    @State private var understandsRemoteWrite = false
    @State private var isSaving = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var creationButtonTitle: String {
        if isSaving { return "Writing to CardNexus…" }
        return kind == .deck && selectedDeckID != nil ? "Create and Link" : "Create Location"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Location").font(.title2.weight(.semibold))
                Text("Create or update a CardNexus location, then choose how RiftBuilder should treat its inventory.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Location name", text: $name, prompt: Text(kind == .deck ? "Deck: Ahri" : "Box A"))
                    .accessibilityHint("This exact name will be written to CardNexus")
                Picker("Type", selection: $kind) {
                    Label("Box / Storage", systemImage: "shippingbox").tag(LocationKind.storage)
                    Label("Deck", systemImage: "rectangle.stack").tag(LocationKind.deck)
                    Label("Unavailable", systemImage: "nosign").tag(LocationKind.unavailable)
                }
                ColorPicker("Location color", selection: $color, supportsOpacity: false)
                Picker("Icon", selection: $icon) {
                    Label("Box", systemImage: "shippingbox").tag("shippingbox")
                    Label("Archive box", systemImage: "archivebox").tag("archivebox")
                    Label("Deck", systemImage: "rectangle.stack").tag("rectangle.stack")
                    Label("Binder", systemImage: "books.vertical").tag("books.vertical")
                    Label("Shelf", systemImage: "tray.full").tag("tray.full")
                    Label("Unavailable", systemImage: "nosign").tag("nosign")
                }
                if kind == .deck {
                    Picker("Local deck", selection: $selectedDeckID) {
                        Text("Select a deck").tag(UUID?.none)
                        ForEach(model.decks) { deck in Text(deck.name).tag(Optional(deck.id)) }
                    }
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
                Button(creationButtonTitle) {
                    Task {
                        isSaving = true
                        let saved = await model.createInventoryLocation(name: trimmedName, color: color.cardNexusLocationHex, icon: icon, kind: kind, linkedDeckID: selectedDeckID)
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || (kind == .deck && selectedDeckID == nil) || !understandsRemoteWrite || isSaving)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { selectedDeckID = model.selectedDeckID ?? model.decks.first?.id }
        .onChange(of: kind) { _, newKind in icon = newKind.systemImage }
    }
}
