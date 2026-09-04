import XCTest
@testable import RiftBuilderCore

final class DeckPriceCalculatorTests: XCTestCase {

    private func entry(nameSlug: String, quantity: Int, zone: DeckZone = .main) -> DeckEntry {
        DeckEntry(deckID: UUID(), zone: zone, nameSlug: nameSlug, quantity: quantity)
    }

    private func listing(productID: Int64, priceCents: Int?, currency: String? = "EUR") -> CardMarketListing {
        CardMarketListing(
            productID: productID,
            printingSlug: "print-\(productID)",
            url: URL(string: "https://example.com/\(productID)")!,
            currency: currency,
            priceCents: priceCents,
            scrapedAt: "2025-01-01T00:00:00Z"
        )
    }

    func test_emptyDeck_hasZeroPrice() {
        let summary = DeckPriceCalculator.calculate(entries: [], marketListingsBySlug: [:])
        XCTAssertEqual(summary.totalCents, 0)
        XCTAssertEqual(summary.pricedEntryCount, 0)
        XCTAssertEqual(summary.totalEntryCount, 0)
        XCTAssertNil(summary.currency)
        XCTAssertTrue(summary.hasNoPriceData)
    }

    func test_singleCard_singlePrinting() {
        let entries = [entry(nameSlug: "fireball", quantity: 3)]
        let listings: [String: [CardMarketListing]] = [
            "fireball": [listing(productID: 1, priceCents: 50)]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.totalCents, 150) // 50¢ × 3
        XCTAssertEqual(summary.pricedEntryCount, 1)
        XCTAssertEqual(summary.totalEntryCount, 1)
        XCTAssertEqual(summary.currency, "EUR")
        XCTAssertTrue(summary.isFullyPriced)
    }

    func test_multipleCards_summed() {
        let entries = [
            entry(nameSlug: "fireball", quantity: 2),
            entry(nameSlug: "lightning", quantity: 4)
        ]
        let listings: [String: [CardMarketListing]] = [
            "fireball": [listing(productID: 1, priceCents: 100)],
            "lightning": [listing(productID: 2, priceCents: 25)]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.totalCents, 300) // (100 × 2) + (25 × 4) = 200 + 100
        XCTAssertTrue(summary.isFullyPriced)
    }

    func test_usesLowestPriceAcrossPrintings() {
        let entries = [entry(nameSlug: "fireball", quantity: 1)]
        let listings: [String: [CardMarketListing]] = [
            "fireball": [
                listing(productID: 1, priceCents: 200), // expensive edition
                listing(productID: 2, priceCents: 50),  // cheap edition
                listing(productID: 3, priceCents: 150)  // mid edition
            ]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.totalCents, 50) // lowest = 50¢
    }

    func test_cardWithNoListings_skipped() {
        let entries = [
            entry(nameSlug: "fireball", quantity: 2),
            entry(nameSlug: "unpriced", quantity: 1)
        ]
        let listings: [String: [CardMarketListing]] = [
            "fireball": [listing(productID: 1, priceCents: 100)]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.totalCents, 200) // only fireball priced
        XCTAssertEqual(summary.pricedEntryCount, 1)
        XCTAssertEqual(summary.totalEntryCount, 2)
        XCTAssertFalse(summary.isFullyPriced)
    }

    func test_listingsWithNilPrice_ignored() {
        let entries = [entry(nameSlug: "fireball", quantity: 1)]
        let listings: [String: [CardMarketListing]] = [
            "fireball": [
                listing(productID: 1, priceCents: nil),
                listing(productID: 2, priceCents: 75)
            ]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.totalCents, 75) // nil-price listing skipped, 75¢ used
        XCTAssertTrue(summary.isFullyPriced)
    }

    func test_allListingsHaveNilPrice_treatedAsUnpriced() {
        let entries = [entry(nameSlug: "fireball", quantity: 1)]
        let listings: [String: [CardMarketListing]] = [
            "fireball": [
                listing(productID: 1, priceCents: nil),
                listing(productID: 2, priceCents: nil)
            ]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.totalCents, 0)
        XCTAssertEqual(summary.pricedEntryCount, 0)
        XCTAssertTrue(summary.hasNoPriceData)
    }

    func test_quantityMultipliedCorrectly() {
        let entries = [entry(nameSlug: "fireball", quantity: 7)]
        let listings: [String: [CardMarketListing]] = [
            "fireball": [listing(productID: 1, priceCents: 33)]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.totalCents, 231) // 33 × 7
    }

    func test_currencyExtractedFromFirstPricedListing() {
        let entries = [entry(nameSlug: "fireball", quantity: 1)]
        let listings: [String: [CardMarketListing]] = [
            "fireball": [listing(productID: 1, priceCents: 100, currency: "USD")]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.currency, "USD")
    }

    func test_currencyDefaultsToEurWhenListingCurrencyIsNil() {
        let entries = [entry(nameSlug: "fireball", quantity: 1)]
        let listings: [String: [CardMarketListing]] = [
            "fireball": [listing(productID: 1, priceCents: 100, currency: nil)]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.currency, "EUR")
    }

    func test_entriesAcrossAllZonesCounted() {
        let entries = [
            entry(nameSlug: "legend", quantity: 1, zone: .legend),
            entry(nameSlug: "main1", quantity: 3, zone: .main),
            entry(nameSlug: "rune1", quantity: 2, zone: .rune)
        ]
        let listings: [String: [CardMarketListing]] = [
            "legend": [listing(productID: 1, priceCents: 500)],
            "main1": [listing(productID: 2, priceCents: 50)],
            "rune1": [listing(productID: 3, priceCents: 25)]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.totalCents, 500 + 150 + 50) // 500 + (50×3) + (25×2)
        XCTAssertEqual(summary.totalEntryCount, 3)
        XCTAssertTrue(summary.isFullyPriced)
    }

    func test_partialPricing_mixedPricedAndUnpriced() {
        let entries = [
            entry(nameSlug: "priced1", quantity: 2),
            entry(nameSlug: "priced2", quantity: 1),
            entry(nameSlug: "unpriced1", quantity: 3),
            entry(nameSlug: "unpriced2", quantity: 1)
        ]
        let listings: [String: [CardMarketListing]] = [
            "priced1": [listing(productID: 1, priceCents: 100)],
            "priced2": [listing(productID: 2, priceCents: 200)]
        ]
        let summary = DeckPriceCalculator.calculate(entries: entries, marketListingsBySlug: listings)
        XCTAssertEqual(summary.totalCents, 400) // (100×2) + (200×1)
        XCTAssertEqual(summary.pricedEntryCount, 2)
        XCTAssertEqual(summary.totalEntryCount, 4)
        XCTAssertFalse(summary.isFullyPriced)
        XCTAssertFalse(summary.hasNoPriceData)
    }
}
