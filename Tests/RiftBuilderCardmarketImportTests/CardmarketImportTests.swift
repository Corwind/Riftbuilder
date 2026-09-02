import Foundation
import GRDB
import RiftBuilderCore
import XCTest
@testable import RiftBuilderCardmarketImport

final class CardmarketImportTests: XCTestCase {
    func testMatcherKeepsSameCardInDifferentExpansionsSeparate() throws {
        let matcher = CardmarketProductMatcher(printings: [
            printing(101, name: "Same Card", expansion: "origins-main-set", number: "001"),
            printing(202, name: "Same Card", expansion: "spiritforged", number: "001"),
        ])

        XCTAssertEqual(
            matcher.match(try product(name: "Same Card", expansion: "Origins", code: "OGN", number: "001")),
            .matched(productID: 101)
        )
        XCTAssertEqual(
            matcher.match(try product(name: "Same Card", expansion: "Spiritforged", code: "SFD", number: "001")),
            .matched(productID: 202)
        )
    }

    func testMatcherPrefersRawPrefixedCollectorNumber() throws {
        let matcher = CardmarketProductMatcher(printings: [
            printing(1, name: "Calm Rune", expansion: "spiritforged", number: "R02"),
            printing(2, name: "Sand Soldier", expansion: "spiritforged", number: "T02"),
        ])
        let source = try product(
            name: "Calm Rune (V.1 - Common)",
            expansion: "Spiritforged",
            code: "SFD",
            number: "02",
            rawNumber: "R02"
        )

        XCTAssertEqual(matcher.match(source), .matched(productID: 1))
    }

    func testMatcherTriesAsteriskAndSignedSuffixWithinTheSameExpansion() throws {
        let matcher = CardmarketProductMatcher(printings: [
            printing(1, name: "Kai'Sa - Daughter of the Void (Signed)", expansion: "origins-main-set", number: "299s"),
            printing(2, name: "Galio - Indefatigable (Signed)", expansion: "riftbound-promos", number: "S003s"),
            printing(3, name: "Akali - Rogue Assassin (Signed)", expansion: "vendetta", number: "189*"),
            printing(999, name: "Kai'Sa - Daughter of the Void (Signed)", expansion: "spiritforged", number: "299*"),
        ])

        XCTAssertEqual(
            matcher.match(try product(
                name: "Kai'Sa, Daughter of the Void (V.3 - Signed Showcase)",
                expansion: "Origins",
                code: "OGN",
                number: "299*"
            )),
            .matched(productID: 1)
        )
        XCTAssertEqual(
            matcher.match(try product(
                name: "Galio, Indefatigable (V.2 - Signed Showcase)",
                expansion: "T1 2025 Worlds Champion Collection",
                code: "T1X",
                number: "S003*"
            )),
            .matched(productID: 2)
        )
        XCTAssertEqual(
            matcher.match(try product(
                name: "Akali, Rogue Assassin (V.3 - Signed Showcase)",
                expansion: "Vendetta",
                code: "VEN",
                number: "189*"
            )),
            .matched(productID: 3)
        )
    }

    func testMatcherNeverDropsAMeaningfulCollectorSuffix() throws {
        let matcher = CardmarketProductMatcher(printings: [
            printing(1, name: "Jinx, Rebel", expansion: "origins-promo-cards", number: "202"),
        ])
        let source = try product(
            name: "Jinx, Rebel (V.2 - Showcase)",
            expansion: "Origins: Promos",
            code: "OGNX",
            number: "202",
            rawNumber: "202b"
        )

        XCTAssertEqual(
            matcher.match(source),
            .unmatched(reason: "no origins-promo-cards printing numbered 202B")
        )
    }

    func testMatcherUsesNameForDuplicateNumbersAndRejectsUnresolvedVariants() throws {
        let matcher = CardmarketProductMatcher(printings: [
            printing(1, name: "Garen - Rugged", expansion: "spiritforged-promo-cards", number: "007"),
            printing(2, name: "Gem Jammer", expansion: "spiritforged-promo-cards", number: "007"),
            printing(3, name: "Guardian Angel", expansion: "spiritforged-promo-cards", number: "051"),
            printing(4, name: "Guardian Angel (Champion stamp)", expansion: "spiritforged-promo-cards", number: "051"),
        ])

        XCTAssertEqual(
            matcher.match(try product(
                name: "Garen, Rugged",
                expansion: "Spiritforged: Promos",
                code: "SFDX",
                number: "007"
            )),
            .matched(productID: 1)
        )
        XCTAssertEqual(
            matcher.match(try product(
                name: "Guardian Angel (V.2 - Rare)",
                expansion: "Spiritforged: Promos",
                code: "SFDX",
                number: "051"
            )),
            .ambiguous(productIDs: [3, 4])
        )
    }

    func testEURPricesRecoverMissingAveragesFromRawAttributes() throws {
        let source = try product(
            name: "Card",
            expansion: "Origins",
            code: "OGN",
            number: "001",
            currency: "EUR",
            trend: nil,
            average7Days: nil,
            average30Days: nil,
            rawAverage7Days: "1,82 €",
            rawAverage30Days: "1,63 €"
        )

        XCTAssertEqual(
            source.eurPrices,
            CardmarketEURPrices(
                trendCents: nil,
                average7DaysCents: 182,
                average30DaysCents: 163
            )
        )
        XCTAssertEqual(source.eurPrices?.selectedCents, 182)
    }

