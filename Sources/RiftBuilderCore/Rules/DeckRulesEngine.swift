import Foundation

public enum DeckRulesEngine {
    public static func validate(snapshot: DeckSnapshot, ruleset: ConstructedRuleset) -> [DeckValidationIssue] {
        var issues: [DeckValidationIssue] = []
        let entries = snapshot.entries

        let invalidEntries = entries.filter { $0.quantity <= 0 }
        if !invalidEntries.isEmpty {
            issues.append(issue(
                severity: .error,
                code: "invalid_quantity",
                message: "Deck entries must have a positive quantity.",
                slugs: invalidEntries.map(\.nameSlug)
            ))
        }

        let unknownSlugs = Set(entries.map(\.nameSlug)).subtracting(snapshot.identities.keys).sorted()
        if !unknownSlugs.isEmpty {
            issues.append(issue(
                severity: .error,
                code: "unknown_cards",
                message: "Some deck entries do not resolve to a card identity.",
                slugs: unknownSlugs
            ))
        }

        validateZoneCount(
            entries: entries,
            zones: [.main, .chosenChampion],
            expected: ruleset.mainDeckCount,
            code: "main_deck_count",
            label: "main deck cards including the chosen champion",
            issues: &issues
        )
        validateZoneCount(
            entries: entries,
            zones: [.legend],
            expected: 1,
            code: "legend_count",
            label: "Champion Legend",
            issues: &issues
        )
        validateZoneCount(
            entries: entries,
            zones: [.chosenChampion],
            expected: 1,
            code: "chosen_champion_count",
            label: "chosen champion",
            issues: &issues
        )
        validateZoneCount(
            entries: entries,
            zones: [.rune],
            expected: ruleset.runeCount,
            code: "rune_count",
            label: "runes",
            issues: &issues
        )
        validateZoneCount(
            entries: entries,
            zones: [.battlefield],
            expected: ruleset.battlefieldCount,
            code: "battlefield_count",
            label: "battlefields",
            issues: &issues
        )

        let battlefieldEntries = entries.filter { $0.zone == .battlefield && $0.quantity > 0 }
        let battlefieldNames = Set(battlefieldEntries.map(\.nameSlug))
        if battlefieldNames.count != ruleset.battlefieldCount
            || battlefieldEntries.contains(where: { $0.quantity != 1 })
        {
            issues.append(issue(
                severity: .error,
                code: "battlefield_uniqueness",
                message: "Battlefields must be \(ruleset.battlefieldCount) uniquely named single cards.",
                slugs: battlefieldEntries.map(\.nameSlug)
            ))
        }

        let copyLimitZones: Set<DeckZone> = [.main, .chosenChampion, .sideboard]
        let quantitiesByName = Dictionary(grouping: entries.filter { copyLimitZones.contains($0.zone) }, by: \.nameSlug)
            .mapValues { $0.reduce(0) { $0 + max(0, $1.quantity) } }
        for (slug, quantity) in quantitiesByName.sorted(by: { $0.key < $1.key }) where quantity > ruleset.maximumCopiesByName {
            issues.append(issue(
                severity: .error,
                code: "copy_limit",
                message: "\(displayName(for: slug, in: snapshot)) has \(quantity) copies; the limit is \(ruleset.maximumCopiesByName) across the main deck and sideboard.",
                slugs: [slug]
            ))
        }

        let sideboardCount = count(entries, in: [.sideboard])
        if sideboardCount > ruleset.maximumSideboardCount {
            issues.append(issue(
                severity: .error,
                code: "sideboard_count",
                message: "The sideboard has \(sideboardCount) cards; the maximum is \(ruleset.maximumSideboardCount).",
                slugs: entries.filter { $0.zone == .sideboard }.map(\.nameSlug)
            ))
        }

        validateDomains(snapshot: snapshot, issues: &issues)
        validateChampionTags(snapshot: snapshot, issues: &issues)
        validateSignatures(snapshot: snapshot, ruleset: ruleset, issues: &issues)
        validateBans(snapshot: snapshot, ruleset: ruleset, issues: &issues)
        validateLegalExpansions(snapshot: snapshot, ruleset: ruleset, issues: &issues)

        return issues
    }
}

