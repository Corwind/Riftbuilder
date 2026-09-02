import RiftBuilderCore
import SwiftUI

struct AppCardDetail: Identifiable, Hashable {
    let identity: CardIdentity
    let imageURL: URL?
    let availability: CardAvailability?
    let expansionSlugs: [String]
    let rarities: [String]
    let printingCount: Int?
    let preferredPrinting: CataloguePrintingMetadata?
    let finish: String?
    let language: String?
    let locations: [AppLocationBreakdown]
    let marketListings: [CardMarketListing]

    var id: String { identity.nameSlug }

    init(inventoryCard card: AppInventoryCard) {
        identity = card.identity
        imageURL = card.imageURL
        availability = card.availability
        expansionSlugs = [card.expansion].compactMap { $0 }
        rarities = [card.rarity].compactMap { $0 }
        printingCount = nil
        preferredPrinting = nil
        finish = card.finish
        language = card.language
        locations = card.visibleLocations(filteredBy: nil)
        marketListings = card.marketListings
    }

    init(catalogueCard card: AppCatalogueCard) {
        identity = card.identity
        imageURL = card.preferredImageURL
        availability = card.availability
        expansionSlugs = card.expansionSlugs
        rarities = card.rarities
        printingCount = card.printingCount
        preferredPrinting = card.preferredPrinting
        finish = nil
        language = nil
        locations = []
        marketListings = card.marketListings
    }

    init(identity: CardIdentity, inventoryCard: AppInventoryCard?) {
        self.identity = identity
        imageURL = inventoryCard?.imageURL
        availability = inventoryCard?.availability
        expansionSlugs = [inventoryCard?.expansion].compactMap { $0 }
        rarities = [inventoryCard?.rarity].compactMap { $0 }
        printingCount = nil
        preferredPrinting = nil
        finish = inventoryCard?.finish
        language = inventoryCard?.language
        locations = inventoryCard?.visibleLocations(filteredBy: nil) ?? []
        marketListings = inventoryCard?.marketListings ?? []
    }
}

extension View {
    func cardDetailSheet(item: Binding<AppCardDetail?>) -> some View {
        inWindowModal(item: item, preferredSize: CGSize(width: 760, height: 620)) { card in
            CardDetailSheet(card: card) {
                item.wrappedValue = nil
            }
        }
    }
}

private struct CardDetailSheet: View {
    let card: AppCardDetail
    let onDismiss: () -> Void

    private var rulesText: String? {
        card.identity.attributes.firstText(for: [
            "rulesText", "rules_text", "rules", "effectText", "effect_text", "effect",
            "abilityText", "ability_text", "text",
        ])
    }

    private var flavorText: String? {
        card.identity.attributes.firstText(for: ["flavorText", "flavor_text", "flavourText", "flavour_text"])
    }

    private var extraStats: [(String, String)] {
        [
            ("Power", card.identity.attributes.firstDisplayValue(for: ["power", "attack", "strength"])),
            ("Health", card.identity.attributes.firstDisplayValue(for: ["health", "hp"])),
            ("Durability", card.identity.attributes.firstDisplayValue(for: ["durability"])),
        ].compactMap { label, value in value.map { (label, $0) } }
    }

