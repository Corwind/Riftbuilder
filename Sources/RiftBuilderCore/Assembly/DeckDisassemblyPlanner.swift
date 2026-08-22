import Foundation

public struct DisassemblyPlanRequest: Sendable {
    public let planID: UUID
    public let deckID: UUID
    public let inventory: AssemblyInventorySnapshot
    public let sourceDeckLocationName: String
    public let destinationStorageLocationName: String?
    public let removalDestinations: [DeckRemovalDestination]
    public let originLots: [DeckCardOriginLot]

    public init(planID: UUID = UUID(), deckID: UUID, inventory: AssemblyInventorySnapshot, sourceDeckLocationName: String, destinationStorageLocationName: String? = nil, removalDestinations: [DeckRemovalDestination] = [], originLots: [DeckCardOriginLot] = []) {
        self.planID = planID
        self.deckID = deckID
        self.inventory = inventory
        self.sourceDeckLocationName = sourceDeckLocationName
        self.destinationStorageLocationName = destinationStorageLocationName
        self.removalDestinations = removalDestinations
        self.originLots = originLots
    }
}

public struct DisassemblyPlan: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID { planID }
    public let planID: UUID
    public let deckID: UUID
    public let sourceDeckLocationName: String
    public let destinationStorageLocationName: String
    public let movements: [PlannedInventoryMovement]
    public let returnRoutes: [DeckReturnRoute]
    public let unresolvedReturnRoutes: [DeckReturnRouteKey]

    public init(planID: UUID, deckID: UUID, sourceDeckLocationName: String, destinationStorageLocationName: String, movements: [PlannedInventoryMovement], returnRoutes: [DeckReturnRoute] = [], unresolvedReturnRoutes: [DeckReturnRouteKey] = []) {
        self.planID = planID
        self.deckID = deckID
        self.sourceDeckLocationName = sourceDeckLocationName
        self.destinationStorageLocationName = destinationStorageLocationName
        self.movements = movements
        self.returnRoutes = returnRoutes
        self.unresolvedReturnRoutes = unresolvedReturnRoutes
    }

    public var canApply: Bool { unresolvedReturnRoutes.isEmpty }

    var executablePlan: AssemblyPlan {
        AssemblyPlan(
            planID: planID,
            deckID: deckID,
            destinationLocationName: destinationStorageLocationName,
            movements: movements,
            requirements: []
        )
    }
}

public enum DisassemblyPlanningError: Error, Hashable, Sendable {
    case emptySourceLocation
    case emptyDestinationLocation
    case sourceLocationNotLinkedToDeck(String, UUID)
    case destinationIsNotStorage(String)
    case sourceAndDestinationAreTheSame
}

extension DisassemblyPlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptySourceLocation: return "A linked CardNexus deck location is required for disassembly."
        case .emptyDestinationLocation: return "Choose a CardNexus storage location before disassembly."
        case let .sourceLocationNotLinkedToDeck(name, deckID): return "The location '\(name)' is not linked to deck \(deckID.uuidString)."
        case let .destinationIsNotStorage(name): return "The destination '\(name)' is not classified as storage."
        case .sourceAndDestinationAreTheSame: return "The disassembly destination must differ from the deck location."
        }
    }
}

/// Moves every synchronized physical line in a deck-linked location back to its
/// remembered source storage by default. Every route remains overridable, while
/// inventory without provenance requires an explicit fallback destination.
public struct DeckDisassemblyPlanner: Sendable {
    public init() {}

    public func makePlan(_ request: DisassemblyPlanRequest) throws -> DisassemblyPlan {
        let source = request.sourceDeckLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDestination = request.destinationStorageLocationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw DisassemblyPlanningError.emptySourceLocation }
        let sourceKey = InventoryLocation.normalize(source)

        var policies: [String: LocationPolicy] = [:]
        for policy in request.inventory.locationPolicies { policies[policy.normalizedName] = policy }
        guard let sourcePolicy = policies[sourceKey], sourcePolicy.kind == .deck, sourcePolicy.linkedDeckID == request.deckID else {
            throw DisassemblyPlanningError.sourceLocationNotLinkedToDeck(source, request.deckID)
        }
        if let fallbackDestination, !fallbackDestination.isEmpty {
            try validate(destination: fallbackDestination, policies: policies, sourceKey: sourceKey)
        }