private extension DeckRulesEngine {
    static func validateZoneCount(
        entries: [DeckEntry],
        zones: Set<DeckZone>,
        expected: Int,
        code: String,
        label: String,
        issues: inout [DeckValidationIssue]
    ) {
        let actual = count(entries, in: zones)
        guard actual != expected else { return }
        issues.append(issue(
            severity: .error,
            code: code,
            message: "The deck must contain exactly \(expected) \(label); it currently contains \(actual).",
            slugs: entries.filter { zones.contains($0.zone) }.map(\.nameSlug)
        ))
    }

    static func count(_ entries: [DeckEntry], in zones: Set<DeckZone>) -> Int {
        entries.lazy.filter { zones.contains($0.zone) }.reduce(0) { $0 + max(0, $1.quantity) }
    }

    static func validateDomains(snapshot: DeckSnapshot, issues: inout [DeckValidationIssue]) {
        guard let legendEntry = snapshot.entries.first(where: { $0.zone == .legend }),
              let legend = snapshot.identities[legendEntry.nameSlug]
        else { return }

        let allowed = Set(legend.domains.map(normalize))
        guard !allowed.isEmpty else { return }
        let checkedZones: Set<DeckZone> = [.chosenChampion, .main, .rune, .sideboard]
        for entry in snapshot.entries where checkedZones.contains(entry.zone) {
            guard let identity = snapshot.identities[entry.nameSlug] else { continue }
            let cardDomains = Set(identity.domains.map(normalize))
            guard !cardDomains.isEmpty, !cardDomains.isSubset(of: allowed) else { continue }
            issues.append(issue(
                severity: .error,
                code: "domain_identity",
                message: "\(identity.displayName) contains a domain outside the Champion Legend's domain identity.",
                slugs: [identity.nameSlug]
            ))
        }
    }

    static func validateChampionTags(snapshot: DeckSnapshot, issues: inout [DeckValidationIssue]) {
        guard let legendEntry = snapshot.entries.first(where: { $0.zone == .legend }),
              let championEntry = snapshot.entries.first(where: { $0.zone == .chosenChampion }),
              let legend = snapshot.identities[legendEntry.nameSlug],
              let champion = snapshot.identities[championEntry.nameSlug]
        else { return }

        let legendTags = Set(legend.tags.map(normalize))
        let championTags = Set(champion.tags.map(normalize))
        if legendTags.isDisjoint(with: championTags) {
            issues.append(issue(
                severity: .error,
                code: "champion_tag",
                message: "The chosen champion must share a champion tag with the Champion Legend.",
                slugs: [legend.nameSlug, champion.nameSlug]
            ))
        }
    }

    static func validateSignatures(snapshot: DeckSnapshot, ruleset: ConstructedRuleset, issues: inout [DeckValidationIssue]) {
        let relevantZones: Set<DeckZone> = [.main, .chosenChampion, .sideboard]
        let signatureEntries = snapshot.entries.filter { entry in
            relevantZones.contains(entry.zone) && snapshot.identities[entry.nameSlug].map(isSignature) == true
        }
        let signatureCount = signatureEntries.reduce(0) { $0 + max(0, $1.quantity) }
        if signatureCount > ruleset.maximumSignatureCards {
            issues.append(issue(
                severity: .error,
                code: "signature_limit",
                message: "The deck has \(signatureCount) signature cards; the maximum is \(ruleset.maximumSignatureCards).",
                slugs: signatureEntries.map(\.nameSlug)
            ))
        }

        guard let championEntry = snapshot.entries.first(where: { $0.zone == .chosenChampion }),
              let champion = snapshot.identities[championEntry.nameSlug]
        else { return }
        let championIdentifiers = Set(([champion.nameSlug, champion.displayName] + champion.tags).map(normalize))

        for entry in signatureEntries {
            guard let identity = snapshot.identities[entry.nameSlug] else { continue }
            let restrictions = signatureRestrictions(identity)
            guard !restrictions.isEmpty,
                  Set(restrictions.map(normalize)).isDisjoint(with: championIdentifiers)
            else { continue }
            issues.append(issue(
                severity: .error,
                code: "signature_restriction",
                message: "\(identity.displayName) is not a signature card for the chosen champion.",
                slugs: [identity.nameSlug, champion.nameSlug]
            ))
        }
    }

