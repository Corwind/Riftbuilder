import SwiftUI

struct ArtworkFirstGridCard<Status: View, Controls: View>: View {
    let name: String
    let imageURL: URL?
    let domains: [String]
    let isRune: Bool
    let openCard: () -> Void
    @ViewBuilder let status: () -> Status
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button(action: openCard) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)

                    GridCardArtwork(imageURL: imageURL, name: name)

                    GridCardDomainTags(domains: domains, isRune: isRune)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show details for \(name)")

            status()
                .frame(maxWidth: .infinity, alignment: .leading)

            controls()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background { ThemedCardSurface(cornerRadius: 13, tintStrength: 0.05, shadowStrength: 0.07) }
        .accessibilityElement(children: .contain)
    }
}

private struct GridCardArtwork: View {
    let imageURL: URL?
    let name: String

    var body: some View {
        CachedCardImage(url: imageURL) { phase in
            switch phase {
            case let .success(image):
                OrientedCardArtwork(image: image, name: name)
            default:
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(.quaternary)
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait")
                            .font(.system(size: 30))
                        Text("Artwork unavailable")
                            .font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .aspectRatio(5 / 7, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).stroke(.separator.opacity(0.4)) }
        .accessibilityLabel("Artwork for \(name)")
    }
}

struct GridCardDomainTags: View {
    let domains: [String]
    let isRune: Bool

    private var visibleDomains: [String] {
        domains.filter { $0.localizedCaseInsensitiveCompare("neutral") != .orderedSame }
    }

    var body: some View {
        AdaptiveBadgeLayout(spacing: 5) {
            ForEach(visibleDomains, id: \.self) { domain in
                GridCardTag(title: domain, color: domainColor(domain))
            }
            if isRune {
                GridCardTag(title: "Rune", color: .indigo, systemImage: "diamond.fill")
            }
        }
    }

    private func domainColor(_ domain: String) -> Color {
        switch domain.lowercased() {
        case "body": .orange
        case "calm": .green
        case "chaos": .purple
        case "fury": .red
        case "mind": .blue
        case "order": .yellow
        default: .accentColor
        }
    }
}

private struct GridCardTag: View {
    let title: String
    let color: Color
    var systemImage: String? = nil

    var body: some View {
        Group {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}
