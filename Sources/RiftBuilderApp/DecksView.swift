import RiftBuilderCore
import SwiftUI

private enum DeckMainOrganization: String, CaseIterable, Identifiable {
    case alphabetical
    case cardType

    var id: Self { self }
    var title: String { self == .alphabetical ? "Alphabetical" : "By Card Type" }
}

private struct DeckCardTypeGroup: Identifiable {
    let title: String
    let entries: [DeckEntry]
    var id: String { title }
}

struct DecksView: View {
    @Bindable var model: AppModel
    @Bindable var deckTransfer: DeckTransferModel
    @Bindable var physicalAssembly: PhysicalAssemblyModel
    @State private var presentation: InventoryPresentation = .grid
    @State private var search = ""
    @Environment(AppTheme.self) private var theme

    var body: some View {
        Group {
            switch model.deckLoadState {
            case .idle where model.decks.isEmpty, .loading where model.decks.isEmpty:
                LoadingStateView(message: "Loading decks…")
            case let .failed(message) where model.decks.isEmpty:
                FailureStateView(title: "Decks unavailable", message: message) {
                    Task { await model.loadDecks() }
                }
            default:
                if model.decks.isEmpty {
                    ContentUnavailableView {
                        Label("No Decks", systemImage: "rectangle.stack.badge.plus")
                    } description: {
                        Text("Create a deck to start building from your collection.")
                    } actions: {
                        Button("New Deck") { model.requestNewDeckNaming() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        deckLibrary
                            .frame(minWidth: 210, idealWidth: 245, maxWidth: 300)
                        DeckEditorView(model: model, deckTransfer: deckTransfer, physicalAssembly: physicalAssembly, presentation: presentation, search: search)
                            .frame(minWidth: 610)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Decks")
        .searchable(text: $search, placement: .toolbar, prompt: "Search cards in this deck")
        .toolbar {
            ToolbarItem(placement: .principal) {
                CollectionPresentationPicker(selection: $presentation)
                    .disabled(model.selectedDeckSnapshot == nil)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    model.requestNewDeckNaming()
                } label: {
                    Label("New Deck", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
        .sheet(isPresented: $model.isCardPickerPresented) {
            CatalogueCardPickerView(model: model)
                .frame(minWidth: 620, minHeight: 520)
        }
    }

    private var deckLibrary: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.decks) { deck in
                    deckLibraryRow(deck)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.separator.opacity(0.35))
                .frame(width: 1)
        }
        .onChange(of: model.selectedDeckID) { _, _ in
            Task { await model.loadSelectedDeck() }
        }
    }

    private func deckLibraryRow(_ deck: Deck) -> some View {
        let isSelected = model.selectedDeckID == deck.id

        return Button {
            model.selectedDeckID = deck.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(deck.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if model.validatedLegalDeckIDs.contains(deck.id) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Validated legal deck")
                            .help("Validated legal deck")
                    }
                }
                if let domains = model.deckDomains[deck.id], !domains.isEmpty {
                    GridCardDomainTags(domains: domains, isRune: false)
                }
                Text(deck.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(12)
        .background {
            ThemedCardSurface(
                cornerRadius: 14,
                tintStrength: isSelected ? 0.20 : 0.055,
                shadowStrength: isSelected ? 0.13 : 0.07
            )
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.gradient, lineWidth: 1.5)
                    .opacity(0.65)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DeckEditorView: View {
    @Bindable var model: AppModel
    @Bindable var deckTransfer: DeckTransferModel
    @Bindable var physicalAssembly: PhysicalAssemblyModel
    let presentation: InventoryPresentation
    let search: String
    @State private var mainOrganization: DeckMainOrganization = .alphabetical
    @State private var showingDeleteConfirmation = false
    @State private var showingDefinitionOnlyConfirmation = false
    @State private var presentedCard: AppCardDetail?

    private var snapshot: DeckSnapshot? { model.selectedDeckSnapshot }

    var body: some View {
        if let snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    deckHeader(snapshot.deck)
                    deckMetrics(snapshot)
                    validationPanel
                    HStack(alignment: .top, spacing: 18) {
                        zoneSection(.legend, snapshot: snapshot)
                            .frame(maxWidth: .infinity, alignment: .top)
                        zoneSection(.chosenChampion, snapshot: snapshot)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    ForEach(remainingDeckZones, id: \.self) { zone in
                        zoneSection(zone, snapshot: snapshot)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmationDialog("Delete \(snapshot.deck.name)?", isPresented: $showingDeleteConfirmation) {
                if model.selectedDeckLocation != nil {
                    Button(model.selectedDeckPhysicalCardCount > 0 ? "Disassemble and Delete…" : "Verify Location and Delete…") {
                        Task {
                            await physicalAssembly.beginDisassembly(
                                deckID: snapshot.deck.id,
                                deletingDefinitionAfterSuccess: true,
                                appModel: model
                            )
                        }
                    }
                    Button("Delete Definition Only…", role: .destructive) {
                        showingDefinitionOnlyConfirmation = true
                    }
                } else {
                    Button("Delete Deck", role: .destructive) { Task { await model.deleteSelectedDeck() } }
                }
            } message: {
                if let location = model.selectedDeckLocation {
                    if model.selectedDeckPhysicalCardCount > 0 {
                        Text("\(model.selectedDeckPhysicalCardCount) physical cards are currently cached in \(location.displayName). RiftBuilder will refresh CardNexus, then let you review where they will be returned before deleting the deck definition.")
                    } else {
                        Text("RiftBuilder will refresh CardNexus and verify that \(location.displayName) is empty before deleting the deck definition.")
                    }
                } else {
                    Text("This removes the local deck definition. It has no linked CardNexus location.")
                }
            }
            .alert("Delete Definition Only?", isPresented: $showingDefinitionOnlyConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Definition Only", role: .destructive) { Task { await model.deleteSelectedDeck() } }
            } message: {
                Text("Cards will remain in the CardNexus deck location, but RiftBuilder will remove the location link and its remembered return locations. This cannot be undone automatically.")
            }
            .cardDetailSheet(item: $presentedCard)
        } else if model.selectedDeckID != nil {
            LoadingStateView(message: "Loading deck…")
        } else {
            ContentUnavailableView {
                Label("Select a Deck", systemImage: "rectangle.stack")
            } description: {
                Text("Choose a deck from the library, or create a new one.")
            } actions: {
                Button("New Deck") { model.requestNewDeckNaming() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var remainingDeckZones: [DeckZone] {
        DeckZone.allCases
            .filter { $0 != .legend && $0 != .chosenChampion }
            .sorted { $0.appSortOrder < $1.appSortOrder }
    }

    private func deckHeader(_ deck: Deck) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(deck.name)
                .font(.largeTitle.weight(.semibold))
                .textSelection(.enabled)
            Button { model.requestRenameSelectedDeck() } label: {
                Image(systemName: "pencil")
            }
            .help("Rename deck")
            Spacer()
            Menu {
                Button {
                    Task { await deckTransfer.copyDeckList(deckID: deck.id, appModel: model) }
                } label: {
                    Label("Copy RiftDeck List", systemImage: "doc.on.doc")
                }
                Button {
                    Task { await deckTransfer.prepareRiftDeckTextExport(deckID: deck.id, appModel: model) }
                } label: {
                    Label("Export RiftDeck Text…", systemImage: "doc.badge.arrow.up")
                }
                Divider()
                Button {
                    Task { await deckTransfer.prepareExport(deckID: deck.id, appModel: model) }
                } label: {
                    Label("Export RiftBuilder Deck File…", systemImage: "archivebox")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .help("Export deck")
            .disabled(deckTransfer.isWorking)
            Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                Image(systemName: "trash")
            }
            .help("Delete deck")
        }
    }

    private func deckMetrics(_ snapshot: DeckSnapshot) -> some View {
        let main = count(.main, in: snapshot) + count(.chosenChampion, in: snapshot)
        let runes = count(.rune, in: snapshot)
        let battlefields = Set(snapshot.entries.filter { $0.zone == .battlefield }.map(\.nameSlug)).count
        let available = buildableQuantity(in: snapshot)
        let required = snapshot.entries.reduce(0) { $0 + $1.quantity }
        return HStack(spacing: 10) {
            MetricCard(title: "Main deck", value: "\(main) / 40", systemImage: "rectangle.stack")
            MetricCard(title: "Runes", value: "\(runes) / 12", systemImage: "diamond")
            MetricCard(title: "Battlefields", value: "\(battlefields) / 3", systemImage: "map")
            MetricCard(title: "Buildable", value: "\(available) / \(required)", systemImage: "checkmark.circle")
        }
    }

    private var validationPanel: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.validationIssues) { issue in ValidationIssueRow(issue: issue) }
            }
            .padding(.top, 8)
        } label: {
            if model.validationIssues.isEmpty {
                StatusPill(title: "Deck is legal", systemImage: "checkmark.seal.fill", tint: .green)
            } else {
                StatusPill(title: "\(model.validationIssues.count) validation issues", systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
        .padding(14)
        .background { ThemedCardSurface(cornerRadius: 12, tintStrength: 0.055, shadowStrength: 0.07) }
    }

    private func zoneSection(_ zone: DeckZone, snapshot: DeckSnapshot) -> some View {
        let allEntries = snapshot.entries.filter { $0.zone == zone }.sorted {
            (snapshot.identities[$0.nameSlug]?.displayName ?? $0.nameSlug) < (snapshot.identities[$1.nameSlug]?.displayName ?? $1.nameSlug)
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = query.isEmpty ? allEntries : allEntries.filter { entry in
            let identity = snapshot.identities[entry.nameSlug] ?? model.catalogueByNameSlug[entry.nameSlug]?.identity
            return (identity?.appSearchText ?? entry.nameSlug).localizedCaseInsensitiveContains(query)
        }

        return GroupBox {
            if entries.isEmpty {
                HStack {
                    Text(query.isEmpty ? "No cards in this zone" : "No matching cards in this zone")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 10)
            } else if zone == .main, mainOrganization == .cardType {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(cardTypeGroups(for: entries, snapshot: snapshot)) { group in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 7) {
                                Text(group.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(group.entries.reduce(0) { $0 + $1.quantity }, format: .number)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            entriesCollection(group.entries, snapshot: snapshot)
                        }
                    }
                }
                .padding(.vertical, 6)
            } else {
                entriesCollection(entries, snapshot: snapshot)
            }
        } label: {
            HStack {
                Text(zone.appTitle)
                Text(entries.reduce(0) { $0 + $1.quantity }, format: .number)
                    .foregroundStyle(.secondary)
                Spacer()
                if zone == .main {
                    Picker("Organization", selection: $mainOrganization) {
                        ForEach(DeckMainOrganization.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 135)
                    .help("Organize Main Deck cards")
                }
                Button {
                    model.pickerZone = zone
                    model.isCardPickerPresented = true
                } label: {
                    Label("Add Card", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .groupBoxStyle(ThemedGroupBoxStyle())
    }


    @ViewBuilder
    private func entriesCollection(_ entries: [DeckEntry], snapshot: DeckSnapshot) -> some View {
        if presentation == .grid {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 270, maximum: 390), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(entries) { entry in
                    let identity = snapshot.identities[entry.nameSlug]
                    let inventory = model.inventory.first { card in card.id == entry.nameSlug }
                    let catalogue = model.catalogueByNameSlug[entry.nameSlug]
                    DeckEntryGridCard(
                        entry: entry,
                        identity: identity,
                        inventory: inventory,
                        catalogueCard: catalogue,
                        isAlwaysAvailable: model.deckInventoryAvailability.isAlwaysAvailable(entry.zone),
                        changeQuantity: { delta in
                            Task { await model.changeQuantity(entry, delta: delta) }
                        },
                        openCard: { presentCard(identity: identity, inventory: inventory, catalogue: catalogue) }
                    )
                }
            }
            .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    let identity = snapshot.identities[entry.nameSlug]
                    let inventory = model.inventory.first { card in card.id == entry.nameSlug }
                    let catalogue = model.catalogueByNameSlug[entry.nameSlug]
                    DeckEntryRow(
                        entry: entry,
                        identity: identity,
                        inventory: inventory,
                        isAlwaysAvailable: model.deckInventoryAvailability.isAlwaysAvailable(entry.zone),
                        changeQuantity: { delta in
                            Task { await model.changeQuantity(entry, delta: delta) }
                        },
                        openCard: { presentCard(identity: identity, inventory: inventory, catalogue: catalogue) }
                    )
                    Divider()
                }
            }
        }
    }

    private func cardTypeGroups(for entries: [DeckEntry], snapshot: DeckSnapshot) -> [DeckCardTypeGroup] {
        let grouped = Dictionary(grouping: entries) { entry in
            let identity = snapshot.identities[entry.nameSlug] ?? model.catalogueByNameSlug[entry.nameSlug]?.identity
            return cardTypeGroupTitle(identity?.cardType)
        }
        return grouped.map { DeckCardTypeGroup(title: $0.key, entries: $0.value) }.sorted { left, right in
            let leftRank = cardTypeGroupRank(left.title)
            let rightRank = cardTypeGroupRank(right.title)
            return leftRank == rightRank ? left.title < right.title : leftRank < rightRank
        }
    }

    private func cardTypeGroupTitle(_ cardType: String?) -> String {
        let value = cardType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = value.lowercased()
        if normalized.contains("unit") { return "Units" }
        if normalized.contains("spell") { return "Spells" }
        if normalized.contains("gear") { return "Gear" }
        return value.isEmpty ? "Other" : value
    }

    private func cardTypeGroupRank(_ title: String) -> Int {
        switch title {
        case "Units": 0
        case "Spells": 1
        case "Gear": 2
        default: 3
        }
    }

    private func buildableQuantity(in snapshot: DeckSnapshot) -> Int {
        var physicalRequiredBySlug: [String: Int] = [:]
        var buildable = 0
        for entry in snapshot.entries {
            if model.deckInventoryAvailability.isAlwaysAvailable(entry.zone) {
                buildable += entry.quantity
            } else {
                physicalRequiredBySlug[entry.nameSlug, default: 0] += entry.quantity
            }
        }
        for (nameSlug, required) in physicalRequiredBySlug {
            let available = model.inventory.first(where: { $0.id == nameSlug })?.availability.usableForTargetDeck ?? 0
            buildable += min(required, available)
        }
        return buildable
    }

    private func count(_ zone: DeckZone, in snapshot: DeckSnapshot) -> Int {
        snapshot.entries.filter { $0.zone == zone }.reduce(0) { $0 + $1.quantity }
    }

    private func presentCard(identity: CardIdentity?, inventory: AppInventoryCard?, catalogue: AppCatalogueCard?) {
        if let catalogue {
            presentedCard = AppCardDetail(catalogueCard: catalogue)
        } else if let identity {
            presentedCard = AppCardDetail(identity: identity, inventoryCard: inventory)
        }
    }
}

struct DeckNamingSheet: View {
    private enum CreationSource: String, CaseIterable, Identifiable {
        case empty
        case location

        var id: String { rawValue }
        var title: String {
            switch self {
            case .empty: "Empty Deck"
            case .location: "From Location"
            }
        }
    }

    let request: DeckNamingRequest
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var creationSource: CreationSource = .empty
    @State private var selectedLocationKey: String?
    @State private var isWorking = false
    @FocusState private var nameFocused: Bool

    init(request: DeckNamingRequest, model: AppModel) {
        self.request = request
        self.model = model
        _name = State(initialValue: request.initialName)
        _selectedLocationKey = State(initialValue: model.importableDeckLocations.first?.normalizedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(request.title)
                    .font(.title2.weight(.semibold))
                Text(request.purpose == .create ? "Create an empty definition or reconstruct one from a CardNexus Deck location." : "Choose a new name for this deck.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if request.purpose == .create {
                Picker("Creation source", selection: $creationSource) {
                    ForEach(CreationSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if creationSource == .location {
                    if model.importableDeckLocations.isEmpty {
                        ContentUnavailableView {
                            Label("No Importable Deck Locations", systemImage: "rectangle.stack.badge.questionmark")
                        } description: {
                            Text("Classify a CardNexus location as Deck and leave it unlinked before importing it.")
                        }
                        .frame(minHeight: 130)
                    } else {
                        Picker("Deck location", selection: $selectedLocationKey) {
                            ForEach(model.importableDeckLocations) { location in
                                Text(location.displayName).tag(Optional(location.normalizedName))
                            }
                        }
                        Text("Cards are assigned to deck zones and checked against constructed rules. Complete decks are assembled; incomplete but legally extendable subsets are created as pending decks.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            TextField("Deck name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { commit() }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.deckNamingRequest = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(confirmationTitle) { commit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || trimmedName.isEmpty || (request.purpose == .create && creationSource == .location && selectedLocation == nil))
            }
        }
        .padding(24)
        .frame(width: 520)
        .background { ThemedCardSurface(cornerRadius: 18, tintStrength: 0.075, shadowStrength: 0.12) }
        .padding(18)
        .onAppear {
            if request.purpose == .create, selectedLocationKey == nil {
                selectedLocationKey = model.importableDeckLocations.first?.normalizedName
            }
            nameFocused = true
        }
        .onChange(of: creationSource) { _, source in
            guard source == .location, let location = selectedLocation else { return }
            if trimmedName.isEmpty { name = location.displayName }
        }
        .onChange(of: selectedLocationKey) { oldKey, _ in
            guard creationSource == .location, let location = selectedLocation else { return }
            let oldLocationName = model.importableDeckLocations.first { $0.normalizedName == oldKey }?.displayName
            if trimmedName.isEmpty || name == oldLocationName { name = location.displayName }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedLocation: LocationPolicy? {
        guard let selectedLocationKey else { return nil }
        return model.importableDeckLocations.first { $0.normalizedName == selectedLocationKey }
    }

    private var confirmationTitle: String {
        if request.purpose == .create, creationSource == .location { return isWorking ? "Importing…" : "Import and Link" }
        return request.confirmationTitle
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        let submittedName = trimmedName
        isWorking = true
        Task {
            if request.purpose == .create, creationSource == .location {
                if let location = selectedLocation, await model.importDeck(from: location, named: submittedName) {
                    model.deckNamingRequest = nil
                    dismiss()
                }
            } else {
                await model.commitDeckName(submittedName, request: request)
                dismiss()
            }
            isWorking = false
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background { ThemedCardSurface(cornerRadius: 10, tintStrength: 0.055, shadowStrength: 0.06) }
    }
}

private struct DeckEntryRow: View {
    let entry: DeckEntry
    let identity: CardIdentity?
    let inventory: AppInventoryCard?
    let isAlwaysAvailable: Bool
    let changeQuantity: (Int) -> Void
    let openCard: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Stepper(value: Binding(
                get: { entry.quantity },
                set: { newValue in changeQuantity(newValue - entry.quantity) }
            ), in: 0...99) {
                Text(entry.quantity, format: .number)
                    .font(.headline.monospacedDigit())
                    .frame(width: 25, alignment: .trailing)
            }
            .fixedSize()
            Button(action: openCard) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(identity?.displayName ?? entry.nameSlug).fontWeight(.medium)
                    Text([identity?.cardType, identity?.appVisibleDomains.joined(separator: " • ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show details for \(identity?.displayName ?? entry.nameSlug)")
            Spacer()
            if isAlwaysAvailable {
                QuantityBadge(title: "Always available", value: entry.quantity, tint: .green)
            } else if let availability = inventory?.availability {
                QuantityBadge(title: "Storage", value: availability.availableInStorage, tint: .green)
                QuantityBadge(title: "This deck", value: availability.inTargetDeck)
                if availability.inOtherDecks > 0 {
                    QuantityBadge(title: "Other decks", value: availability.inOtherDecks, tint: .orange)
                }
                let missing = max(0, entry.quantity - availability.usableForTargetDeck)
                if missing > 0 { QuantityBadge(title: "Missing", value: missing, tint: .red) }
            } else {
                QuantityBadge(title: "Missing", value: entry.quantity, tint: .red)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct CardPickerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var cards: [AppInventoryCard] {
        guard !model.pickerSearch.isEmpty else { return model.inventory }
        return model.inventory.filter { $0.identity.displayName.localizedCaseInsensitiveContains(model.pickerSearch) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a Card").font(.title2.weight(.semibold))
                    Text("Missing cards remain selectable so you can plan future upgrades.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Zone", selection: $model.pickerZone) {
                    ForEach(DeckZone.allCases.sorted { $0.appSortOrder < $1.appSortOrder }, id: \.self) { zone in Text(zone.appTitle).tag(zone) }
                }
                .frame(width: 175)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            List(cards) { card in
                HStack(spacing: 12) {
                    CardArtwork(card: card, width: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.identity.displayName).fontWeight(.medium)
                        Text([card.identity.cardType, card.identity.appVisibleDomains.joined(separator: " • ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    QuantityBadge(title: "Owned", value: card.availability.totalOwned)
                    if model.pickerZone == .rune {
                        StatusPill(title: "Always available", systemImage: "infinity", tint: .green)
                    } else {
                        QuantityBadge(title: "Free", value: card.availability.availableInStorage, tint: card.availability.availableInStorage > 0 ? .green : .secondary)
                    }
                    Button("Add") { Task { await model.addCard(card, zone: model.pickerZone) } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
            .searchable(text: $model.pickerSearch, prompt: "Search the card catalogue")
        }
    }
}
