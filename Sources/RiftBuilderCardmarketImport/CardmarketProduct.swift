import Foundation

struct CardmarketProduct: Decodable, Sendable {
    struct Source: Decodable, Sendable {
        let url: String
        let scrapedAt: String
    }

    struct Identity: Decodable, Sendable {
        let displayName: String
        let expansionName: String
        let expansionCode: String
        let collectorNumber: String
    }

    struct PricePoint: Decodable, Sendable {
        let raw: String?
        let value: Decimal?
    }

    struct Prices: Decodable, Sendable {
        let currency: String?
        let trend: PricePoint
        let average7Days: PricePoint
        let average30Days: PricePoint
    }

    let source: Source
    let identity: Identity
    let prices: Prices
    let attributes: [String: String]

    var cardName: String {
        let suffix = " \(identity.expansionName) - Singles"
        let withoutExpansion = identity.displayName.hasSuffix(suffix)
            ? String(identity.displayName.dropLast(suffix.count))
            : identity.displayName
        return withoutExpansion.replacingOccurrences(
            of: #"\s*\(V\.\d+\s*-\s*[^)]*\)\s*$"#,
            with: "",
            options: .regularExpression
        )
    }

    var collectorNumbers: [String] {
        let rawNumbers = attributes["Number"].map(Self.splitCollectorNumbers) ?? []
        return rawNumbers.isEmpty ? Self.splitCollectorNumbers(identity.collectorNumber) : rawNumbers
    }

    var eurPrices: CardmarketEURPrices? {
        guard prices.currency?.uppercased() == "EUR" else { return nil }
        return CardmarketEURPrices(
            trendCents: Self.cents(prices.trend.value)
                ?? Self.eurCents(prices.trend.raw),
            average7DaysCents: Self.cents(prices.average7Days.value)
                ?? Self.eurCents(attributes["7-days average price"])
                ?? Self.eurCents(prices.average7Days.raw),
            average30DaysCents: Self.cents(prices.average30Days.value)
                ?? Self.eurCents(attributes["30-days average price"])
                ?? Self.eurCents(prices.average30Days.raw)
        )
    }

    private static func splitCollectorNumbers(_ value: String) -> [String] {
        value
            .split(separator: "/")
            .flatMap { collectorNumberAliases(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func collectorNumberAliases(_ value: String) -> [String] {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.hasSuffix("*") else { return [normalized] }
        return [normalized, normalized.dropLast() + "S"]
    }

    private static func eurCents(_ raw: String?) -> Int? {
        guard let raw, raw.contains("€") else { return nil }
        let normalized = raw
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
            .flatMap(cents)
    }

    private static func cents(_ value: Decimal?) -> Int? {
        guard let value, value >= 0 else { return nil }
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}

struct CardmarketEURPrices: Equatable, Sendable {
    let trendCents: Int?
    let average7DaysCents: Int?
    let average30DaysCents: Int?

    var selectedCents: Int? {
        trendCents ?? average7DaysCents ?? average30DaysCents
    }
}