        let overrides = request.removalDestinations.reduce(into: [DeckReturnRouteKey: String]()) { result, destination in
            result[DeckReturnRouteKey(requirement: destination.requirement, originLotID: destination.originLotID)] = destination.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var origins = request.originLots.filter { $0.deckID == request.deckID && $0.quantity > 0 }.map(OriginLot.init)
        var routes: [DeckReturnRouteKey: RouteAllocation] = [:]
        var allocations: [MovementKey: Int] = [:]
        let lines = request.inventory.lines.filter {
            $0.quantity > 0 && InventoryLocation.normalize($0.locationName) == sourceKey && request.inventory.printingsByProductID[$0.productID] != nil
        }.sorted(by: Self.lineLessThan)

        for line in lines {
            guard let printing = request.inventory.printingsByProductID[line.productID] else { continue }
            let requirement = DeckPhysicalRequirementKey(
                nameSlug: printing.nameSlug,
                preference: PrintingPreference(productID: line.productID, finish: line.finish, language: line.language)
            )
            var remaining = line.quantity
            let matchingOrigins = origins.indices.filter {
                origins[$0].remaining > 0 && Self.origin(origins[$0].lot, matches: line, nameSlug: printing.nameSlug)
            }.sorted { Self.originLessThan(origins[$0].lot, origins[$1].lot) }
            for originIndex in matchingOrigins where remaining > 0 {
                let quantity = min(remaining, origins[originIndex].remaining)
                origins[originIndex].remaining -= quantity
                remaining -= quantity
                let remembered = origins[originIndex].lot
                let route = DeckReturnRouteKey(requirement: requirement, originLotID: remembered.id)
                let destination = try destination(
                    for: route,
                    origin: remembered,
                    fallback: fallbackDestination,
                    overrides: overrides,
                    policies: policies,
                    sourceKey: sourceKey
                )
                addRoute(route, quantity: quantity, previousLocationName: remembered.previousLocationName, destination: destination, to: &routes)
                if let destination {
                    allocations[MovementKey(line: line, nameSlug: printing.nameSlug, destination: destination, originLotID: remembered.id), default: 0] += quantity
                }
            }
            if remaining > 0 {
                let route = DeckReturnRouteKey(requirement: requirement, originLotID: nil)
                let destination = try destination(for: route, origin: nil, fallback: fallbackDestination, overrides: overrides, policies: policies, sourceKey: sourceKey)
                addRoute(route, quantity: remaining, previousLocationName: nil, destination: destination, to: &routes)
                if let destination {
                    allocations[MovementKey(line: line, nameSlug: printing.nameSlug, destination: destination, originLotID: nil), default: 0] += remaining
                }
            }
        }

        let sortedAllocations = allocations.sorted(by: Self.movementLessThan)
        let movements = sortedAllocations.enumerated().map { index, allocation in
            PlannedInventoryMovement(
                operationID: "\(request.planID.uuidString.lowercased()):disband:\(index)",
                inventoryID: allocation.key.inventoryID,
                productID: allocation.key.productID,
                nameSlug: allocation.key.nameSlug,
                quantity: allocation.value,
                sourceLocationName: allocation.key.sourceLocationName,
                destinationLocationName: allocation.key.destination,
                finish: allocation.key.finish,
                language: allocation.key.language,
                originLotID: allocation.key.originLotID
            )
        }
        let returnRoutes = routes.values.sorted(by: Self.routeLessThan).map {
            DeckReturnRoute(key: $0.key, quantity: $0.quantity, previousLocationName: $0.previousLocationName, destinationLocationName: $0.destination)
        }
        let unresolved = returnRoutes.filter { $0.destinationLocationName == nil }.map(\.key)
        let destinations = Set(movements.map(\.destinationLocationName))
        let destinationSummary = destinations.count == 1 ? (destinations.first ?? "") : "Multiple storage locations"

        return DisassemblyPlan(
            planID: request.planID,
            deckID: request.deckID,
            sourceDeckLocationName: source,
            destinationStorageLocationName: destinationSummary,
            movements: movements,
            returnRoutes: returnRoutes,
            unresolvedReturnRoutes: unresolved
        )
    }
}

private extension DeckDisassemblyPlanner {
    struct OriginLot {
        let lot: DeckCardOriginLot
        var remaining: Int
        init(_ lot: DeckCardOriginLot) { self.lot = lot; remaining = lot.quantity }
    }

    struct RouteAllocation {
        let key: DeckReturnRouteKey
        var quantity: Int
        let previousLocationName: String?
        let destination: String?
    }

