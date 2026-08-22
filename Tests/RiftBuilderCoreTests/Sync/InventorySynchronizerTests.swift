import Foundation
import XCTest
@testable import RiftBuilderCore

final class InventorySynchronizerTests: XCTestCase {
    func testSynchronizePersistsCompleteRemoteSnapshot() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let generation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let line = InventoryLine(
            inventoryID: "line-1",
            productID: 42,
            finish: "Standard",
            condition: "NM",
            language: "en",
            quantity: 3,
            locationName: "Box A",
            updatedAt: timestamp
        )
        let service = SynchronizerServiceStub(lines: [line], locations: [InventoryLocation(name: "Box A")])
        let repository = SynchronizerRepositorySpy()
        let synchronizer = InventorySynchronizer(
            service: service,
            repository: repository,
            now: { timestamp },
            makeGeneration: { generation }
        )

        let report = try await synchronizer.synchronize()

        XCTAssertEqual(report.generation, generation)
        XCTAssertEqual(report.lineCount, 1)
        XCTAssertEqual(report.locationCount, 1)
        let captured = await repository.capturedInventorySync
        XCTAssertEqual(captured?.lines, [line])
        XCTAssertEqual(captured?.locations.map(\.name), ["Box A"])
        XCTAssertEqual(captured?.generation, generation)
        XCTAssertEqual(captured?.completedAt, timestamp)
    }
}

private actor SynchronizerServiceStub: CardNexusServicing {
    let lines: [InventoryLine]
    let locations: [InventoryLocation]

    init(lines: [InventoryLine], locations: [InventoryLocation]) {
        self.lines = lines
        self.locations = locations
    }

    func verifyCredential() async throws {}
    func fetchAllInventoryLines(game: String) async throws -> [InventoryLine] { lines }
    func fetchLocations() async throws -> [InventoryLocation] { locations }

    func fetchCatalogueMetadata(game: String) async throws -> CatalogueFeedMetadata {
        throw StubError.unimplemented
    }

    func downloadCatalogue(from url: URL) async throws -> AsyncThrowingStream<CardPrinting, any Error> {
        throw StubError.unimplemented
    }
}

private actor SynchronizerRepositorySpy: RiftBuilderRepository {
    struct CapturedSync: Sendable {
        let lines: [InventoryLine]
        let locations: [InventoryLocation]
        let generation: UUID
        let completedAt: Date
    }

    private(set) var capturedInventorySync: CapturedSync?

    func synchronizeInventory(lines: [InventoryLine], locations: [InventoryLocation], generation: UUID, completedAt: Date) async throws {
        capturedInventorySync = CapturedSync(lines: lines, locations: locations, generation: generation, completedAt: completedAt)
    }

    func replaceCatalogue(printings: [CardPrinting], checksum: String, completedAt: Date) async throws {}
    func inventoryCards(search: String?, targetDeckID: UUID?) async throws -> [InventoryCardSummary] { [] }
    func locationPolicies() async throws -> [LocationPolicy] { [] }
    func saveLocationPolicy(_ policy: LocationPolicy) async throws {}
    func decks() async throws -> [Deck] { [] }
    func deckLegendDomains() async throws -> [UUID: [String]] { [:] }
    func deckSnapshot(id: UUID) async throws -> DeckSnapshot? { nil }
    func saveDeck(_ deck: Deck) async throws {}
    func deleteDeck(id: UUID) async throws {}
    func saveDeckEntry(_ entry: DeckEntry) async throws {}
    func deleteDeckEntry(id: UUID) async throws {}
}

private enum StubError: Error {
    case unimplemented
}
