import XCTest
@testable import RiftBuilderCore

final class CatalogueChecksumTests: XCTestCase {
    func testChecksumIsNilBeforeImportAndMatchesSuccessfulCatalogueReplacement() async throws {
        let repository = try GRDBRiftBuilderRepository.inMemory()
        let initial = try await repository.catalogueChecksum()
        XCTAssertNil(initial)

        try await repository.replaceCatalogue(printings: [], checksum: "sha256:fixture", completedAt: .now)

        let stored = try await repository.catalogueChecksum()
        XCTAssertEqual(stored, "sha256:fixture")
    }
}
