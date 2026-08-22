import Foundation

struct InventoryPageDTO: Decodable, Sendable {
    let data: [InventoryLineDTO]
    let pagination: PaginationDTO
}

struct PaginationDTO: Decodable, Sendable { let nextCursor: String? }

struct InventoryLineDTO: Decodable, Sendable {
    let id: String
    let customId: String?
    let productId: Int64
    let finish: String
    let condition: String?
    let language: String?
    let quantity: Int
    let graded: JSONValue?
    let location: String?
    let tags: [String]
    let comment: String?
    let notes: String?
    let forSale: Bool
    let listing: JSONValue?
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, customId, productId, finish, condition, language, quantity, graded, location, tags, comment, notes, forSale, listing, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        customId = try container.decodeIfPresent(String.self, forKey: .customId)
        productId = try container.decode(Int64.self, forKey: .productId)
        finish = try container.decode(String.self, forKey: .finish)
        condition = try container.decodeIfPresent(String.self, forKey: .condition)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        quantity = try container.decode(Int.self, forKey: .quantity)
        graded = try container.decodeIfPresent(JSONValue.self, forKey: .graded)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        forSale = try container.decodeIfPresent(Bool.self, forKey: .forSale) ?? false
        listing = try container.decodeIfPresent(JSONValue.self, forKey: .listing)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    var model: InventoryLine {
        InventoryLine(inventoryID: id, customID: customId, productID: productId, finish: finish, condition: condition, language: language, quantity: quantity, graded: graded, locationName: location, tags: tags, comment: comment, notes: notes, isForSale: forSale, listing: listing, updatedAt: updatedAt)
    }
}

struct InventoryLocationDTO: Decodable, Sendable {
    let name: String
    let color: String?
    let icon: String?
    var model: InventoryLocation { InventoryLocation(name: name, color: color, icon: icon) }
}

struct CatalogueFeedMetadataDTO: Decodable, Sendable {
    let feedType: String
    let url: URL
    let checksum: String
    let recordCount: Int
    let encoding: String
    let generatedAt: Date
    var model: CatalogueFeedMetadata { CatalogueFeedMetadata(url: url, checksum: checksum, recordCount: recordCount, generatedAt: generatedAt) }
}

struct CatalogueProductDTO: Decodable, Sendable {
    let id: Int64
    let productType: String
    let name: String
    let nameSlug: String
    let slug: String
    let expansionId: Int64?
    let expansionSlug: String?
    let printNumber: String?
    let variant: String?
    let rarity: String?
    let finishes: [String]
    let languages: [String]
    let imageUrl: URL?
    let imageBackUrl: URL?
    let attributes: [String: JSONValue]

    var model: CardPrinting? {
        guard productType == "card" else { return nil }
        return CardPrinting(productID: id, nameSlug: nameSlug, printingSlug: slug, displayName: name, expansionID: expansionId, expansionSlug: expansionSlug, printNumber: printNumber, variant: variant, rarity: rarity, finishes: finishes, languages: languages, imageURL: imageUrl, imageBackURL: imageBackUrl, attributes: attributes)
    }
}

enum CardNexusCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date")
        }
        return decoder
    }
}
