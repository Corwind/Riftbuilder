import Foundation
import GRDB
import RiftBuilderCore

public struct CardmarketImportDiagnostic: Sendable {
    public let line: Int
    public let cardName: String
    public let detail: String
}

public struct CardmarketImportReport: Sendable {
    public let totalRecords: Int
    public let importedLinks: Int
    public let importedPrices: Int
    public let linksWithoutEURPrice: Int
    public let discardedNonEURPrices: Int
    public let unmatched: [CardmarketImportDiagnostic]
    public let ambiguous: [CardmarketImportDiagnostic]
    public let conflicts: [CardmarketImportDiagnostic]
    public let dryRun: Bool
}

public enum CardmarketImportError: LocalizedError {
    case databaseNotFound(String)
    case invalidJSON(line: Int, underlying: any Error)
    case invalidCardmarketURL(line: Int, value: String)

    public var errorDescription: String? {
        switch self {
        case let .databaseNotFound(path):
            "No RiftBuilder database exists at \(path). Launch RiftBuilder once or pass --database."
        case let .invalidJSON(line, underlying):
            "Could not decode products.jsonl line \(line): \(underlying.localizedDescription)"
        case let .invalidCardmarketURL(line, value):
            "Line \(line) does not contain a valid Cardmarket product URL: \(value)"
        }
    }
}

public enum CardmarketProductsImporter {
    public static func run(
        inputURL: URL,
        databasePath: String,
        dryRun: Bool = false
    ) throws -> CardmarketImportReport {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw CardmarketImportError.databaseNotFound(databasePath)
        }

        // Repository initialization is the production migration entry point. The
        // importer uses its own short-lived pool after the schema is current.
        _ = try GRDBRiftBuilderRepository(path: databasePath)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let database = try DatabasePool(path: databasePath, configuration: configuration)
        let printings = try database.read(loadPrintings)
        let products = try decodeProducts(at: inputURL)
        let matcher = CardmarketProductMatcher(printings: printings)
        let prepared = try prepare(products: products, matcher: matcher)

        if !dryRun {
            try database.write { db in
                for listing in prepared.listings.values.sorted(by: { $0.productID < $1.productID }) {
                    try upsert(listing: listing, in: db)
                }
            }
        }

