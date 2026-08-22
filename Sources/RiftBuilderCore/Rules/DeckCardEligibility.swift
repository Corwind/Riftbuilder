import Foundation

public enum DeckCardEligibility {
    public static func allows(
        _ identity: CardIdentity,
        in zone: DeckZone,
        legend: CardIdentity? = nil
    ) -> Bool {
        switch zone {
        case .legend:
            isLegend(identity)
        case .chosenChampion:
            isChampion(identity) && !isLegend(identity) && matchesLegendTags(identity, legend: legend)
        case .battlefield:
            isBattlefield(identity)
        case .rune:
            isRune(identity) && matchesLegendDomains(identity, legend: legend)
        case .main, .sideboard:
            !isLegend(identity) && !isRune(identity) && !isBattlefield(identity)
        }
    }

    public static func isLegend(_ identity: CardIdentity) -> Bool {
        hasRole("legend", identity: identity)
    }

    public static func isChampion(_ identity: CardIdentity) -> Bool {
        hasRole("champion", identity: identity)
    }

    public static func isBattlefield(_ identity: CardIdentity) -> Bool {
        hasRole("battlefield", identity: identity)
    }

    public static func isRune(_ identity: CardIdentity) -> Bool {
        hasRole("rune", identity: identity)
    }
}

private extension DeckCardEligibility {
    static func hasRole(_ role: String, identity: CardIdentity) -> Bool {
        ([identity.cardType, identity.superType].compactMap { $0 } + identity.tags).contains { value in
            normalizedWords(value).contains(role)
        }
    }

    static func matchesLegendTags(_ identity: CardIdentity, legend: CardIdentity?) -> Bool {
        guard let legend else { return true }
        let legendTags = Set(legend.tags.map(normalize).filter { !$0.isEmpty })
        let championTags = Set(identity.tags.map(normalize).filter { !$0.isEmpty })
        return !legendTags.isEmpty && !championTags.isDisjoint(with: legendTags)
    }

    static func matchesLegendDomains(_ identity: CardIdentity, legend: CardIdentity?) -> Bool {
        guard let legend else { return true }
        let allowedDomains = Set(legend.domains.map(normalize).filter { !$0.isEmpty })
        let cardDomains = Set(identity.domains.map(normalize).filter { !$0.isEmpty })
        return !allowedDomains.isEmpty && !cardDomains.isEmpty && cardDomains.isSubset(of: allowedDomains)
    }

    static func normalizedWords(_ value: String) -> Set<String> {
        Set(normalize(value).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
