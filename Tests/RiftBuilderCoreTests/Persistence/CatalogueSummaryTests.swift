import Foundation
import XCTest
@testable import RiftBuilderCore

final class CatalogueSummaryTests: XCTestCase {
    func testEmptyDatabaseReturnsNoCatalogueSummaries() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        let summaries = try await repository.catalogueCards(search: nil)
        XCTAssertTrue(summaries.isEmpty)
    }

    func testUnownedCardsAppearInCatalogue() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [cataloguePrinting(productID: 1, nameSlug: "unowned", displayName: "Unowned Card")],
            checksum: "fixture",
            completedAt: .now
        )

        let summaries = try await repository.catalogueCards(search: nil)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].identity.nameSlug, "unowned")
        XCTAssertEqual(summaries[0].printingCount, 1)
    }

    func testMultiplePrintingsAreGroupedWithDeterministicPreferredImageAndMetadata() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [
                cataloguePrinting(productID: 5, nameSlug: "ahri", displayName: "Ahri", expansion: "zeta", rarity: "Rare"),
                cataloguePrinting(productID: 30, nameSlug: "ahri", displayName: "Ahri", expansion: "alpha", rarity: "Common", image: "https://images.example/30.png"),
                cataloguePrinting(productID: 20, nameSlug: "ahri", displayName: "Ahri", expansion: "alpha", rarity: "Rare", image: "https://images.example/20.png"),
            ],
            checksum: "fixture",
            completedAt: .now
        )

        let summaries = try await repository.catalogueCards(search: nil)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.printingCount, 3)
        XCTAssertEqual(summary.preferredPrinting?.productID, 20)
        XCTAssertEqual(summary.preferredPrinting?.expansionSlug, "alpha")
        XCTAssertEqual(summary.preferredPrinting?.rarity, "Rare")
        XCTAssertEqual(summary.preferredImageURL, URL(string: "https://images.example/20.png"))
        XCTAssertEqual(summary.expansionSlugs, ["alpha", "zeta"])
        XCTAssertEqual(summary.rarities, ["Common", "Rare"])
    }

    func testMultiplePrintingsMergeTheirIdentityTags() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [
                cataloguePrinting(productID: 1, nameSlug: "ahri", displayName: "Ahri", tags: ["Champion", "Ahri"]),
                cataloguePrinting(productID: 2, nameSlug: "ahri", displayName: "Ahri", tags: ["Ionia"]),
                cataloguePrinting(productID: 3, nameSlug: "ahri", displayName: "Ahri"),
            ],
            checksum: "fixture",
            completedAt: .now
        )

        let summaries = try await repository.catalogueCards(search: nil)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.identity.tags, ["Ahri", "Champion", "Ionia"])
    }

    func testPreferredPrintingFallsBackToLowestProductIDWhenNoImageExists() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [
                cataloguePrinting(productID: 9, nameSlug: "zed", displayName: "Zed"),
                cataloguePrinting(productID: 2, nameSlug: "zed", displayName: "Zed"),
            ],
            checksum: "fixture",
            completedAt: .now
        )

        let summaries = try await repository.catalogueCards(search: nil)
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.preferredPrinting?.productID, 2)
        XCTAssertNil(summary.preferredImageURL)
    }

    func testCatalogueSearchMatchesDisplayNameAndSlugAndEscapesWildcards() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        try await repository.replaceCatalogue(
            printings: [
                cataloguePrinting(productID: 1, nameSlug: "ahri-charmer", displayName: "Ahri, Charmer"),
                cataloguePrinting(productID: 2, nameSlug: "zed-master", displayName: "The Master of Shadows"),
            ],
            checksum: "fixture",
            completedAt: .now
        )

        let byName = try await repository.catalogueCards(search: " CHARMer ")
        XCTAssertEqual(byName.map(\.identity.nameSlug), ["ahri-charmer"])
        let bySlug = try await repository.catalogueCards(search: "zed-master")
        XCTAssertEqual(bySlug.map(\.identity.nameSlug), ["zed-master"])
        let wildcard = try await repository.catalogueCards(search: "%")
        XCTAssertTrue(wildcard.isEmpty)
    }
}

private func cataloguePrinting(
    productID: Int64,
    nameSlug: String,
    displayName: String,
    expansion: String? = nil,
    rarity: String? = nil,
    image: String? = nil,
    tags: [String] = []
) -> CardPrinting {
    CardPrinting(
        productID: productID,
        nameSlug: nameSlug,
        printingSlug: "\(nameSlug)-\(productID)",
        displayName: displayName,
        expansionSlug: expansion,
        rarity: rarity,
        imageURL: image.flatMap(URL.init(string:)),
        attributes: ["tags": .array(tags.map { .string($0) })]
    )
}
