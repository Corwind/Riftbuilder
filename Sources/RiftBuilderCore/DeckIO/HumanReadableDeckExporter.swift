import Foundation

public enum HumanReadableDeckExporter {
    public static func export(_ snapshot: DeckSnapshot) -> String {
        var lines = [
            snapshot.deck.name,
            "Ruleset: \(snapshot.deck.rulesetID)",
            "State: \(snapshot.deck.state.rawValue.capitalized)",
        ]

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
            lines.append("")
            lines.append("\(heading(for: zone)) (\(entries.reduce(0) { $0 + $1.quantity }))")
            for entry in entries {
                let name = snapshot.identities[entry.nameSlug]?.displayName ?? entry.nameSlug
                lines.append("\(entry.quantity)x \(name)\(preferenceSuffix(entry))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

private extension HumanReadableDeckExporter {
    static let orderedZones: [DeckZone] = [
        .legend, .chosenChampion, .main, .rune, .battlefield, .sideboard,
    ]

    static func heading(for zone: DeckZone) -> String {
        switch zone {
        case .legend: return "Legend"
        case .chosenChampion: return "Chosen Champion"
        case .main: return "Main Deck"
        case .rune: return "Runes"
        case .battlefield: return "Battlefields"
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

    static func preferenceSuffix(_ entry: DeckEntry) -> String {
        var preferences: [String] = []
        if let productID = entry.preferredProductID { preferences.append("product \(productID)") }
        if let finish = entry.preferredFinish, !finish.isEmpty { preferences.append(finish) }
        if let language = entry.preferredLanguage, !language.isEmpty { preferences.append(language) }
        return preferences.isEmpty ? "" : " [\(preferences.joined(separator: ", "))]"
    }
}
