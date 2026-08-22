import Foundation

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

    public var preferredImageURL: URL? { preferredPrinting?.imageURL }

    public init(
        identity: CardIdentity,
        preferredPrinting: CataloguePrintingMetadata?,
        printingCount: Int,
        expansionSlugs: [String],
        rarities: [String]
    ) {
        self.identity = identity
        self.preferredPrinting = preferredPrinting
        self.printingCount = printingCount
        self.expansionSlugs = expansionSlugs
        self.rarities = rarities
    }
}
