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
                            presentedCard = AppCardDetail(inventoryCard: card)
                        }
                    } else {
                        ScrollView {
                            LazyVGrid(columns: gridColumns, spacing: 14) {
                                ForEach(model.filteredInventory) { card in
                                    InventoryGridCard(card: card) {
                                        presentedCard = AppCardDetail(inventoryCard: card)
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

            TableColumn("Total") { card in
                Text(card.availability.totalOwned, format: .number).monospacedDigit()
            }
            .width(55)

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
        .accessibilityLabel("Inventory cards")
    }
}

private struct InventoryGridCard: View {
    let card: AppInventoryCard
    let openCard: () -> Void

    var body: some View {
        ArtworkFirstGridCard(
            name: card.identity.displayName,
            imageURL: card.imageURL,
            domains: card.identity.appVisibleDomains,
            isRune: card.identity.appIsRune,
            openCard: openCard
        ) {
            AdaptiveBadgeLayout(spacing: 6) {
                QuantityBadge(title: "Owned", value: card.availability.totalOwned)
                QuantityBadge(title: "Free", value: card.availability.availableInStorage, tint: .green)
            }
        } controls: {
            EmptyView()
        }
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