    static func validateBans(snapshot: DeckSnapshot, ruleset: ConstructedRuleset, issues: inout [DeckValidationIssue]) {
        let bannedCards = Set(ruleset.bannedCards.map(normalize))
        let bannedBattlefields = Set(ruleset.bannedBattlefields.map(normalize))
        for entry in snapshot.entries {
            guard let identity = snapshot.identities[entry.nameSlug] else { continue }
            let names = Set([identity.nameSlug, identity.displayName].map(normalize))
            let isBanned = entry.zone == .battlefield
                ? !names.isDisjoint(with: bannedBattlefields)
                : !names.isDisjoint(with: bannedCards)
            if isBanned {
                issues.append(issue(
                    severity: .error,
                    code: entry.zone == .battlefield ? "banned_battlefield" : "banned_card",
                    message: "\(identity.displayName) is banned by \(ruleset.name) \(ruleset.effectiveDate).",
                    slugs: [identity.nameSlug]
                ))
            }
        }
    }

    static func validateLegalExpansions(snapshot: DeckSnapshot, ruleset: ConstructedRuleset, issues: inout [DeckValidationIssue]) {
        guard let legalValues = ruleset.legalExpansionSlugs, !legalValues.isEmpty else { return }
        let legal = Set(legalValues.map(normalize))
        for entry in snapshot.entries {
            guard let identity = snapshot.identities[entry.nameSlug] else { continue }
            let expansion = identity.attributes.string(for: ["expansionSlug", "expansion_slug", "setSlug", "set_slug", "set"])
            guard let expansion else {
                issues.append(issue(
                    severity: .warning,
                    code: "unknown_set_legality",
                    message: "The expansion for \(identity.displayName) is unknown, so set legality could not be confirmed.",
                    slugs: [identity.nameSlug]
                ))
                continue
            }
            if !legal.contains(normalize(expansion)) {
                issues.append(issue(
                    severity: .error,
                    code: "illegal_set",
                    message: "\(identity.displayName) is from an expansion that is not legal in this ruleset.",
                    slugs: [identity.nameSlug]
                ))
            }
        }
    }

    static func isSignature(_ identity: CardIdentity) -> Bool {
        for key in ["isSignature", "is_signature", "signature"] {
            switch identity.attributes[key] {
            case .bool(true): return true
            case let .string(value) where ["true", "yes", "signature"].contains(normalize(value)): return true
            default: continue
            }
        }
        return normalize(identity.cardType ?? "") == "signature"
            || normalize(identity.superType ?? "") == "signature"
    }

    static func signatureRestrictions(_ identity: CardIdentity) -> [String] {
        identity.attributes.strings(for: [
            "signatureFor", "signature_for", "signatureChampion", "signature_champion",
        ])
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func displayName(for slug: String, in snapshot: DeckSnapshot) -> String {
        snapshot.identities[slug]?.displayName ?? slug
    }

    static func issue(
        severity: ValidationSeverity,
        code: String,
        message: String,
        slugs: [String]
    ) -> DeckValidationIssue {
        let uniqueSlugs = Array(Set(slugs)).sorted()
        return DeckValidationIssue(
            id: "\(code):\(uniqueSlugs.joined(separator: ","))",
            severity: severity,
            code: code,
            message: message,
            affectedNameSlugs: uniqueSlugs
        )
    }
}
