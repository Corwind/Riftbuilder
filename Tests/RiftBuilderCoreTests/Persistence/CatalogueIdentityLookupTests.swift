import XCTest
@testable import RiftBuilderCore

final class CatalogueIdentityLookupTests: XCTestCase {
    func testTargetedLookupFindsOwnedAndUnownedCatalogueCards() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [
                lookupPrinting(productID: 1, nameSlug: "owned", displayName: "Owned Card"),
                lookupPrinting(productID: 2, nameSlug: "unowned", displayName: "Unowned Card"),
            ],
            checksum: "fixture",
            completedAt: .now
        )

        let none = try await repository.cardIdentities(nameSlugs: [])
        XCTAssertTrue(none.isEmpty)
        let found = try await repository.cardIdentities(nameSlugs: ["unowned", "missing"])
        XCTAssertEqual(Set(found.keys), ["unowned"])
        XCTAssertEqual(found["unowned"]?.displayName, "Unowned Card")
    }

    func testSearchableCatalogueReturnsAllIdentitiesInStableDisplayOrder() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [
                lookupPrinting(productID: 1, nameSlug: "zed", displayName: "Zed"),
                lookupPrinting(productID: 2, nameSlug: "ahri-charmer", displayName: "Ahri, Charmer"),
                lookupPrinting(productID: 3, nameSlug: "ahri-legend", displayName: "Ahri, Nine-Tailed"),
            ],
            checksum: "fixture",
            completedAt: .now
        )

        let all = try await repository.catalogueIdentities(search: nil)
        XCTAssertEqual(all.map(\.displayName), ["Ahri, Charmer", "Ahri, Nine-Tailed", "Zed"])
        let filtered = try await repository.catalogueIdentities(search: "AHRI_")
        XCTAssertTrue(filtered.isEmpty, "Search wildcard characters must be treated literally")
        let matching = try await repository.catalogueIdentities(search: " ahri ")
        XCTAssertEqual(matching.map(\.nameSlug), ["ahri-charmer", "ahri-legend"])
    }
}

private func lookupPrinting(productID: Int64, nameSlug: String, displayName: String) -> CardPrinting {
    CardPrinting(
        productID: productID,
        nameSlug: nameSlug,
        printingSlug: "\(nameSlug)-printing",
        displayName: displayName
    )
}
