import AppKit
import SwiftUI

struct ThemeTintedSurface: View {
    let colors: [Color]
    let transparency: Double
    let lightTintOpacity: Double
    let darkTintOpacity: Double
    var direction: (start: UnitPoint, end: UnitPoint) = (.topLeading, .bottomTrailing)

    @Environment(\.colorScheme) private var colorScheme

    private var effectiveTransparency: Double {
        min(max(transparency, 0), 1) * 0.72
    }

    private var tintOpacity: Double {
        colorScheme == .dark ? darkTintOpacity : lightTintOpacity
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            Color(nsColor: .windowBackgroundColor)
                .opacity(1 - effectiveTransparency)
            LinearGradient(
                colors: gradientColors.map { $0.opacity(tintOpacity) },
                startPoint: direction.start,
                endPoint: direction.end
            )
        }
    }

    private var gradientColors: [Color] {
        guard let first = colors.first else { return [.accentColor, .accentColor] }
        return colors.count == 1 ? [first, first] : colors
    }
}
