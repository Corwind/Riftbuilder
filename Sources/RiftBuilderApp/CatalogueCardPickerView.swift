import RiftBuilderCore
import SwiftUI

struct CatalogueCardPickerView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var presentedCard: AppCardDetail?

    private var cards: [AppCatalogueCard] {
        let query = model.pickerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.catalogue }
        return model.catalogue.filter { card in
            [card.identity.appSearchText, card.expansionSlugs.joined(separator: " "), card.rarities.joined(separator: " ")]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a Card").font(.title2.weight(.semibold))
                    Text("The full catalogue is available, including cards you do not own yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Zone", selection: $model.pickerZone) {
                    ForEach(DeckZone.allCases.sorted { $0.appSortOrder < $1.appSortOrder }, id: \.self) { zone in Text(zone.appTitle).tag(zone) }
                }
                .frame(width: 175)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            content
        }
        .searchable(text: $model.pickerSearch, prompt: "Search the card catalogue")
        .task { await model.loadCatalogue() }
        .cardDetailSheet(item: $presentedCard)
    }

    @ViewBuilder
    private var content: some View {
        switch model.catalogueLoadState {
        case .idle where cards.isEmpty, .loading where cards.isEmpty:
            LoadingStateView(message: "Loading catalogue…")
        case let .failed(message) where cards.isEmpty:
            FailureStateView(title: "Catalogue unavailable", message: message) { Task { await model.loadCatalogue(force: true) } }
        default:
            if cards.isEmpty {
                ContentUnavailableView.search(text: model.pickerSearch)
            } else {
                List(cards) { catalogueCard in
                    let card = catalogueCard.inventoryCard
                    HStack(spacing: 12) {
                        Button {
                            presentedCard = AppCardDetail(catalogueCard: catalogueCard)
                        } label: {
                            HStack(spacing: 12) {
                                CardArtwork(card: card, width: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(card.identity.displayName).fontWeight(.medium)
                                    Text([card.identity.cardType, card.identity.appVisibleDomains.joined(separator: " • ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
            }
        }
    }

}
