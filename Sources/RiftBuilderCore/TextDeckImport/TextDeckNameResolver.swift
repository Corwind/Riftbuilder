import Foundation

public enum TextDeckNameNormalizer {
    public static func normalize(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let characters = Array(folded)
        var result = ""
        var hasPendingWhitespace = false

        for index in characters.indices {
            let character = characters[index]
            if isTitleSeparator(character, at: index, in: characters) {
                if result.last != "," {
                    result.append(",")
                }
                hasPendingWhitespace = false
            } else if character.isWhitespace {
                hasPendingWhitespace = true
            } else {
                if hasPendingWhitespace, !result.isEmpty, result.last != "," {
                    result.append(" ")
                }
                result.append(character)
                hasPendingWhitespace = false
            }
        }

        return result
    }
}

private extension TextDeckNameNormalizer {
    static let unambiguousTitleSeparators: Set<Character> = [",", "–", "—", "―"]

    static func isTitleSeparator(_ character: Character, at index: Int, in characters: [Character]) -> Bool {
        if unambiguousTitleSeparators.contains(character) {
            return true
        }
        guard character == "-" else { return false }
        let hasWhitespaceBefore = index > characters.startIndex && characters[characters.index(before: index)].isWhitespace
        let hasWhitespaceAfter = index < characters.index(before: characters.endIndex) && characters[characters.index(after: index)].isWhitespace
        return hasWhitespaceBefore || hasWhitespaceAfter
    }
}

public enum TextDeckNameResolver {
    public static func resolve(
        _ document: TextDeckImportDocument,
        against catalogue: [CardIdentity],
        deckID: UUID
    ) -> ResolvedTextDeckImport {
        let identitiesByName = Dictionary(grouping: catalogue) {
            TextDeckNameNormalizer.normalize($0.displayName)
        }
        var entries: [DeckEntry] = []
        var identities: [String: CardIdentity] = [:]
        var unresolved: [UnresolvedTextDeckCard] = []
        var ambiguous: [AmbiguousTextDeckCard] = []

        for sourceEntry in document.entries {
            let matchesBySlug = Dictionary(
                identitiesByName[TextDeckNameNormalizer.normalize(sourceEntry.displayName), default: []]
                    .map { ($0.nameSlug, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let matches = matchesBySlug.values.sorted { $0.nameSlug < $1.nameSlug }
            switch matches.count {
            case 0:
                unresolved.append(UnresolvedTextDeckCard(entry: sourceEntry))
            case 1:
                let identity = matches[0]
                entries.append(
                    DeckEntry(
                        deckID: deckID,
                        zone: sourceEntry.zone,
                        nameSlug: identity.nameSlug,
                        quantity: sourceEntry.quantity
                    )
                )
                identities[identity.nameSlug] = identity
            default:
                ambiguous.append(AmbiguousTextDeckCard(entry: sourceEntry, candidates: matches))
            }
        }

        return ResolvedTextDeckImport(
            source: document,
            deckID: deckID,
            entries: entries,
            identities: identities,
            unresolvedCards: unresolved,
            ambiguousCards: ambiguous
        )
    }
}
