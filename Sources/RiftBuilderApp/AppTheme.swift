import AppKit
import Foundation
import Observation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum AppAccentPalette: String, CaseIterable, Identifiable {
    case riftBlue
    case arcanePurple
    case ember
    case verdant
    case radiantYellow
    case crimsonRed
    case monochrome

    var id: Self { self }

    var title: String {
        switch self {
        case .riftBlue: "Rift Blue"
        case .arcanePurple: "Arcane Purple"
        case .ember: "Ember"
        case .verdant: "Verdant"
        case .radiantYellow: "Radiant Yellow"
        case .crimsonRed: "Crimson Red"
        case .monochrome: "Monochrome"
        }
    }

    var color: Color {
        switch self {
        case .riftBlue: Self.adaptive(light: (0.05, 0.32, 0.72), dark: (0.25, 0.56, 1.00))
        case .arcanePurple: Self.adaptive(light: (0.39, 0.18, 0.68), dark: (0.66, 0.42, 0.96))
        case .ember: Self.adaptive(light: (0.74, 0.22, 0.05), dark: (1.00, 0.39, 0.20))
        case .verdant: Self.adaptive(light: (0.06, 0.43, 0.23), dark: (0.22, 0.72, 0.44))
        case .radiantYellow: Self.adaptive(light: (0.65, 0.41, 0.00), dark: (1.00, 0.76, 0.14))
        case .crimsonRed: Self.adaptive(light: (0.66, 0.05, 0.10), dark: (0.96, 0.22, 0.28))
        case .monochrome: Color.primary
        }
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let components = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: components.0, green: components.1, blue: components.2, alpha: 1)
        })
    }

    var supportsCombination: Bool { self != .monochrome }
}

@MainActor
@Observable
final class AppTheme {
    private static let appearanceKey = "riftbuilder.appearance"
    private static let accentKey = "riftbuilder.accentPalette"
    private static let secondaryAccentKey = "riftbuilder.secondaryAccentPalette"
    private static let backgroundTransparencyKey = "riftbuilder.backgroundTransparency"

    var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }
    var accent: AppAccentPalette {
        didSet {
            defaults.set(accent.rawValue, forKey: Self.accentKey)
            if !accent.supportsCombination || accent == secondaryAccent { secondaryAccent = nil }
        }
    }
    var backgroundTransparency: Double {
        didSet {
            let clamped = min(max(backgroundTransparency, 0), 1)
            if backgroundTransparency != clamped {
                backgroundTransparency = clamped
            } else {
                defaults.set(backgroundTransparency, forKey: Self.backgroundTransparencyKey)
            }
        }
    }
    var secondaryAccent: AppAccentPalette? {
        didSet {
            if let secondaryAccent {
                defaults.set(secondaryAccent.rawValue, forKey: Self.secondaryAccentKey)
            } else {
                defaults.removeObject(forKey: Self.secondaryAccentKey)
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        accent = AppAccentPalette(rawValue: defaults.string(forKey: Self.accentKey) ?? "") ?? .riftBlue
        backgroundTransparency = defaults.object(forKey: Self.backgroundTransparencyKey) as? Double ?? 0
        let storedSecondary = AppAccentPalette(rawValue: defaults.string(forKey: Self.secondaryAccentKey) ?? "")
        secondaryAccent = storedSecondary?.supportsCombination == true && storedSecondary != accent ? storedSecondary : nil
    }

    var colors: [Color] { [accent.color, secondaryAccent?.color].compactMap { value in value } }

    var gradient: LinearGradient {
        LinearGradient(colors: colors.count == 1 ? [accent.color, accent.color] : colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct ThemeSettingsSection: View {
    @Environment(AppTheme.self) private var theme

    var body: some View {
        @Bindable var theme = theme
        Picker("Appearance", selection: $theme.appearance) {
            ForEach(AppAppearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
        }
        .pickerStyle(.segmented)

        LabeledContent("Primary color") {
            Picker("Primary color", selection: $theme.accent) {
                ForEach(AppAccentPalette.allCases) { palette in
                    Text(palette.title).tag(palette)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }

        if theme.accent.supportsCombination {
            LabeledContent("Second color") {
                Picker("Second color", selection: $theme.secondaryAccent) {
                    Text("Single color").tag(nil as AppAccentPalette?)
                    ForEach(AppAccentPalette.allCases.filter { $0.supportsCombination && $0 != theme.accent }) { palette in
                        Text(palette.title).tag(palette as AppAccentPalette?)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            HStack(spacing: 0) {
                Rectangle().fill(theme.gradient)
            }
            .frame(height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.12)) }
            .accessibilityLabel(theme.secondaryAccent.map { "Gradient from " + theme.accent.title + " to " + $0.title } ?? theme.accent.title)
        }

        LabeledContent("Transparency") {
            HStack(spacing: 10) {
                Text(theme.backgroundTransparency <= 0.001 ? "Matte" : "Frosted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                Slider(value: $theme.backgroundTransparency, in: 0...1)
                    .frame(width: 190)
            }
        }

        Text("Choose a single color or pair any two colored palettes. Set Transparency to zero for a matte window or increase it for strongly blurred frosted glass; the maximum remains blurred so background text is not readable. Monochrome remains single-color.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
