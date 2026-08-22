import Foundation

struct InventoryLocationUpsertDTO: Encodable, Sendable {
    let name: String
    let color: String?
    let icon: String?
    let upsert = true
}
