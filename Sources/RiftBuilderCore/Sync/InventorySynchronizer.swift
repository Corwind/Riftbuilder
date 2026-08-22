import Foundation

public struct InventorySyncReport: Hashable, Sendable {
    public let generation: UUID
    public let lineCount: Int
    public let locationCount: Int
    public let completedAt: Date

    public init(generation: UUID, lineCount: Int, locationCount: Int, completedAt: Date) {
        self.generation = generation
        self.lineCount = lineCount
        self.locationCount = locationCount
        self.completedAt = completedAt
    }
}

public actor InventorySynchronizer {
    private let service: any CardNexusServicing
    private let repository: any RiftBuilderRepository
    private let now: @Sendable () -> Date
    private let makeGeneration: @Sendable () -> UUID

    public init(
        service: any CardNexusServicing,
        repository: any RiftBuilderRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        makeGeneration: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.service = service
        self.repository = repository
        self.now = now
        self.makeGeneration = makeGeneration
    }

    @discardableResult
    public func synchronize(game: String = "riftbound") async throws -> InventorySyncReport {
        async let inventoryTask = service.fetchAllInventoryLines(game: game)
        async let locationsTask = service.fetchLocations()
        let (lines, locations) = try await (inventoryTask, locationsTask)
        try Task.checkCancellation()

        let generation = makeGeneration()
        let completedAt = now()
        try await repository.synchronizeInventory(
            lines: lines,
            locations: locations,
            generation: generation,
            completedAt: completedAt
        )

        return InventorySyncReport(
            generation: generation,
            lineCount: lines.count,
            locationCount: locations.count,
            completedAt: completedAt
        )
    }
}