    func testImporterWritesLinksForAllCurrenciesButOnlyStoresEURPrices() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "riftbuilder-cardmarket-import-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "riftbuilder.sqlite")
        let inputURL = directory.appending(path: "products.jsonl")
        let repository = try GRDBRiftBuilderRepository(path: databaseURL.path)
        try await repository.replaceCatalogue(
            printings: [
                CardPrinting(
                    productID: 101,
                    nameSlug: "same-card",
                    printingSlug: "ogn-same-card-001",
                    displayName: "Same Card",
                    expansionSlug: "origins-main-set",
                    printNumber: "001"
                ),
                CardPrinting(
                    productID: 202,
                    nameSlug: "same-card",
                    printingSlug: "sfd-same-card-001",
                    displayName: "Same Card",
                    expansionSlug: "spiritforged",
                    printNumber: "001"
                ),
            ],
            checksum: "catalogue",
            completedAt: .now
        )
        let input = try [
            productJSON(name: "Same Card", expansion: "Origins", code: "OGN", number: "001", currency: "EUR", trend: 1.99),
            productJSON(name: "Same Card", expansion: "Spiritforged", code: "SFD", number: "001", currency: "GBP", trend: 2.99),
        ].joined(separator: "\n")
        try Data(input.utf8).write(to: inputURL)

        let report = try CardmarketProductsImporter.run(
            inputURL: inputURL,
            databasePath: databaseURL.path
        )

        XCTAssertEqual(report.totalRecords, 2)
        XCTAssertEqual(report.importedLinks, 2)
        XCTAssertEqual(report.importedPrices, 1)
        XCTAssertEqual(report.linksWithoutEURPrice, 1)
        XCTAssertEqual(report.discardedNonEURPrices, 1)
        XCTAssertTrue(report.unmatched.isEmpty)
        XCTAssertTrue(report.ambiguous.isEmpty)

        let database = try DatabaseQueue(path: databaseURL.path)
        let rows = try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT product_id, url, currency, price_cents FROM cardmarket_price ORDER BY product_id"
            )
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["product_id"] as Int64, 101)
        XCTAssertEqual(rows[0]["currency"] as String?, "EUR")
        XCTAssertEqual(rows[0]["price_cents"] as Int?, 199)
        XCTAssertEqual(rows[1]["product_id"] as Int64, 202)
        XCTAssertNotNil(rows[1]["url"] as String?)
        XCTAssertNil(rows[1]["currency"] as String?)
        XCTAssertNil(rows[1]["price_cents"] as Int?)
    }
}

private func printing(
    _ productID: Int64,
    name: String,
    expansion: String,
    number: String
) -> StoredCardPrinting {
    StoredCardPrinting(
        productID: productID,
        nameSlug: name.lowercased().replacingOccurrences(of: " ", with: "-"),
        displayName: name,
        expansionSlug: expansion,
        printNumber: number
    )
}

private func product(
    name: String,
    expansion: String,
    code: String,
    number: String,
    rawNumber: String? = nil,
    currency: String? = "EUR",
    trend: Double? = 1,
    average7Days: Double? = 0.9,
    average30Days: Double? = 0.8,
    rawAverage7Days: String = "0,90 €",
    rawAverage30Days: String = "0,80 €"
) throws -> CardmarketProduct {
    let json = try productJSON(
        name: name,
        expansion: expansion,
        code: code,
        number: number,
        rawNumber: rawNumber,
        currency: currency,
        trend: trend,
        average7Days: average7Days,
        average30Days: average30Days,
        rawAverage7Days: rawAverage7Days,
        rawAverage30Days: rawAverage30Days
    )
    return try JSONDecoder().decode(CardmarketProduct.self, from: Data(json.utf8))
}

private func productJSON(
    name: String,
    expansion: String,
    code: String,
    number: String,
    rawNumber: String? = nil,
    currency: String? = "EUR",
    trend: Double? = 1,
    average7Days: Double? = 0.9,
    average30Days: Double? = 0.8,
    rawAverage7Days: String = "0,90 €",
    rawAverage30Days: String = "0,80 €"
) throws -> String {
    let object: [String: Any] = [
        "source": [
            "url": "https://www.cardmarket.com/en/Riftbound/Products/Singles/\(expansion)/\(name)",
            "scrapedAt": "2026-08-29T12:00:00Z",
        ],
        "identity": [
            "displayName": "\(name) \(expansion) - Singles",
            "expansionName": expansion,
            "expansionCode": code,
            "collectorNumber": number,
        ],
        "prices": [
            "currency": currency.map { $0 as Any } ?? NSNull(),
            "trend": ["raw": NSNull(), "value": trend.map { $0 as Any } ?? NSNull()],
            "average7Days": ["raw": NSNull(), "value": average7Days.map { $0 as Any } ?? NSNull()],
            "average30Days": ["raw": NSNull(), "value": average30Days.map { $0 as Any } ?? NSNull()],
        ],
        "attributes": [
            "Number": rawNumber ?? number,
            "7-days average price": rawAverage7Days,
            "30-days average price": rawAverage30Days,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
