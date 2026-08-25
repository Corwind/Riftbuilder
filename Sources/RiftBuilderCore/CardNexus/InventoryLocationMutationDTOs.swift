import Foundation

struct InventoryLocationUpdateDTO: Encodable, Sendable {
    let name: String
    let color: String?
    let icon: String?
}

struct InventoryLocationDeleteResponseDTO: Decodable, Sendable {
    let deleted: Bool
}
