import RiftBuilderCore

extension CardIdentity {
    var appIsRune: Bool {
        cardType?.localizedCaseInsensitiveContains("rune") == true
            || tags.contains { $0.localizedCaseInsensitiveContains("rune") }
    }

    var appIsBattlefield: Bool {
        cardType?.localizedCaseInsensitiveContains("battlefield") == true
    }

    var appVisibleDomains: [String] {
        guard !appIsBattlefield else { return [] }
        return domains.filter { $0.localizedCaseInsensitiveCompare("neutral") != .orderedSame }
    }
}
