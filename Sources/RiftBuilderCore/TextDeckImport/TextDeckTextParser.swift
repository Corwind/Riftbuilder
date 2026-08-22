import Foundation

public enum TextDeckTextParser {
    public static func parse(_ text: String) throws -> TextDeckImportDocument {
        let normalizedText = normalizedLineEndings(in: text)
        let lines = normalizedText.split(separator: "\n", omittingEmptySubsequences: false)
        var currentZone: DeckZone?
        var orderedKeys: [EntryKey] = []
        var entriesByKey: [EntryKey: TextDeckImportEntry] = [:]

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            var line = String(rawLine)
            if lineNumber == 1, line.first == "\u{feff}" {
                line.removeFirst()
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasSuffix(":") {
                let heading = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                guard let zone = zone(for: heading) else {
                    throw TextDeckImportError.unknownSection(line: lineNumber, heading: heading)
                }
                currentZone = zone
                continue
            }

            guard let zone = currentZone else {
                throw TextDeckImportError.entryBeforeSection(line: lineNumber, content: line)
            }
            let parsed = try parseEntry(line, lineNumber: lineNumber, zone: zone)
            let key = EntryKey(zone: zone, normalizedName: TextDeckNameNormalizer.normalize(parsed.displayName))

            if let existing = entriesByKey[key] {
                let (quantity, overflow) = existing.quantity.addingReportingOverflow(parsed.quantity)
                guard !overflow else {
                    throw TextDeckImportError.quantityOverflow(line: lineNumber, cardName: existing.displayName, zone: zone)
                }
                entriesByKey[key] = TextDeckImportEntry(
                    zone: zone,
                    displayName: existing.displayName,
                    quantity: quantity,
                    lineNumber: existing.lineNumber
                )
            } else {
                orderedKeys.append(key)
                entriesByKey[key] = parsed
            }
        }

        let entries = orderedKeys.compactMap { entriesByKey[$0] }
        return TextDeckImportDocument(
            entries: entries,
            suggestedDeckName: suggestedDeckName(from: entries)
        )
    }
}

private extension TextDeckTextParser {
    struct EntryKey: Hashable {
        let zone: DeckZone
        let normalizedName: String
    }

    static let sections: [String: DeckZone] = [
        "legend": .legend,
        "champion": .chosenChampion,
        "maindeck": .main,
        "battlefields": .battlefield,
        "rune pool": .rune,
        "sideboard": .sideboard,
    ]

    static func normalizedLineEndings(in text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func zone(for heading: String) -> DeckZone? {
        sections[TextDeckNameNormalizer.normalize(heading)]
    }

    static func parseEntry(_ line: String, lineNumber: Int, zone: DeckZone) throws -> TextDeckImportEntry {
        guard let separator = line.firstIndex(where: { $0.isWhitespace }) else {
            if Int(line) != nil {
                throw TextDeckImportError.missingCardName(line: lineNumber)
            }
            throw TextDeckImportError.invalidQuantity(line: lineNumber, token: line)
        }

        let quantityToken = String(line[..<separator])
        guard let quantity = Int(quantityToken), quantity > 0 else {
            throw TextDeckImportError.invalidQuantity(line: lineNumber, token: quantityToken)
        }
        let name = String(line[separator...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw TextDeckImportError.missingCardName(line: lineNumber)
        }
        return TextDeckImportEntry(zone: zone, displayName: name, quantity: quantity, lineNumber: lineNumber)
    }

    static func suggestedDeckName(from entries: [TextDeckImportEntry]) -> String? {
        let legendNames = entries.filter { $0.zone == .legend }.map(\.displayName)
        let championNames = entries.filter { $0.zone == .chosenChampion }.map(\.displayName)
        guard legendNames.count <= 1, championNames.count <= 1 else { return nil }

        let legendHero = legendNames.first.flatMap(heroName)
        let championHero = championNames.first.flatMap(heroName)
        let hero: String?
        switch (legendHero, championHero) {
        case let (legend?, champion?) where TextDeckNameNormalizer.normalize(legend) == TextDeckNameNormalizer.normalize(champion):
            hero = legend
        case let (legend?, nil):
            hero = legend
        case let (nil, champion?):
            hero = champion
        default:
            hero = nil
        }
        return hero.map { "\($0) Deck" }
    }

    static func heroName(from displayName: String) -> String? {
        let candidate = displayName.split(separator: ",", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate
    }
}
