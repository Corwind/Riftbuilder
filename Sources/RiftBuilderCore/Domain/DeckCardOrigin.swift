import Foundation

public struct DeckCardOriginLot: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let deckID: UUID
    public let nameSlug: String
    public let productID: Int64
    public let finish: String
    public let language: String?
    public let previousLocationKey: String
    public let previousLocationName: String?
    public let quantity: Int
    public let createdAt: Date

    public init(id: UUID = UUID(), deckID: UUID, nameSlug: String, productID: Int64, finish: String, language: String? = nil, previousLocationKey: String, previousLocationName: String?, quantity: Int, createdAt: Date = Date()) {
        self.id = id
        self.deckID = deckID
        self.nameSlug = nameSlug
        self.productID = productID
        self.finish = finish
        self.language = language
        self.previousLocationKey = previousLocationKey
        self.previousLocationName = previousLocationName
        self.quantity = quantity
        self.createdAt = createdAt
    }
}