    private var isLegend: Bool {
        card.identity.cardType?.localizedCaseInsensitiveCompare("Legend") == .orderedSame
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Card Details").font(.headline)
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            HStack(alignment: .top, spacing: 26) {
                DetailCardArtwork(url: card.imageURL, name: card.identity.displayName)
                    .frame(width: 280, height: 392)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(card.identity.displayName)
                                .font(.largeTitle.weight(.semibold))
                                .textSelection(.enabled)
                            let typeLine = [card.identity.superType, card.identity.cardType]
                                .compactMap { $0 }
                                .filter { !$0.isEmpty }
                                .uniqued()
                                .joined(separator: " · ")
                            if !typeLine.isEmpty {
                                Text(typeLine).font(.title3).foregroundStyle(.secondary)
                            }
                            if !card.identity.appVisibleDomains.isEmpty {
                                Text("Domains")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            CardDomainTags(identity: card.identity)
                        }

                        if (!isLegend && (card.identity.energyCost != nil || card.identity.mightCost != nil)) || !extraStats.isEmpty {
                            statGrid
                        }

                        if let rulesText, !rulesText.isEmpty {
                            detailSection("Rules") {
                                Text(rulesText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }

                        if let flavorText, !flavorText.isEmpty {
                            Text(flavorText)
                                .font(.callout.italic())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }

                        metadataSection
                        if !card.marketListings.isEmpty {
                            marketSection
                        }

                        if let availability = card.availability {
                            HStack(spacing: 8) {
                                QuantityBadge(title: "Total", value: availability.totalOwned)
                                QuantityBadge(title: "Free", value: availability.availableInStorage, tint: .green)
                                let used = availability.inTargetDeck + availability.inOtherDecks
                                QuantityBadge(title: "Used", value: used, tint: .orange)
                            }
                        }

                        if !card.locations.isEmpty {
                            locationSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                }
            }
            .padding(24)
        }
        .background(.background)
        .accessibilityElement(children: .contain)
    }

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading, spacing: 8) {
            if !isLegend, let energy = card.identity.energyCost { CardStat(title: "Energy Cost", value: String(energy), color: .blue) }
            if !isLegend, let might = card.identity.mightCost { CardStat(title: "Might", value: String(might), color: .orange) }
            ForEach(Array(extraStats.enumerated()), id: \.offset) { _, stat in
                CardStat(title: stat.0, value: stat.1, color: .secondary)
            }
        }
    }

    private var metadataSection: some View {
        detailSection("Printing") {
            VStack(alignment: .leading, spacing: 7) {
                metadataRow("Set", value: card.expansionSlugs.joined(separator: ", "))
                metadataRow("Rarity", value: card.rarities.joined(separator: ", "))
                metadataRow("Riot ID", value: card.identity.attributes.firstDisplayValue(for: ["riotId", "riot_id"]))
                metadataRow("Card number", value: card.preferredPrinting?.printNumber)
                metadataRow("Printing", value: card.preferredPrinting?.printingSlug)
                metadataRow("Finish", value: card.finish)
                metadataRow("Language", value: card.language?.uppercased())
                if let printingCount = card.printingCount {
                    metadataRow("Known printings", value: String(printingCount))
                }
            }
        }
    }

    private var marketSection: some View {
        detailSection("Cardmarket") {
            VStack(spacing: 0) {
                ForEach(Array(card.marketListings.enumerated()), id: \.element.id) { index, listing in
                    Link(destination: listing.url) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                let printingLabel = [listing.expansionSlug, listing.printNumber]
                                    .compactMap { $0 }
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " · ")
                                Text(printingLabel.isEmpty ? listing.printingSlug : printingLabel)
                                    .font(.body.weight(.medium))
                                if !printingLabel.isEmpty {
                                    Text(listing.printingSlug)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let priceCents = listing.priceCents {
                                    Text(Double(priceCents) / 100, format: .currency(code: listing.currency ?? "EUR"))
                                        .font(.body.monospacedDigit().weight(.semibold))
                                    if let priceSource = listing.priceSource {
                                        Text(priceSource.detailTitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("View offers")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < card.marketListings.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private var locationSection: some View {
        detailSection("Locations") {
            VStack(spacing: 0) {
                ForEach(Array(card.locations.enumerated()), id: \.element.id) { index, location in
                    HStack(spacing: 10) {
                        LocationColorSwatch(value: location.color, size: 12)
                        Image(systemName: location.kind.systemImage)
                            .frame(width: 18)
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
                    .padding(.vertical, 5)
                    if index < card.locations.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func metadataRow(_ title: String, value: String?) -> some View {
        Group {
            if let value, !value.isEmpty {
                LabeledContent(title, value: value)
            }
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension CardMarketPriceSource {
    var detailTitle: String {
        switch self {
        case .trend: "Trend price"
        case .average7Days: "7-day average"
        case .average30Days: "30-day average"
        }
    }
}

private struct DetailCardArtwork: View {
    let url: URL?
    let name: String

    var body: some View {
        CachedCardImage(url: url) { phase in
            switch phase {
            case let .success(image):
                OrientedCardArtwork(image: image, name: name)
            default:
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(.quaternary)
                    VStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                            .font(.system(size: 38))
                        Text(name).font(.headline).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.45)) }
        .accessibilityLabel("Artwork for \(name)")
    }
}

private struct CardDomainTags: View {
    let identity: CardIdentity

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(identity.appVisibleDomains, id: \.self) { domain in
                CardTag(title: domain, color: domainColor(domain))
            }
            if identity.cardType?.localizedCaseInsensitiveContains("rune") == true || identity.tags.contains(where: { $0.localizedCaseInsensitiveCompare("rune") == .orderedSame }) {
                CardTag(title: "Rune", color: .indigo, systemImage: "diamond.fill")
            }
            ForEach(identity.tags.filter { $0.localizedCaseInsensitiveCompare("rune") != .orderedSame }, id: \.self) { tag in
                CardTag(title: tag, color: .secondary)
            }
        }
    }

    private func domainColor(_ domain: String) -> Color {
        switch domain.lowercased() {
        case "fury": .red
        case "calm": .green
        case "chaos": .purple
        case "order": .yellow
        case "mind": .blue
        case "body": .orange
        default: .accentColor
        }
    }
}

private struct CardTag: View {
    let title: String
    let color: Color
    var systemImage: String? = nil

    var body: some View {
        Group {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.13), in: Capsule())
    }
}

private struct CardStat: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(color)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: min(maxWidth, max(0, x - spacing)), height: y + rowHeight), points)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func firstText(for keys: [String]) -> String? {
        for key in keys {
            guard let value = self[key] else { continue }
            switch value {
            case let .string(text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                return text
            case let .array(values):
                let lines = values.compactMap { value -> String? in
                    if case let .string(text) = value { return text }
                    return nil
                }
                if !lines.isEmpty { return lines.joined(separator: "\n") }
            default: continue
            }
        }
        return nil
    }

    func firstDisplayValue(for keys: [String]) -> String? {
        for key in keys {
            guard let value = self[key] else { continue }
            switch value {
            case let .string(text): return text
            case let .number(number): return number.rounded() == number ? String(Int(number)) : String(number)
            case let .bool(flag): return flag ? "Yes" : "No"
            default: continue
            }
        }
        return nil
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
