import SwiftUI

struct CatalogueView: View {
    @Bindable var model: AppModel
    @State private var search = ""
    @State private var presentation: InventoryPresentation = .grid
    @State private var presentedCard: AppCardDetail?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    private var filteredCards: [AppCatalogueCard] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.catalogue }
        return model.catalogue.filter { card in
            let searchableText = [
                card.identity.appSearchText,
                card.expansionSlugs.joined(separator: " "),
                card.rarities.joined(separator: " "),
            ].joined(separator: " ")
            return searchableText.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            switch model.catalogueLoadState {
            case .idle, .loading:
                if model.catalogue.isEmpty { LoadingStateView(message: "Loading the Riftbound catalogue…") } else { catalogueContent }
            case let .failed(message):
                if model.catalogue.isEmpty {
                    FailureStateView(title: "Catalogue unavailable", message: message) { Task { await model.loadCatalogue(force: true) } }
                } else {
                    catalogueContent
                }
            case .loaded:
                filteredCards.isEmpty ? AnyView(ContentUnavailableView.search(text: search)) : AnyView(catalogueContent)
            }
        }
        .navigationTitle("Catalogue")
        .searchable(text: $search, placement: .toolbar, prompt: "Search every Riftbound card")
        .task { await model.loadCatalogue() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                CollectionPresentationPicker(selection: $presentation)
            }
        }
        .cardDetailSheet(item: $presentedCard)
    }

    @ViewBuilder
    private var catalogueContent: some View {
        if presentation == .table {
            Table(filteredCards) {
                TableColumn("Card") { card in
                    HStack(spacing: 10) {
                        CardArtwork(card: card.inventoryCard, width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.identity.displayName).fontWeight(.medium)
                            Text([card.identity.cardType, card.preferredPrinting?.expansionSlug].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { presentedCard = AppCardDetail(catalogueCard: card) }
                }
                TableColumn("Printings") { card in Text(card.printingCount, format: .number).monospacedDigit() }.width(65)
                TableColumn("Owned") { card in Text(card.availability.totalOwned, format: .number).monospacedDigit() }.width(55)
                TableColumn("Available") { card in
                    Text(card.availability.availableInStorage, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(card.availability.availableInStorage > 0 ? .green : .secondary)
                }
                .width(75)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredCards) { card in
                        ArtworkFirstGridCard(
                            name: card.identity.displayName,
                            imageURL: card.preferredImageURL,
                            domains: card.identity.appVisibleDomains,
                            isRune: card.identity.appIsRune,
                            openCard: { presentedCard = AppCardDetail(catalogueCard: card) }
                        ) {
                            VStack(alignment: .leading, spacing: 7) {
                                AdaptiveBadgeLayout(spacing: 6) {
                                    QuantityBadge(title: "Owned", value: card.availability.totalOwned)
                                    QuantityBadge(title: "Free", value: card.availability.availableInStorage, tint: .green)
                                }
                                Text("\(card.printingCount) printing\(card.printingCount == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } controls: {
                            EmptyView()
                        }
                    }
                }
                .padding()
            }
        }
    }

}
