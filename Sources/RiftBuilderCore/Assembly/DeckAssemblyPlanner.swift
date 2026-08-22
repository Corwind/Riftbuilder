import Foundation

public enum AssemblyPlanningError: Error, Hashable, Sendable {
    case emptyDestinationLocation
    case destinationLocationNotFound(String)
    case destinationLocationNotLinkedToDeck(String, UUID)
}

extension AssemblyPlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyDestinationLocation:
            return "A CardNexus deck location is required before assembly."
        case let .destinationLocationNotFound(name):
            return "The CardNexus location '\(name)' is not present in the synchronized location list."
        case let .destinationLocationNotLinkedToDeck(name, deckID):
            return "The location '\(name)' is not classified as the deck location for \(deckID.uuidString)."
        }
    }
}

/// Produces a deterministic proposal without mutating local or remote state.
/// Explicit printing preferences are allocated before generic requirements, and
/// are soft preferences: a different printing is used rather than reported
/// missing when an otherwise eligible copy exists.
public struct DeckAssemblyPlanner: Sendable {
    public init() {}

    public func makePlan(_ request: AssemblyPlanRequest) throws -> AssemblyPlan {
        let destination = request.destinationLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { throw AssemblyPlanningError.emptyDestinationLocation }
        let destinationKey = InventoryLocation.normalize(destination)

        var policies: [String: LocationPolicy] = [:]
        for policy in request.inventory.locationPolicies {
            policies[policy.normalizedName] = policy
        }
        guard let destinationPolicy = policies[destinationKey] else {
            throw AssemblyPlanningError.destinationLocationNotFound(destination)
        }
        guard destinationPolicy.kind == .deck, destinationPolicy.linkedDeckID == request.deck.deck.id else {
            throw AssemblyPlanningError.destinationLocationNotLinkedToDeck(destination, request.deck.deck.id)
        }

        var quantitiesByRequirement: [RequirementKey: Int] = [:]
        // Runes are unlimited game components rather than owned physical stock.
        // They remain in the snapshot for legality validation, but assembly must
        // never allocate inventory, report shortages, or move lines for them.
        for entry in request.deck.entries where entry.quantity > 0 && entry.zone != .rune {
            let key = RequirementKey(
                nameSlug: entry.nameSlug,
                preference: PrintingPreference(
                    productID: entry.preferredProductID,
                    finish: entry.preferredFinish,
                    language: entry.preferredLanguage
                )
            )
            quantitiesByRequirement[key, default: 0] += entry.quantity
        }
        let requirements = quantitiesByRequirement.keys.sorted(by: RequirementKey.lessThan)

        var destinationLots: [Lot] = []
        var storageLots: [Lot] = []
        for line in request.inventory.lines where line.quantity > 0 {
            guard let printing = request.inventory.printingsByProductID[line.productID] else { continue }
            let lot = Lot(line: line, nameSlug: printing.nameSlug, remaining: line.quantity)
            let locationKey = InventoryLocation.normalize(line.locationName)
            if locationKey == destinationKey {
                destinationLots.append(lot)
            } else if let policy = policies[locationKey], policy.kind == .storage, policy.countsAsAvailable {
                storageLots.append(lot)
            }
        }

        var allocatedByInventoryID: [String: Int] = [:]
        var ignoredDestinationAllocations: [String: Int] = [:]
        var requirementResults: [AssemblyRequirementResult] = []
        for requirement in requirements {
            let required = quantitiesByRequirement[requirement, default: 0]
            var remaining = required
            let alreadyThere = consume(
                requirement: requirement,
                requested: &remaining,
                lots: &destinationLots,
                allocations: &ignoredDestinationAllocations,
                recordsAllocations: false
            )
            let allocated = consume(
                requirement: requirement,
                requested: &remaining,
                lots: &storageLots,
                allocations: &allocatedByInventoryID,
                recordsAllocations: true
            )
            requirementResults.append(AssemblyRequirementResult(
                nameSlug: requirement.nameSlug,
                preference: requirement.preference,
                required: required,
                alreadyAtDestination: alreadyThere,
                allocatedFromStorage: allocated,
                missing: remaining
            ))
        }

        var linesByID: [String: InventoryLine] = [:]
        for line in request.inventory.lines { linesByID[line.inventoryID] = line }
        let movements = allocatedByInventoryID.compactMap { inventoryID, quantity -> PlannedInventoryMovement? in
            guard let line = linesByID[inventoryID],
                  let printing = request.inventory.printingsByProductID[line.productID]
            else { return nil }
            return PlannedInventoryMovement(
                operationID: "\(request.planID.uuidString.lowercased()):\(inventoryID)",
                inventoryID: inventoryID,
                productID: line.productID,
                nameSlug: printing.nameSlug,
                quantity: quantity,
                sourceLocationName: line.locationName,
                destinationLocationName: destination,
                finish: line.finish,
                language: line.language
            )
        }.sorted(by: Self.movementLessThan)

        return AssemblyPlan(
            planID: request.planID,
            deckID: request.deck.deck.id,
            destinationLocationName: destination,
            movements: movements,
            requirements: requirementResults
        )
    }
}

