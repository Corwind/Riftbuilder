import Foundation

public enum CardMarketPriceSource: String, Codable, Hashable, Sendable {
    case trend
    case average7Days = "average_7_days"
    case average30Days = "average_30_days"
}

public struct CardMarketListing: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64 { productID }
    public let productID: Int64
    public let printingSlug: String
    public let expansionSlug: String?
    public let printNumber: String?
    public let url: URL
    public let currency: String?
    public let priceCents: Int?
    public let priceSource: CardMarketPriceSource?
    public let scrapedAt: String

    public init(productID: Int64, printingSlug: String, expansionSlug: String? = nil, printNumber: String? = nil, url: URL, currency: String? = nil, priceCents: Int? = nil, priceSource: CardMarketPriceSource? = nil, scrapedAt: String) {
        self.productID = productID
        self.printingSlug = printingSlug
        self.expansionSlug = expansionSlug
        self.printNumber = printNumber
        self.url = url
        self.currency = currency
        self.priceCents = priceCents
        self.priceSource = priceSource
        self.scrapedAt = scrapedAt
    }
}

public struct CataloguePrintingMetadata: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64 { productID }
    public let productID: Int64
    public let printingSlug: String
    public let expansionSlug: String?
    public let printNumber: String?
    public let rarity: String?
    public let imageURL: URL?

    public init(
        productID: Int64,
        printingSlug: String,
        expansionSlug: String? = nil,
        printNumber: String? = nil,
        rarity: String? = nil,
        imageURL: URL? = nil
    ) {
        self.productID = productID
        self.printingSlug = printingSlug
        self.expansionSlug = expansionSlug
        self.printNumber = printNumber
        self.rarity = rarity
        self.imageURL = imageURL
    }
}

public struct CatalogueCardSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String { identity.nameSlug }
    public let identity: CardIdentity
    public let preferredPrinting: CataloguePrintingMetadata?
    public let printingCount: Int
    public let expansionSlugs: [String]
    public let rarities: [String]
    public let marketListings: [CardMarketListing]

    public var preferredImageURL: URL? { preferredPrinting?.imageURL }

    public init(
        identity: CardIdentity,
        preferredPrinting: CataloguePrintingMetadata?,
        printingCount: Int,
        expansionSlugs: [String],
        rarities: [String],
        marketListings: [CardMarketListing] = []
    ) {
        self.identity = identity
        self.preferredPrinting = preferredPrinting
        self.printingCount = printingCount
        self.expansionSlugs = expansionSlugs
        self.rarities = rarities
        self.marketListings = marketListings
    }
}
