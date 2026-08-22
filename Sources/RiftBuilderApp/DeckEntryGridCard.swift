import RiftBuilderCore
import SwiftUI

struct DeckEntryGridCard: View {
    let entry: DeckEntry
    let identity: CardIdentity?
    let inventory: AppInventoryCard?
    let catalogueCard: AppCatalogueCard?
    let isAlwaysAvailable: Bool
    let changeQuantity: (Int) -> Void
    let openCard: () -> Void

    private var displayName: String { identity?.displayName ?? entry.nameSlug }
    private var availability: CardAvailability? { inventory?.availability ?? catalogueCard?.availability }
    private var imageURL: URL? { catalogueCard?.preferredImageURL ?? inventory?.imageURL }

    var body: some View {
        ArtworkFirstGridCard(
            name: displayName,
            imageURL: imageURL,
            domains: identity?.appVisibleDomains ?? [],
            isRune: entry.zone == .rune,
            openCard: openCard
        ) {
            availabilityContent
        } controls: {
            VStack(spacing: 9) {
                Divider()
                quantityControls
            }
        }
    }

    @ViewBuilder
    private var availabilityContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            AdaptiveBadgeLayout(spacing: 6) {
                QuantityBadge(title: "Owned", value: availability?.totalOwned ?? 0)
                QuantityBadge(title: "Free", value: availability?.availableInStorage ?? 0, tint: .green)
                if isAlwaysAvailable {
                    StatusPill(title: "Always available", systemImage: "infinity", tint: .green)
                }
            }

            if !isAlwaysAvailable {
                AdaptiveBadgeLayout(spacing: 6) {
                    if let availability, availability.inTargetDeck > 0 {
                        QuantityBadge(title: "This deck", value: availability.inTargetDeck)
                    }
                    if let availability, availability.inOtherDecks > 0 {
                        QuantityBadge(title: "Other decks", value: availability.inOtherDecks, tint: .orange)
                    }
                    let missing = max(0, entry.quantity - (availability?.usableForTargetDeck ?? 0))
                    if missing > 0 {
                        QuantityBadge(title: "Missing", value: missing, tint: .red)
                    }
                }
            }
        }
    }

    private var quantityControls: some View {
        HStack(spacing: 8) {
            Button { changeQuantity(-1) } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)
            .disabled(entry.quantity <= 1)
            .accessibilityLabel("Decrease \(displayName) quantity")

            Text(entry.quantity, format: .number)
                .font(.headline.monospacedDigit())
                .frame(minWidth: 24)
                .accessibilityLabel("Quantity \(entry.quantity)")

            Button { changeQuantity(1) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(entry.quantity >= 99)
            .accessibilityLabel("Increase \(displayName) quantity")

            Spacer()

            Button(role: .destructive) { changeQuantity(-entry.quantity) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(displayName) from this zone")
            .accessibilityLabel("Remove \(displayName) from this zone")
        }
        .controlSize(.small)
    }
}
