import Foundation

public enum DeckSavePlanningError: Error, Hashable, Sendable {
    case deckMismatch
    case emptyDeckLocation
    case deckLocationNotLinked(String, UUID)
    case removalDestinationNotAvailableStorage(String)
    case removalDestinationIsDeckLocation(String)
}

extension DeckSavePlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deckMismatch: return "The saved deck and its draft do not identify the same deck."
        case .emptyDeckLocation: return "The deck needs a linked CardNexus location before its changes can be saved."
        case let .deckLocationNotLinked(name, deckID): return "The location '\(name)' is not linked to deck \(deckID.uuidString)."
        case let .removalDestinationNotAvailableStorage(name): return "The removal destination '\(name)' is not an available storage location."
        case let .removalDestinationIsDeckLocation(name): return "The removal destination '\(name)' is the deck's own location."
        }
    }
}

/// Reconciles the physically saved definition with its persisted editing draft.
/// It proposes line-level moves but never mutates either local or remote state.
public struct DeckSavePlanner: Sendable {
    public init() {}

    public func makePlan(_ request: DeckSavePlanRequest) throws -> DeckSavePlan {
        let deckID = request.savedDeck.deck.id
        guard request.draft.deck.id == deckID else { throw DeckSavePlanningError.deckMismatch }
        let deckLocation = request.deckLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deckLocation.isEmpty else { throw DeckSavePlanningError.emptyDeckLocation }
        let deckLocationKey = InventoryLocation.normalize(deckLocation)
        let policies = Dictionary(uniqueKeysWithValues: request.inventory.locationPolicies.map { ($0.normalizedName, $0) })
        guard let deckPolicy = policies[deckLocationKey], deckPolicy.kind == .deck, deckPolicy.linkedDeckID == deckID else {
            throw DeckSavePlanningError.deckLocationNotLinked(deckLocation, deckID)
        }

        let savedQuantities = Self.physicalQuantities(request.savedDeck.entries, availability: request.inventoryAvailability)
        let draftQuantities = Self.physicalQuantities(request.draft.entries, availability: request.inventoryAvailability)
        let changedRequirements = Set(savedQuantities.keys).union(draftQuantities.keys).filter {
            savedQuantities[$0, default: 0] != draftQuantities[$0, default: 0]
        }.sorted(by: Self.requirementLessThan)
        let destinations = request.removalDestinations.reduce(into: [DeckReturnRouteKey: String]()) { result, destination in
            result[DeckReturnRouteKey(requirement: destination.requirement, originLotID: destination.originLotID)] = destination.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var storageLots: [Lot] = []
        var deckLots: [Lot] = []
        for line in request.inventory.lines where line.quantity > 0 {
            guard let printing = request.inventory.printingsByProductID[line.productID] else { continue }
            let lot = Lot(line: line, nameSlug: printing.nameSlug, remaining: line.quantity)
            let locationKey = InventoryLocation.normalize(line.locationName)
            if locationKey == deckLocationKey {
                deckLots.append(lot)
            } else if let policy = policies[locationKey], policy.kind == .storage, policy.countsAsAvailable {
                storageLots.append(lot)
            }
        }

        var allocations: [MovementAllocationKey: Int] = [:]
        var originLots = request.originLots.filter { $0.deckID == deckID && $0.quantity > 0 }.map(OriginLot.init)
        var routeAllocations: [DeckReturnRouteKey: ReturnRouteAllocation] = [:]
        var results: [DeckSaveRequirementResult] = []
        for requirement in changedRequirements {
            let change = draftQuantities[requirement, default: 0] - savedQuantities[requirement, default: 0]
            if change > 0 {
                var remaining = change
                let allocated = consume(requirement: requirement, requested: &remaining, lots: &storageLots) { line in
                    MovementAllocationKey(direction: .intoDeck, inventoryID: line.inventoryID, destinationLocationName: deckLocation)
                } allocations: { key, quantity in
                    allocations[key, default: 0] += quantity
                }
                results.append(DeckSaveRequirementResult(requirement: requirement, direction: .intoDeck, requested: change, allocated: allocated, missing: remaining, destinationLocationName: deckLocation))
            } else {
                let requested = -change
                var remaining = requested
                let candidates = deckLots.indices.filter { deckLots[$0].remaining > 0 && deckLots[$0].nameSlug == requirement.nameSlug }.sorted {
                    lotLessThan(deckLots[$0], deckLots[$1], preference: requirement.preference)
                }
                var allocated = 0
                for deckLotIndex in candidates where remaining > 0 {
                    let quantity = min(remaining, deckLots[deckLotIndex].remaining)
                    let line = deckLots[deckLotIndex].line
                    deckLots[deckLotIndex].remaining -= quantity
                    remaining -= quantity
                    allocated += quantity

                    var lineQuantityRemaining = quantity
                    let matchingOrigins = originLots.indices.filter {
                        originLots[$0].remaining > 0 && Self.origin(originLots[$0].lot, matches: line, nameSlug: requirement.nameSlug)
                    }.sorted { Self.originLessThan(originLots[$0].lot, originLots[$1].lot) }
                    for originIndex in matchingOrigins where lineQuantityRemaining > 0 {
                        let originQuantity = min(lineQuantityRemaining, originLots[originIndex].remaining)
                        originLots[originIndex].remaining -= originQuantity
                        lineQuantityRemaining -= originQuantity
                        let origin = originLots[originIndex].lot
                        let routeKey = DeckReturnRouteKey(requirement: requirement, originLotID: origin.id)
                        let destination = try returnDestination(
                            route: routeKey,
                            origin: origin,
                            overrides: destinations,
                            policies: policies,
                            deckLocationKey: deckLocationKey
                        )
                        addRoute(routeKey, quantity: originQuantity, previousLocationName: origin.previousLocationName, destinationLocationName: destination, to: &routeAllocations)
                        if let destination {
                            allocations[MovementAllocationKey(direction: .outOfDeck, inventoryID: line.inventoryID, destinationLocationName: destination, originLotID: origin.id), default: 0] += originQuantity
                        }
                    }

                    if lineQuantityRemaining > 0 {
                        let routeKey = DeckReturnRouteKey(requirement: requirement, originLotID: nil)
                        let destination = try returnDestination(
                            route: routeKey,
                            origin: nil,
                            overrides: destinations,
                            policies: policies,
                            deckLocationKey: deckLocationKey
                        )
                        addRoute(routeKey, quantity: lineQuantityRemaining, previousLocationName: nil, destinationLocationName: destination, to: &routeAllocations)
                        if let destination {
                            allocations[MovementAllocationKey(direction: .outOfDeck, inventoryID: line.inventoryID, destinationLocationName: destination, originLotID: nil), default: 0] += lineQuantityRemaining
                        }
                    }
                }
                let requirementDestinations = Set(routeAllocations.values.filter { $0.key.requirement == requirement }.compactMap(\.destinationLocationName))
                results.append(DeckSaveRequirementResult(
                    requirement: requirement,
                    direction: .outOfDeck,
                    requested: requested,
                    allocated: allocated,
                    missing: remaining,
                    destinationLocationName: requirementDestinations.count == 1 ? requirementDestinations.first : nil
                ))
            }
        }

        let linesByID = Dictionary(uniqueKeysWithValues: request.inventory.lines.map { ($0.inventoryID, $0) })
        let sortedAllocations = allocations.sorted { lhs, rhs in
            if lhs.key.direction != rhs.key.direction { return lhs.key.direction.rawValue < rhs.key.direction.rawValue }
            let leftSource = InventoryLocation.normalize(linesByID[lhs.key.inventoryID]?.locationName)
            let rightSource = InventoryLocation.normalize(linesByID[rhs.key.inventoryID]?.locationName)
            if leftSource != rightSource { return leftSource < rightSource }
            if lhs.key.destinationLocationName != rhs.key.destinationLocationName { return lhs.key.destinationLocationName < rhs.key.destinationLocationName }
            if lhs.key.inventoryID != rhs.key.inventoryID { return lhs.key.inventoryID < rhs.key.inventoryID }
            return (lhs.key.originLotID?.uuidString ?? "") < (rhs.key.originLotID?.uuidString ?? "")
        }
        let movements = sortedAllocations.enumerated().compactMap { index, allocation -> PlannedInventoryMovement? in
            guard let line = linesByID[allocation.key.inventoryID], let printing = request.inventory.printingsByProductID[line.productID] else { return nil }
            return PlannedInventoryMovement(
                operationID: "\(request.planID.uuidString.lowercased()):save:\(index)",
                inventoryID: line.inventoryID,
                productID: line.productID,
                nameSlug: printing.nameSlug,
                quantity: allocation.value,
                sourceLocationName: line.locationName,
                destinationLocationName: allocation.key.destinationLocationName,
                finish: line.finish,
                language: line.language,
                originLotID: allocation.key.originLotID
            )
        }

        let returnRoutes = routeAllocations.values.sorted(by: Self.returnRouteLessThan).map {
            DeckReturnRoute(key: $0.key, quantity: $0.quantity, previousLocationName: $0.previousLocationName, destinationLocationName: $0.destinationLocationName)
        }
        let unresolvedRoutes = returnRoutes.filter { $0.destinationLocationName == nil }.map(\.key)
        let unresolvedRequirements = Array(Set(unresolvedRoutes.map(\.requirement))).sorted(by: Self.requirementLessThan)

        return DeckSavePlan(
            planID: request.planID,
            deckID: deckID,
            deckLocationName: deckLocation,
            movements: movements,
            requirements: results,
            unresolvedRemovalDestinations: unresolvedRequirements,
            returnRoutes: returnRoutes,
            unresolvedReturnRoutes: unresolvedRoutes
        )
    }
}

private extension DeckSavePlanner {
    struct Lot {
        let line: InventoryLine
        let nameSlug: String
        var remaining: Int
    }

