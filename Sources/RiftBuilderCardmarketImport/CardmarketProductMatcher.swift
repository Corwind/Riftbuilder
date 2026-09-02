import Foundation

struct StoredCardPrinting: Equatable, Sendable {
    let productID: Int64
    let nameSlug: String
    let displayName: String
    let expansionSlug: String?
    let printNumber: String?
}

enum CardmarketProductMatch: Equatable, Sendable {
    case matched(productID: Int64)
    case unmatched(reason: String)
    case ambiguous(productIDs: [Int64])
}

struct CardmarketProductMatcher: Sendable {
    static let defaultExpansionSlugs = [
        "OGN": "origins-main-set",
        "OGNX": "origins-promo-cards",
        "OGS": "origins-proving-grounds",
        "PROK": "project-k",
        "SFD": "spiritforged",
        "SFDX": "spiritforged-promo-cards",
        "SGN": "unleashed-promo-cards",
        "T1X": "riftbound-promos",
        "UNL": "unleashed",
        "UNLX": "unleashed-promo-cards",
        "VEN": "vendetta",
        "VENX": "vendetta-promo-cards",
    ]

    private let printingsByExpansion: [String: [StoredCardPrinting]]
    private let expansionSlugs: [String: String]

    init(
        printings: [StoredCardPrinting],
        expansionSlugs: [String: String] = Self.defaultExpansionSlugs
    ) {
        printingsByExpansion = Dictionary(grouping: printings.compactMap { printing in
            printing.expansionSlug.map { ($0, printing) }
        }, by: \.0).mapValues { pairs in
            pairs.map(\.1)
        }
        self.expansionSlugs = expansionSlugs
    }

    func match(_ product: CardmarketProduct) -> CardmarketProductMatch {
        let expansionCode = product.identity.expansionCode.uppercased()
        guard let expansionSlug = expansionSlugs[expansionCode] else {
            return .unmatched(reason: "unsupported expansion \(expansionCode)")
        }
        guard let expansionPrintings = printingsByExpansion[expansionSlug] else {
            return .unmatched(reason: "no local printings for \(expansionSlug)")
        }

        let rawCandidates = candidates(
            numbered: product.collectorNumbers,
            in: expansionPrintings
        )
        guard !rawCandidates.isEmpty else {
            let numbers = product.collectorNumbers.joined(separator: ", ")
            return .unmatched(reason: "no \(expansionSlug) printing numbered \(numbers)")
        }
        return resolve(rawCandidates, for: product)
    }

    private func candidates(
        numbered collectorNumbers: [String],
        in printings: [StoredCardPrinting]
    ) -> [StoredCardPrinting] {
        let normalizedNumbers = Set(collectorNumbers.map { $0.uppercased() })
        return printings.filter { printing in
            guard let printNumber = printing.printNumber else { return false }
            return normalizedNumbers.contains(printNumber.uppercased())
        }
    }

    private func resolve(
        _ candidates: [StoredCardPrinting],
        for product: CardmarketProduct
    ) -> CardmarketProductMatch {
        let uniqueCandidates = Dictionary(
            candidates.map { ($0.productID, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.productID < $1.productID }
        let sourceName = normalizedBaseName(product.cardName)
        let matchingNames = uniqueCandidates.filter {
            normalizedBaseName($0.displayName) == sourceName
        }
        if matchingNames.count == 1 {
            return .matched(productID: matchingNames[0].productID)
        }
        if matchingNames.count > 1 {
            return .ambiguous(productIDs: matchingNames.map(\.productID))
        }
        if uniqueCandidates.count == 1 {
            return .unmatched(
                reason: "collector number matched product ID \(uniqueCandidates[0].productID), but the card name did not"
            )
        }
        return .ambiguous(productIDs: uniqueCandidates.map(\.productID))
    }

    private func normalizedBaseName(_ value: String) -> String {
        let withoutPresentationSuffix = value.replacingOccurrences(
            of: #"(?:\s*\((?:alt|alternate art|metal|signed|signature|overnumbered|promo alternate|worlds 2025|oversized card|champion stamp|champion|top 8|top cut|top 128|winner|participation|prerelease|pre-rift promo|lunar revel 2026|secret garden|serialized|ultimate)\))+\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let folded = withoutPresentationSuffix.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
