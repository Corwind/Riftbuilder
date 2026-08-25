import RiftBuilderCore
import SwiftUI

struct LocationsView: View {
    @Bindable var model: AppModel
    @State private var isCreatingLocation = false
    @State private var importLocation: LocationPolicy?
    @State private var editLocation: LocationPolicy?

    var body: some View {
        Group {
            switch model.locationLoadState {
            case .idle where model.locations.isEmpty, .loading where model.locations.isEmpty:
                LoadingStateView(message: "Loading locations…")
            case let .failed(message) where model.locations.isEmpty:
                FailureStateView(title: "Locations unavailable", message: message) {
                    Task { await model.loadLocations() }
                }
            default:
                if model.locations.isEmpty {
                    ContentUnavailableView {
                        Label("No Locations", systemImage: "shippingbox")
                    } description: {
                        Text("Create a location here or synchronize locations already present in CardNexus.")
                    } actions: {
                        Button("Create Location") { isCreatingLocation = true }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            locationSummary
                            ForEach(model.locations) { policy in
                                LocationPolicyRow(
                                    policy: policy,
                                    cardCount: model.inventoryTotalsByLocation[policy.normalizedName] ?? 0,
                                    linkedDeckName: policy.linkedDeckID.flatMap { id in model.decks.first { $0.id == id }?.name },
                                    importDeck: { importLocation = policy },
                                    edit: { editLocation = policy }
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Locations")
        .toolbar {
            Button {
                isCreatingLocation = true
            } label: {
                Label("Create Location", systemImage: "plus")
            }
            Button {
                Task { await model.loadLocations() }
            } label: {
                Label("Refresh Locations", systemImage: "arrow.clockwise")
            }
        }
        .sheet(isPresented: $isCreatingLocation) {
            CreateLocationView(model: model)
        }
        .sheet(item: $importLocation) { location in
            ImportDeckFromLocationView(location: location, model: model)
        }
        .sheet(item: $editLocation) { location in
            EditLocationView(
                location: location,
                cardCount: model.inventoryTotalsByLocation[location.normalizedName] ?? 0,
                model: model
            )
        }
    }

    private var locationSummary: some View {
        HStack(spacing: 18) {
            Label("\(model.locations.filter { $0.kind == .storage }.count) storage", systemImage: "shippingbox")
            Label("\(model.locations.filter { $0.kind == .deck }.count) decks", systemImage: "rectangle.stack")
            Label("\(model.locations.filter { $0.kind == .unavailable }.count) unavailable", systemImage: "nosign")
            Spacer()
            Text("Storage locations count as available when deck building.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background { ThemedCardSurface(cornerRadius: 12, tintStrength: 0.055, shadowStrength: 0.07) }
    }
}

private struct LocationPolicyRow: View {
    let policy: LocationPolicy
    let cardCount: Int
    let linkedDeckName: String?
    let importDeck: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            LocationColorSwatch(value: policy.color, size: 18)
            Image(systemName: policy.kind.systemImage)
                .font(.title2)
                .foregroundStyle(policy.kind == .storage ? .green : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(policy.displayName).font(.headline)
                Text(policy.normalizedName == "__unlocated__" ? "Cards without a CardNexus location" : "CardNexus location")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if policy.kind == .deck && policy.linkedDeckID == nil {
                    Button(action: importDeck) {
                        Label("Create deck from this location", systemImage: "rectangle.stack.badge.plus")
                    }
                    .buttonStyle(.link)
                    .help("Create a legal deck definition from cards in this location")
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Label(policy.kind.appTitle, systemImage: policy.kind.systemImage)
                    .font(.callout.weight(.medium))
                Text("\(cardCount) card\(cardCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let linkedDeckName {
                    Text(linkedDeckName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 120, alignment: .trailing)
            if policy.normalizedName != "__unlocated__" {
                Button(action: edit) {
                    Label("Edit Location", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .help("Edit the name, color, icon, type, and deck link")
            }
        }
        .padding(14)
        .background { ThemedCardSurface(cornerRadius: 12, tintStrength: 0.055, shadowStrength: 0.07) }
        .accessibilityElement(children: .contain)
    }
}

private struct EditLocationView: View {
    let location: LocationPolicy
    let cardCount: Int
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: LocationKind
    @State private var linkedDeckID: UUID?
    @State private var icon: String
    @State private var color: Color
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var isConfirmingDelete = false

    init(location: LocationPolicy, cardCount: Int, model: AppModel) {
        self.location = location
        self.cardCount = cardCount
        self.model = model
        _name = State(initialValue: location.displayName)
        _kind = State(initialValue: location.kind)
        _linkedDeckID = State(initialValue: location.linkedDeckID)
        _icon = State(initialValue: location.icon ?? location.kind.systemImage)
        _color = State(initialValue: Color(cardNexusLocationColor: location.color) ?? .blue)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isWorking: Bool { isSaving || isDeleting }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit Location").font(.title2.weight(.semibold))
                Text("Update its CardNexus appearance and how RiftBuilder uses it.")
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("CardNexus") {
                    TextField("Location name", text: $name)
                    ColorPicker("Location color", selection: $color, supportsOpacity: false)
                    Picker("Icon", selection: $icon) {
                        Label("Box", systemImage: "shippingbox").tag("shippingbox")
                        Label("Archive box", systemImage: "archivebox").tag("archivebox")
                        Label("Deck", systemImage: "rectangle.stack").tag("rectangle.stack")
                        Label("Binder", systemImage: "books.vertical").tag("books.vertical")
                        Label("Shelf", systemImage: "tray.full").tag("tray.full")
                        Label("Unavailable", systemImage: "nosign").tag("nosign")
                    }
                }

                Section("RiftBuilder") {
                    Picker("Type", selection: $kind) {
                        Label("Box / Storage", systemImage: "shippingbox").tag(LocationKind.storage)
                        Label("Deck", systemImage: "rectangle.stack").tag(LocationKind.deck)
                        Label("Unavailable", systemImage: "nosign").tag(LocationKind.unavailable)
                    }
                    if kind == .deck {
                        Picker("Linked deck", selection: $linkedDeckID) {
                            Text("Not linked").tag(UUID?.none)
                            ForEach(model.linkableDecks(for: location)) { deck in
                                Text(deck.name).tag(Optional(deck.id))
                            }
                        }
                    }
                    LabeledContent("Availability") {
                        Text(kind == .storage ? "Available for deck building" : "Unavailable for deck building")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Inventory") {
                    LabeledContent("Cards in this location", value: "\(cardCount)")
                    if cardCount == 0 {
                        Button("Delete Empty Location…", role: .destructive) { isConfirmingDelete = true }
                            .disabled(isWorking)
                    } else {
                        Label("Move every card elsewhere before this location can be deleted.", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Label("Saving writes the name, color, and icon to CardNexus using inventory:write. Renaming keeps the cards in this location. RiftBuilder preserves its type, deck link, and remembered return routes under the new name.", systemImage: "exclamationmark.shield.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(isSaving ? "Saving…" : "Save Changes") {
                    Task {
                        isSaving = true
                        let saved = await model.editInventoryLocation(AppInventoryLocationEdit(
                            original: location,
                            name: trimmedName,
                            color: color.cardNexusLocationHex,
                            icon: icon,
                            kind: kind,
                            linkedDeckID: kind == .deck ? linkedDeckID : nil
                        ))
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty || isWorking)
            }
        }
        .padding(24)
        .frame(width: 600)
        .onChange(of: kind) { oldKind, newKind in
            if icon == oldKind.systemImage { icon = newKind.systemImage }
            if newKind != .deck { linkedDeckID = nil }
        }
        .alert("Delete \(location.displayName)?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Location", role: .destructive) {
                Task {
                    isDeleting = true
                    let deleted = await model.deleteEmptyInventoryLocation(location)
                    isDeleting = false
                    if deleted { dismiss() }
                }
            }
        } message: {
            Text("RiftBuilder will refresh CardNexus and proceed only if the location is still empty. Deleting it also removes its local type and deck link. This cannot be undone.")
        }
    }
}

private struct ImportDeckFromLocationView: View {
    let location: LocationPolicy
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deckName: String
    @State private var isImporting = false

    init(location: LocationPolicy, model: AppModel) {
        self.location = location
        self.model = model
        _deckName = State(initialValue: location.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Deck from Location").font(.title2.weight(.semibold))
                Text(location.displayName).foregroundStyle(.secondary)
            }
            TextField("Deck name", text: $deckName)
                .textFieldStyle(.roundedBorder)
            Text("RiftBuilder infers zones from the scanned cards. A complete legal deck is imported as assembled; an incomplete but legally extendable subset is imported as pending. Structurally illegal contents are rejected without saving or linking anything.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isImporting ? "Importing…" : "Import and Link") {
                    isImporting = true
                    Task {
                        if await model.importDeck(from: location, named: deckName) { dismiss() }
                        isImporting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting || deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
