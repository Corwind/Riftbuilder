import RiftBuilderCore
import SwiftUI

struct CollectionPresentationPicker: View {
    @Binding var selection: InventoryPresentation

    var body: some View {
        Picker("Presentation", selection: $selection) {
            ForEach(InventoryPresentation.allCases) { mode in
                Image(systemName: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 76)
        .help("Switch between list and grid")
    }
}

struct QuantityBadge: View {
    let title: String
    let value: Int
    var tint: Color = .secondary
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            Text(title)
            Text(value, format: .number)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(compact ? .caption2 : .caption)
        .lineLimit(1)
        .foregroundStyle(tint)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 3 : 4)
        .background(tint.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct OrientedCardArtwork: View {
    let image: Image
    let name: String

    private var requiresPortraitRotation: Bool {
        name.localizedCaseInsensitiveCompare("Rockfall Path") == .orderedSame
    }

    var body: some View {
        GeometryReader { geometry in
            if requiresPortraitRotation {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.height, height: geometry.size.width)
                    .rotationEffect(.degrees(-90))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            } else {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}

struct CardArtwork: View {
    let card: AppInventoryCard
    var width: CGFloat = 48

    var body: some View {
        CachedCardImage(url: card.imageURL) { phase in
            switch phase {
            case let .success(image):
                OrientedCardArtwork(image: image, name: card.identity.displayName)
            default:
                ZStack {
                    RoundedRectangle(cornerRadius: width * 0.12)
                        .fill(.quaternary)
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: width, height: width * 1.4)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.12))
        .overlay {
            RoundedRectangle(cornerRadius: width * 0.12)
                .stroke(.separator.opacity(0.35))
        }
        .accessibilityHidden(true)
    }
}

struct LoadingStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailureStateView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}

struct OfflineBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            Text(message)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: retry)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.14))
        .accessibilityElement(children: .combine)
    }
}

struct ValidationIssueRow: View {
    let issue: DeckValidationIssue

    var body: some View {
        Label {
            Text(issue.message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? .red : .orange)
        }
        .font(.callout)
        .accessibilityLabel("\(issue.severity.rawValue): \(issue.message)")
    }
}

struct ThemedCardSurface: View {
    var cornerRadius: CGFloat = 13
    var tintStrength: Double = 0.08
    var shadowStrength: Double = 0.10

    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(colorScheme == .dark ? Color.black.opacity(0.10) : Color.white.opacity(0.18))
            shape.fill(theme.gradient)
                .opacity(colorScheme == .dark ? tintStrength : tintStrength * 1.25)
        }
        .overlay {
            shape.stroke(theme.gradient, lineWidth: 1)
                .opacity(colorScheme == .dark ? 0.28 : 0.22)
        }
        .overlay {
            shape.inset(by: 1)
                .stroke(.white.opacity(colorScheme == .dark ? 0.055 : 0.16), lineWidth: 1)
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? shadowStrength : shadowStrength * 0.55),
            radius: 10,
            y: 4
        )
    }
}

struct ThemedGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background {
            ThemedCardSurface(cornerRadius: 13, tintStrength: 0.055, shadowStrength: 0.07)
        }
    }
}
