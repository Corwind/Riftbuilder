import AppKit
import SwiftUI

struct LocationColorSwatch: View {
    let value: String?
    var size: CGFloat = 14

    var body: some View {
        Circle()
            .fill(Color(cardNexusLocationColor: value) ?? .secondary.opacity(0.35))
            .frame(width: size, height: size)
            .overlay { Circle().stroke(.primary.opacity(0.18), lineWidth: 1) }
            .accessibilityLabel(value.map { "Location color \($0)" } ?? "No location color")
    }
}

extension Color {
    init?(cardNexusLocationColor value: String?) {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else { return nil }
        let namedColors: [String: Color] = [
            "black": .black,
            "blue": .blue,
            "brown": .brown,
            "cyan": .cyan,
            "gray": .gray,
            "green": .green,
            "indigo": .indigo,
            "mint": .mint,
            "orange": .orange,
            "pink": .pink,
            "purple": .purple,
            "red": .red,
            "teal": .teal,
            "white": .white,
            "yellow": .yellow,
        ]
        if let named = namedColors[rawValue.lowercased()] {
            self = named
            return
        }

        let hex = rawValue.hasPrefix("#") ? String(rawValue.dropFirst()) : rawValue
        let expanded: String
        if hex.count == 3 {
            expanded = hex.map { "\($0)\($0)" }.joined()
        } else {
            expanded = hex
        }
        guard expanded.count == 6 || expanded.count == 8, let number = UInt64(expanded, radix: 16) else { return nil }
        let hasAlpha = expanded.count == 8
        let red = Double((number >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = Double((number >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = Double((number >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? Double(number & 0xff) / 255 : 1
        self = Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    @MainActor
    var cardNexusLocationHex: String {
        let converted = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return String(
            format: "#%02X%02X%02X",
            Int((converted.redComponent * 255).rounded()),
            Int((converted.greenComponent * 255).rounded()),
            Int((converted.blueComponent * 255).rounded())
        )
    }
}