    struct MovementAllocationKey: Hashable {
        let direction: DeckSaveMovementDirection
        let inventoryID: String
        let destinationLocationName: String
        let originLotID: UUID?

        init(direction: DeckSaveMovementDirection, inventoryID: String, destinationLocationName: String, originLotID: UUID? = nil) {
            self.direction = direction
            self.inventoryID = inventoryID
            self.destinationLocationName = destinationLocationName
            self.originLotID = originLotID
        }
    }

    struct OriginLot {
        let lot: DeckCardOriginLot
        var remaining: Int

        init(_ lot: DeckCardOriginLot) {
            self.lot = lot
            remaining = lot.quantity
        }
    }

    struct ReturnRouteAllocation {
        let key: DeckReturnRouteKey
        var quantity: Int
        let previousLocationName: String?
        let destinationLocationName: String?
    }

    static func physicalQuantities(_ entries: [DeckEntry], availability: DeckInventoryAvailability) -> [DeckPhysicalRequirementKey: Int] {
        entries.reduce(into: [:]) { result, entry in
            guard entry.quantity > 0, !availability.isAlwaysAvailable(entry.zone) else { return }
            result[DeckPhysicalRequirementKey(entry: entry), default: 0] += entry.quantity
        }
    }

    static func requirementLessThan(_ lhs: DeckPhysicalRequirementKey, _ rhs: DeckPhysicalRequirementKey) -> Bool {
        if lhs.preference.isExplicit != rhs.preference.isExplicit { return lhs.preference.isExplicit }
        if lhs.nameSlug != rhs.nameSlug { return lhs.nameSlug < rhs.nameSlug }
        if lhs.preference.productID != rhs.preference.productID { return (lhs.preference.productID ?? Int64.max) < (rhs.preference.productID ?? Int64.max) }
        if normalized(lhs.preference.finish) != normalized(rhs.preference.finish) { return normalized(lhs.preference.finish) < normalized(rhs.preference.finish) }
        return normalized(lhs.preference.language) < normalized(rhs.preference.language)
    }

