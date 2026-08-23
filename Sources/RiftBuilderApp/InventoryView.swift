import RiftBuilderCore
import SwiftUI

struct InventoryView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var presentedCard: AppCardDetail?

    private let gridColumns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            if case let .failed(message, cachedDataAvailable) = model.syncState, cachedDataAvailable {
                OfflineBanner(message: message) {
                    Task { await model.synchronize() }
                }
            }
            inventoryContent
        }
        .navigationTitle("Inventory")
        .searchable(text: $model.inventorySearch, placement: .toolbar, prompt: "Names, descriptions, domains, types…")
        .searchFocused($searchFocused)
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .toolbar {
            ToolbarItem(placement: .principal) {
                CollectionPresentationPicker(selection: $model.inventoryPresentation)
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                Picker("Inventory scope", selection: $model.inventoryScope) {
                    ForEach(InventoryScope.allCases) { scope in Text(scope.title).tag(scope) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Picker("Location", selection: $model.inventoryLocationFilter) {
                    Text("All Locations").tag(nil as String?)
                    ForEach(model.visibleLocations) { location in
                        Text(location.displayName).tag(location.normalizedName as String?)
                    }
                }
                .frame(width: 170)
            }
        }
        .cardDetailSheet(item: $presentedCard)
    }

    @ViewBuilder
    private var inventoryContent: some View {
        switch model.inventoryLoadState {
        case .idle where model.inventory.isEmpty, .loading where model.inventory.isEmpty:
            LoadingStateView(message: "Loading your collection…")
        case let .failed(message) where model.inventory.isEmpty:
            FailureStateView(title: "Inventory unavailable", message: message) {
                Task { await model.loadInventory() }
            }
        default:
            if model.filteredInventory.isEmpty {
                if model.inventorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.inventoryLocationFilter != nil {
                    ContentUnavailableView("No Cards at This Location", systemImage: "shippingbox", description: Text("Choose another location or show all locations."))
                } else {
                    ContentUnavailableView.search(text: model.inventorySearch)
                }
            } else {
                Group {
                    if model.inventoryPresentation == .table {
                        InventoryTable(model: model) { card in
                            presentedCard = AppCardDetail(inventoryCard: card, locationFilter: model.inventoryLocationFilter)
                        }
                    } else {
                        ScrollView {
                            LazyVGrid(columns: gridColumns, spacing: 14) {
                                ForEach(model.filteredInventory) { card in
                                    InventoryGridCard(card: card, locationFilter: model.inventoryLocationFilter) {
                                        presentedCard = AppCardDetail(inventoryCard: card, locationFilter: model.inventoryLocationFilter)
                                    }
                                }
                            }
                            .padding()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct InventoryTable: View {
    @Bindable var model: AppModel
    let openCard: (AppInventoryCard) -> Void

    var body: some View {
        Table(model.filteredInventory) {
            TableColumn("Card") { card in
                HStack(spacing: 10) {
                    CardArtwork(card: card, width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.identity.displayName).fontWeight(.medium)
                        Text([card.identity.cardType, card.expansion].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { openCard(card) }
            }
            .width(min: 210, ideal: 280)

            TableColumn("Quantity") { card in
                Text(card.displayedInventoryQuantity(filteredBy: model.inventoryLocationFilter), format: .number)
                    .monospacedDigit()
            }
            .width(65)

            if model.inventoryLocationFilter == nil {
                TableColumn("Available") { card in
                    Text(card.availability.availableInStorage, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(card.availability.availableInStorage > 0 ? .green : .secondary)
                }
                .width(75)

                TableColumn("This deck") { card in
                    Text(card.availability.inTargetDeck, format: .number).monospacedDigit()
                }
                .width(75)

                TableColumn("Other decks") { card in
                    Text(card.availability.inOtherDecks, format: .number).monospacedDigit()
                }
                .width(80)
            }

            TableColumn("Locations") { card in
                InventoryTableLocationSummary(
                    locations: card.visibleLocations(filteredBy: model.inventoryLocationFilter)
                )
            }
            .width(min: 170, ideal: 260)
        }
        .accessibilityLabel("Inventory cards")
    }
}

private struct InventoryGridCard: View {
    let card: AppInventoryCard
    let locationFilter: String?
    let openCard: () -> Void

    private var displayedLocations: [AppLocationBreakdown] {
        card.visibleLocations(filteredBy: locationFilter)
    }

    var body: some View {
        ArtworkFirstGridCard(
            name: card.identity.displayName,
            imageURL: card.imageURL,
            domains: card.identity.appVisibleDomains,
            isRune: card.identity.appIsRune,
            openCard: openCard
        ) {
            VStack(alignment: .leading, spacing: 7) {
                if locationFilter == nil {
                    AdaptiveBadgeLayout(spacing: 6) {
                        QuantityBadge(title: "Owned", value: card.availability.totalOwned)
                        QuantityBadge(title: "Free", value: card.availability.availableInStorage, tint: .green)
                    }
                }
                InventoryGridLocationSummary(locations: displayedLocations)
            }
            .frame(height: 84, alignment: .topLeading)
        } controls: {
            EmptyView()
        }
    }
}

private struct InventoryGridLocationSummary: View {
    let locations: [AppLocationBreakdown]

    private let maximumVisibleLocations = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(locations.prefix(maximumVisibleLocations))) { location in
                InventoryCompactLocationRow(location: location)
            }
            if locations.count > maximumVisibleLocations {
                Text("+\(locations.count - maximumVisibleLocations) more location\(locations.count - maximumVisibleLocations == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if locations.isEmpty {
                Text("No visible locations")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct InventoryCompactLocationRow: View {
    let location: AppLocationBreakdown

    var body: some View {
        HStack(spacing: 5) {
            LocationColorSwatch(value: location.color, size: 8)
            Text(location.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(location.quantity, format: .number)
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(location.displayName), \(location.quantity) cards")
    }
}

private struct InventoryTableLocationSummary: View {
    let locations: [AppLocationBreakdown]

    private var summary: String {
        guard !locations.isEmpty else { return "No visible locations" }
        return locations.map { "\($0.displayName) \($0.quantity)" }.joined(separator: " · ")
    }

    var body: some View {
        Text(summary)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(summary)
    }
}

private struct InventoryDetailView: View {
    let card: AppInventoryCard?

    var body: some View {
        if let card {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        CardArtwork(card: card, width: 76)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(card.identity.displayName).font(.title2.weight(.semibold))
                            Text([card.identity.cardType, card.rarity, card.expansion].compactMap { $0 }.joined(separator: " · "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if !card.identity.appVisibleDomains.isEmpty {
                                Text(card.identity.appVisibleDomains.joined(separator: " • "))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }

                    HStack {
                        QuantityBadge(title: "Owned", value: card.availability.totalOwned)
                        QuantityBadge(title: "Available", value: card.availability.availableInStorage, tint: .green)
                        if card.availability.otherwiseUnavailable > 0 {
                            QuantityBadge(title: "Unavailable", value: card.availability.otherwiseUnavailable, tint: .orange)
                        }
                    }

                    Divider()
                    Text("Locations").font(.headline)
                    ForEach(card.locations.filter { $0.kind != .unavailable }) { location in
                        HStack(spacing: 10) {
                            Image(systemName: location.kind.systemImage)
                                .frame(width: 20)
                                .foregroundStyle(location.isAvailable ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.displayName)
                                Text(location.kind.appTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(location.quantity, format: .number)
                                .font(.body.monospacedDigit().weight(.semibold))
                        }
                        .padding(.vertical, 3)
                    }
                    if let finish = card.finish, let language = card.language {
                        Divider()
                        LabeledContent("Printing", value: [finish, language].joined(separator: " · "))
                    }
                }
                .padding(18)
            }
            .background(.background.secondary)
        } else {
            ContentUnavailableView("Select a Card", systemImage: "rectangle.stack", description: Text("Choose a card to inspect its quantities and physical locations."))
        }
    }
}