    struct MovementKey: Hashable {
        let inventoryID: String
        let productID: Int64
        let nameSlug: String
        let sourceLocationName: String?
        let destination: String
        let finish: String?
        let language: String?
        let originLotID: UUID?

        init(line: InventoryLine, nameSlug: String, destination: String, originLotID: UUID?) {
            inventoryID = line.inventoryID
            productID = line.productID
            self.nameSlug = nameSlug
            sourceLocationName = line.locationName
            self.destination = destination
            finish = line.finish
            language = line.language
            self.originLotID = originLotID
        }
    }

    func validate(destination: String, policies: [String: LocationPolicy], sourceKey: String) throws {
        let key = InventoryLocation.normalize(destination)
        guard key != sourceKey else { throw DisassemblyPlanningError.sourceAndDestinationAreTheSame }
        guard let policy = policies[key], policy.kind == .storage, policy.countsAsAvailable else {
            throw DisassemblyPlanningError.destinationIsNotStorage(destination)
        }
    }

    func destination(for route: DeckReturnRouteKey, origin: DeckCardOriginLot?, fallback: String?, overrides: [DeckReturnRouteKey: String], policies: [String: LocationPolicy], sourceKey: String) throws -> String? {
        if let override = overrides[route], !override.isEmpty {
            try validate(destination: override, policies: policies, sourceKey: sourceKey)
            return policies[InventoryLocation.normalize(override)]?.displayName
        }
        if let origin, origin.previousLocationKey != sourceKey,
           let policy = policies[origin.previousLocationKey], policy.kind == .storage, policy.countsAsAvailable {
            return policy.displayName
        }
        if let fallback, !fallback.isEmpty {
            try validate(destination: fallback, policies: policies, sourceKey: sourceKey)
            return policies[InventoryLocation.normalize(fallback)]?.displayName
        }
        return nil
    }

    func addRoute(_ key: DeckReturnRouteKey, quantity: Int, previousLocationName: String?, destination: String?, to routes: inout [DeckReturnRouteKey: RouteAllocation]) {
        if var existing = routes[key] {
            existing.quantity += quantity
            routes[key] = existing
        } else {
            routes[key] = RouteAllocation(key: key, quantity: quantity, previousLocationName: previousLocationName, destination: destination)
        }
    }

    static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func origin(_ origin: DeckCardOriginLot, matches line: InventoryLine, nameSlug: String) -> Bool {
        origin.nameSlug == nameSlug && origin.productID == line.productID && normalized(origin.finish) == normalized(line.finish) && normalized(origin.language) == normalized(line.language)
    }

    static func originLessThan(_ lhs: DeckCardOriginLot, _ rhs: DeckCardOriginLot) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.previousLocationKey != rhs.previousLocationKey { return lhs.previousLocationKey < rhs.previousLocationKey }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func lineLessThan(_ lhs: InventoryLine, _ rhs: InventoryLine) -> Bool {
        if lhs.productID != rhs.productID { return lhs.productID < rhs.productID }
        if normalized(lhs.finish) != normalized(rhs.finish) { return normalized(lhs.finish) < normalized(rhs.finish) }
        if normalized(lhs.language) != normalized(rhs.language) { return normalized(lhs.language) < normalized(rhs.language) }
        return lhs.inventoryID < rhs.inventoryID
    }

    static func movementLessThan(_ lhs: (key: MovementKey, value: Int), _ rhs: (key: MovementKey, value: Int)) -> Bool {
        if lhs.key.nameSlug != rhs.key.nameSlug { return lhs.key.nameSlug < rhs.key.nameSlug }
        if lhs.key.productID != rhs.key.productID { return lhs.key.productID < rhs.key.productID }
        if lhs.key.destination != rhs.key.destination { return lhs.key.destination < rhs.key.destination }
        if lhs.key.inventoryID != rhs.key.inventoryID { return lhs.key.inventoryID < rhs.key.inventoryID }
        return (lhs.key.originLotID?.uuidString ?? "") < (rhs.key.originLotID?.uuidString ?? "")
    }

    static func routeLessThan(_ lhs: RouteAllocation, _ rhs: RouteAllocation) -> Bool {
        if lhs.key.requirement.nameSlug != rhs.key.requirement.nameSlug { return lhs.key.requirement.nameSlug < rhs.key.requirement.nameSlug }
        return (lhs.key.originLotID?.uuidString ?? "") < (rhs.key.originLotID?.uuidString ?? "")
    }
}