private extension DeckAssemblyPlanner {
    struct RequirementKey: Hashable {
        let nameSlug: String
        let preference: PrintingPreference

        static func lessThan(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.preference.isExplicit != rhs.preference.isExplicit { return lhs.preference.isExplicit }
            if lhs.nameSlug != rhs.nameSlug { return lhs.nameSlug < rhs.nameSlug }
            if lhs.preference.productID != rhs.preference.productID {
                return (lhs.preference.productID ?? Int64.max) < (rhs.preference.productID ?? Int64.max)
            }
            if normalized(lhs.preference.finish) != normalized(rhs.preference.finish) {
                return normalized(lhs.preference.finish) < normalized(rhs.preference.finish)
            }
            return normalized(lhs.preference.language) < normalized(rhs.preference.language)
        }
    }

    struct Lot {
        let line: InventoryLine
        let nameSlug: String
        var remaining: Int
    }

    func consume(requirement: RequirementKey, requested: inout Int, lots: inout [Lot], allocations: inout [String: Int], recordsAllocations: Bool) -> Int {
        guard requested > 0 else { return 0 }
        let candidateIndices = lots.indices
            .filter { lots[$0].remaining > 0 && lots[$0].nameSlug == requirement.nameSlug }
            .sorted { lhs, rhs in
                lotLessThan(lots[lhs], lots[rhs], preference: requirement.preference)
            }
        var consumed = 0
        for index in candidateIndices where requested > 0 {
            let quantity = min(requested, lots[index].remaining)
            lots[index].remaining -= quantity
            requested -= quantity
            consumed += quantity
            if recordsAllocations {
                allocations[lots[index].line.inventoryID, default: 0] += quantity
            }
        }
        return consumed
    }

    func lotLessThan(_ lhs: Lot, _ rhs: Lot, preference: PrintingPreference) -> Bool {
        let lhsRank = preferenceRank(line: lhs.line, preference: preference)
        let rhsRank = preferenceRank(line: rhs.line, preference: preference)
        if lhsRank != rhsRank { return lhsRank.lexicographicallyPrecedes(rhsRank) }
        let lhsLocation = InventoryLocation.normalize(lhs.line.locationName)
        let rhsLocation = InventoryLocation.normalize(rhs.line.locationName)
        if lhsLocation != rhsLocation { return lhsLocation < rhsLocation }
        if lhs.line.productID != rhs.line.productID { return lhs.line.productID < rhs.line.productID }
        if normalized(lhs.line.finish) != normalized(rhs.line.finish) { return normalized(lhs.line.finish) < normalized(rhs.line.finish) }
        if normalized(lhs.line.language) != normalized(rhs.line.language) { return normalized(lhs.line.language) < normalized(rhs.line.language) }
        return lhs.line.inventoryID < rhs.line.inventoryID
    }

    func preferenceRank(line: InventoryLine, preference: PrintingPreference) -> [Int] {
        [
            preference.productID.map { $0 == line.productID ? 0 : 1 } ?? 0,
            preference.finish.map { normalized($0) == normalized(line.finish) ? 0 : 1 } ?? 0,
            preference.language.map { normalized($0) == normalized(line.language) ? 0 : 1 } ?? 0,
        ]
    }

    static func movementLessThan(_ lhs: PlannedInventoryMovement, _ rhs: PlannedInventoryMovement) -> Bool {
        let lhsLocation = InventoryLocation.normalize(lhs.sourceLocationName)
        let rhsLocation = InventoryLocation.normalize(rhs.sourceLocationName)
        if lhsLocation != rhsLocation { return lhsLocation < rhsLocation }
        if lhs.nameSlug != rhs.nameSlug { return lhs.nameSlug < rhs.nameSlug }
        if lhs.productID != rhs.productID { return lhs.productID < rhs.productID }
        return lhs.inventoryID < rhs.inventoryID
    }

    static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}
