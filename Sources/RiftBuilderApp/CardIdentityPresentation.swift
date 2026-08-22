import RiftBuilderCore

extension CardIdentity {
    var appIsRune: Bool {
        DeckCardEligibility.isRune(self)
    }

    var appIsBattlefield: Bool {
        DeckCardEligibility.isBattlefield(self)
    }

    var appVisibleDomains: [String] {
        guard !appIsBattlefield else { return [] }
        return domains.filter { $0.localizedCaseInsensitiveCompare("neutral") != .orderedSame }
    }
}