    func consume(requirement: DeckPhysicalRequirementKey, requested: inout Int, lots: inout [Lot], allocationKey: (InventoryLine) -> MovementAllocationKey, allocations: (MovementAllocationKey, Int) -> Void) -> Int {
        let candidates = lots.indices.filter { lots[$0].remaining > 0 && lots[$0].nameSlug == requirement.nameSlug }.sorted {
            lotLessThan(lots[$0], lots[$1], preference: requirement.preference)
        }
        var consumed = 0
        for index in candidates where requested > 0 {
            let quantity = min(requested, lots[index].remaining)
            lots[index].remaining -= quantity
            requested -= quantity
            consumed += quantity
            allocations(allocationKey(lots[index].line), quantity)
        }
        return consumed
    }

    func lotLessThan(_ lhs: Lot, _ rhs: Lot, preference: PrintingPreference) -> Bool {
        let leftRank = preferenceRank(lhs.line, preference: preference)
        let rightRank = preferenceRank(rhs.line, preference: preference)
        if leftRank != rightRank { return leftRank.lexicographicallyPrecedes(rightRank) }
        let leftLocation = InventoryLocation.normalize(lhs.line.locationName)
        let rightLocation = InventoryLocation.normalize(rhs.line.locationName)
        if leftLocation != rightLocation { return leftLocation < rightLocation }
        if lhs.line.productID != rhs.line.productID { return lhs.line.productID < rhs.line.productID }
        if Self.normalized(lhs.line.finish) != Self.normalized(rhs.line.finish) { return Self.normalized(lhs.line.finish) < Self.normalized(rhs.line.finish) }
        if Self.normalized(lhs.line.language) != Self.normalized(rhs.line.language) { return Self.normalized(lhs.line.language) < Self.normalized(rhs.line.language) }
        return lhs.line.inventoryID < rhs.line.inventoryID
    }

