import Foundation

public enum HumanReadableDeckExporter {
    public static func export(_ snapshot: DeckSnapshot) -> String {
        var sections: [String] = []

        for zone in orderedZones {
            let entries = snapshot.entries
                .filter { $0.zone == zone }
                .sorted { lhs, rhs in
                    let leftName = snapshot.identities[lhs.nameSlug]?.displayName ?? lhs.nameSlug
                    let rightName = snapshot.identities[rhs.nameSlug]?.displayName ?? rhs.nameSlug
                    let comparison = leftName.localizedCaseInsensitiveCompare(rightName)
                    if comparison == .orderedSame { return entrySortKey(lhs) < entrySortKey(rhs) }
                    return comparison == .orderedAscending
            }
            guard !entries.isEmpty else { continue }
            var lines = ["\(heading(for: zone)):"]
            for entry in entries {
                let name = snapshot.identities[entry.nameSlug]?.displayName ?? entry.nameSlug
                lines.append("\(entry.quantity) \(riftDeckName(name))")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n") + (sections.isEmpty ? "" : "\n")
    }
}

private extension HumanReadableDeckExporter {
    static let orderedZones: [DeckZone] = [
        .legend, .chosenChampion, .main, .battlefield, .rune, .sideboard,
    ]

    static func heading(for zone: DeckZone) -> String {
        switch zone {
        case .legend: return "Legend"
        case .chosenChampion: return "Champion"
        case .main: return "MainDeck"
        case .battlefield: return "Battlefields"
        case .rune: return "Rune Pool"
        case .sideboard: return "Sideboard"
        }
    }

    static func entrySortKey(_ entry: DeckEntry) -> String {
        [
            entry.nameSlug,
            entry.preferredProductID.map(String.init) ?? "",
            entry.preferredFinish ?? "",
            entry.preferredLanguage ?? "",
        ].joined(separator: "|")
    }

    static func riftDeckName(_ displayName: String) -> String {
        displayName.replacingOccurrences(of: " - ", with: ", ")
    }
}
