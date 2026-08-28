import RiftBuilderCore
import SwiftUI

struct CatalogueCardPickerView: View {
    @Bindable var model: AppModel
    let onDismiss: () -> Void
    @State private var presentedCard: AppCardDetail?

    private var eligibleCards: [AppCatalogueCard] {
        model.catalogue.filter { card in
            DeckCardEligibility.allows(
                card.identity,
                in: model.pickerZone,
                legend: model.selectedLegendIdentity
            )
        }
    }

    private var cards: [AppCatalogueCard] {
        let query = model.pickerSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return eligibleCards }
        return eligibleCards.filter { card in
            [card.identity.appSearchText, card.expansionSlugs.joined(separator: " "), card.rarities.joined(separator: " ")]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var filterDescription: String {
        switch model.pickerZone {
        case .legend:
            return "Showing Legends only, including cards you do not own yet."
        case .chosenChampion:
            if let legend = model.selectedLegendIdentity {
                return "Showing Champions that share a tag with \(legend.displayName)."
            }
            return "Showing all Champions. Choose a Legend first to narrow them by tag."
        case .battlefield:
            return "Showing Battlefields only, including cards you do not own yet."
        case .rune:
            if let legend = model.selectedLegendIdentity {
                let domains = model.selectedLegendDomains.map { $0.capitalized }.joined(separator: " • ")
                guard !domains.isEmpty else {
                    return "\(legend.displayName) has no Rune domains in the catalogue."
                }
                return "Showing \(domains) Runes allowed by \(legend.displayName)."
            }
            return "Showing all Runes. Choose a Legend first to narrow them by domain."
        case .main, .sideboard:
            return "Showing playable cards only; Legends, Runes, and Battlefields are excluded."
        }
    }

    private var zoneMaximum: Int? {
        DeckZoneCapacity.maximumTotalQuantity(for: model.pickerZone)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a Card").font(.title2.weight(.semibold))
                    Text(filterDescription)
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Zone", selection: $model.pickerZone) {
                    ForEach(DeckZone.allCases.sorted { $0.appSortOrder < $1.appSortOrder }, id: \.self) { zone in Text(zone.appTitle).tag(zone) }
                }
                .frame(width: 175)
                if let zoneMaximum {
                    let quantity = model.deckZoneQuantity(model.pickerZone)
                    StatusPill(
                        title: "\(quantity) / \(zoneMaximum)",
                        systemImage: quantity >= zoneMaximum ? "checkmark.circle.fill" : "rectangle.stack",
                        tint: quantity >= zoneMaximum ? .orange : .secondary
                    )
                }
                Button("Done") { onDismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                if model.pickerSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label("No Eligible Cards", systemImage: "rectangle.stack.badge.minus")
                    } description: {
                        Text(filterDescription)
                    }
                } else {
                    ContentUnavailableView.search(text: model.pickerSearch)
                }
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
                            .disabled(!model.canAddCard(card, to: model.pickerZone))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

}