    func preferenceRank(_ line: InventoryLine, preference: PrintingPreference) -> [Int] {
        [
            preference.productID.map { $0 == line.productID ? 0 : 1 } ?? 0,
            preference.finish.map { Self.normalized($0) == Self.normalized(line.finish) ? 0 : 1 } ?? 0,
            preference.language.map { Self.normalized($0) == Self.normalized(line.language) ? 0 : 1 } ?? 0,
        ]
    }

    static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func origin(_ origin: DeckCardOriginLot, matches line: InventoryLine, nameSlug: String) -> Bool {
        origin.nameSlug == nameSlug
            && origin.productID == line.productID
            && normalized(origin.finish) == normalized(line.finish)
            && normalized(origin.language) == normalized(line.language)
    }

    static func originLessThan(_ lhs: DeckCardOriginLot, _ rhs: DeckCardOriginLot) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.previousLocationKey != rhs.previousLocationKey { return lhs.previousLocationKey < rhs.previousLocationKey }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    func returnDestination(route: DeckReturnRouteKey, origin: DeckCardOriginLot?, overrides: [DeckReturnRouteKey: String], policies: [String: LocationPolicy], deckLocationKey: String) throws -> String? {
        if let override = overrides[route], !override.isEmpty {
            let key = InventoryLocation.normalize(override)
            guard key != deckLocationKey else { throw DeckSavePlanningError.removalDestinationIsDeckLocation(override) }
            guard let policy = policies[key], policy.kind == .storage, policy.countsAsAvailable else {
                throw DeckSavePlanningError.removalDestinationNotAvailableStorage(override)
            }
            return policy.displayName
        }
        guard let origin, origin.previousLocationKey != deckLocationKey,
              let policy = policies[origin.previousLocationKey], policy.kind == .storage, policy.countsAsAvailable
        else { return nil }
        return policy.displayName
    }

    func addRoute(_ key: DeckReturnRouteKey, quantity: Int, previousLocationName: String?, destinationLocationName: String?, to routes: inout [DeckReturnRouteKey: ReturnRouteAllocation]) {
        guard quantity > 0 else { return }
        if var existing = routes[key] {
            existing.quantity += quantity
            routes[key] = existing
        } else {
            routes[key] = ReturnRouteAllocation(key: key, quantity: quantity, previousLocationName: previousLocationName, destinationLocationName: destinationLocationName)
        }
    }

    static func returnRouteLessThan(_ lhs: ReturnRouteAllocation, _ rhs: ReturnRouteAllocation) -> Bool {
        if requirementLessThan(lhs.key.requirement, rhs.key.requirement) { return true }
        if requirementLessThan(rhs.key.requirement, lhs.key.requirement) { return false }
        return (lhs.key.originLotID?.uuidString ?? "") < (rhs.key.originLotID?.uuidString ?? "")
    }
}