        let importedPrices = prepared.listings.values.count {
            $0.eurPrices?.selectedCents != nil
        }
        return CardmarketImportReport(
            totalRecords: products.count,
            importedLinks: prepared.listings.count,
            importedPrices: importedPrices,
            linksWithoutEURPrice: prepared.listings.count - importedPrices,
            discardedNonEURPrices: products.count {
                $0.product.prices.currency?.uppercased() != "EUR"
            },
            unmatched: prepared.unmatched,
            ambiguous: prepared.ambiguous,
            conflicts: prepared.conflicts,
            dryRun: dryRun
        )
    }

    private struct LineProduct: Sendable {
        let line: Int
        let product: CardmarketProduct
    }

    private struct Listing: Sendable {
        let line: Int
        let productID: Int64
        let url: String
        let scrapedAt: String
        let eurPrices: CardmarketEURPrices?
        let cardName: String
    }

    private struct PreparedImport {
        var listings: [Int64: Listing]
        var unmatched: [CardmarketImportDiagnostic]
        var ambiguous: [CardmarketImportDiagnostic]
        var conflicts: [CardmarketImportDiagnostic]
    }

    private static func decodeProducts(at url: URL) throws -> [LineProduct] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).enumerated().map { offset, line in
            do {
                return LineProduct(
                    line: offset + 1,
                    product: try decoder.decode(CardmarketProduct.self, from: Data(line))
                )
            } catch {
                throw CardmarketImportError.invalidJSON(line: offset + 1, underlying: error)
            }
        }
    }

    private static func loadPrintings(_ db: Database) throws -> [StoredCardPrinting] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT product_id, name_slug, display_name, expansion_slug, print_number
                FROM card_printing
                """
        ).map { row in
            StoredCardPrinting(
                productID: row["product_id"],
                nameSlug: row["name_slug"],
                displayName: row["display_name"],
                expansionSlug: row["expansion_slug"],
                printNumber: row["print_number"]
            )
        }
    }

    private static func prepare(
        products: [LineProduct],
        matcher: CardmarketProductMatcher
    ) throws -> PreparedImport {
        var result = PreparedImport(
            listings: [:],
            unmatched: [],
            ambiguous: [],
            conflicts: []
        )
        var conflictedProductIDs: Set<Int64> = []
        var productIDByURL: [String: Int64] = [:]

        for lineProduct in products {
            let product = lineProduct.product
            guard let url = URL(string: product.source.url),
                  url.scheme == "https",
                  url.host?.lowercased() == "www.cardmarket.com",
                  url.path.contains("/Riftbound/Products/Singles/")
            else {
                throw CardmarketImportError.invalidCardmarketURL(
                    line: lineProduct.line,
                    value: product.source.url
                )
            }

            switch matcher.match(product) {
            case let .unmatched(reason):
                result.unmatched.append(diagnostic(for: lineProduct, detail: reason))
            case let .ambiguous(productIDs):
                result.ambiguous.append(diagnostic(
                    for: lineProduct,
                    detail: "candidate product IDs: \(productIDs.map(String.init).joined(separator: ", "))"
                ))
            case let .matched(productID):
                if conflictedProductIDs.contains(productID) {
                    result.conflicts.append(diagnostic(
                        for: lineProduct,
                        detail: "another source record already conflicts for product ID \(productID)"
                    ))
                    continue
                }
                if let otherProductID = productIDByURL[product.source.url],
                   otherProductID != productID {
                    result.conflicts.append(diagnostic(
                        for: lineProduct,
                        detail: "URL is already associated with product ID \(otherProductID)"
                    ))
                    continue
                }
                if let existing = result.listings.removeValue(forKey: productID) {
                    conflictedProductIDs.insert(productID)
                    productIDByURL[existing.url] = nil
                    result.conflicts.append(CardmarketImportDiagnostic(
                        line: existing.line,
                        cardName: existing.cardName,
                        detail: "multiple source records map to product ID \(productID)"
                    ))
                    result.conflicts.append(diagnostic(
                        for: lineProduct,
                        detail: "multiple source records map to product ID \(productID)"
                    ))
                    continue
                }

                productIDByURL[product.source.url] = productID
                result.listings[productID] = Listing(
                    line: lineProduct.line,
                    productID: productID,
                    url: product.source.url,
                    scrapedAt: product.source.scrapedAt,
                    eurPrices: product.eurPrices,
                    cardName: product.cardName
                )
            }
        }
        return result
    }

    private static func diagnostic(
        for lineProduct: LineProduct,
        detail: String
    ) -> CardmarketImportDiagnostic {
        CardmarketImportDiagnostic(
            line: lineProduct.line,
            cardName: lineProduct.product.cardName,
            detail: detail
        )
    }

    private static func upsert(listing: Listing, in db: Database) throws {
        if let prices = listing.eurPrices {
            try db.execute(
                sql: """
                    INSERT INTO cardmarket_listing (
                        product_id, url, trend_price_eur_cents,
                        average_7_days_price_eur_cents, average_30_days_price_eur_cents,
                        scraped_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(product_id) DO UPDATE SET
                        url = excluded.url,
                        trend_price_eur_cents = excluded.trend_price_eur_cents,
                        average_7_days_price_eur_cents = excluded.average_7_days_price_eur_cents,
                        average_30_days_price_eur_cents = excluded.average_30_days_price_eur_cents,
                        scraped_at = excluded.scraped_at
                    """,
                arguments: [
                    listing.productID,
                    listing.url,
                    prices.trendCents,
                    prices.average7DaysCents,
                    prices.average30DaysCents,
                    listing.scrapedAt,
                ]
            )
        } else {
            // A non-EUR scrape can still provide the stable product link, but it
            // must not overwrite a previously imported EUR observation.
            try db.execute(
                sql: """
                    INSERT INTO cardmarket_listing (product_id, url, scraped_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(product_id) DO UPDATE SET
                        url = excluded.url,
                        scraped_at = excluded.scraped_at
                    """,
                arguments: [listing.productID, listing.url, listing.scrapedAt]
            )
        }
    }
}
