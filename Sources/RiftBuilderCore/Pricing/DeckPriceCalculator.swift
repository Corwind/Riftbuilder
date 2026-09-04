import Foundation

/// A summary of the market price for a deck.
public struct DeckPriceSummary: Sendable, Equatable {
    /// Total price of all priced entries, in cents.
    public let totalCents: Int
    /// Number of entries that have at least one listing with a price.
    public let pricedEntryCount: Int
    /// Total number of entries in the deck.
    public let totalEntryCount: Int
    /// Currency code shared by all listings (e.g. ``"EUR"``).
    /// `nil` when no listings have a price.
    public let currency: String?

    /// `true` when every entry has at least one priced listing.
    public var isFullyPriced: Bool { pricedEntryCount == totalEntryCount }

    /// `true` when no entry has any price data at all.
    public var hasNoPriceData: Bool { pricedEntryCount == 0 }

    public init(totalCents: Int, pricedEntryCount: Int, totalEntryCount: Int, currency: String?) {
        self.totalCents = totalCents
        self.pricedEntryCount = pricedEntryCount
        self.totalEntryCount = totalEntryCount
        self.currency = currency
    }
}

/// Computes the market price of a deck.
///
/// For each deck entry the calculator looks up all market listings for the
/// card's ``nameSlug``, selects the **lowest** available price (so that the
/// cheapest printing is used when a card exists in multiple editions), and
/// multiplies by the entry's ``quantity``.  The deck price is the sum of those
/// per-entry totals.
public enum DeckPriceCalculator {
    /// Calculates the deck price from entries and their associated market listings.
    ///
    /// - Parameters:
    ///   - entries: The deck entries (each carrying a ``DeckEntry/nameSlug``
    ///     and ``DeckEntry/quantity``).
    ///   - marketListingsBySlug: A dictionary mapping each card's ``nameSlug``
    ///     to its list of market listings across all printings.
    /// - Returns: A ``DeckPriceSummary`` describing the total, coverage and
    ///   currency.
    public static func calculate(
        entries: [DeckEntry],
        marketListingsBySlug: [String: [CardMarketListing]]
    ) -> DeckPriceSummary {
        var totalCents = 0
        var pricedEntryCount = 0
        var currency: String?

        for entry in entries {
            let listings = marketListingsBySlug[entry.nameSlug] ?? []
            let pricedListings = listings.compactMap { listing -> (Int, String?)? in
                guard let cents = listing.priceCents else { return nil }
                return (cents, listing.currency)
            }
            guard let lowestPrice = pricedListings.map(\.0).min() else { continue }

            totalCents += lowestPrice * entry.quantity
            pricedEntryCount += 1

            if currency == nil {
                currency = pricedListings.first(where: { $0.1 != nil })?.1 ?? "EUR"
            }
        }

        return DeckPriceSummary(
            totalCents: totalCents,
            pricedEntryCount: pricedEntryCount,
            totalEntryCount: entries.count,
            currency: currency
        )
    }
}
