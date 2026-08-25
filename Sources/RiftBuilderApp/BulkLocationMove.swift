import Foundation
import RiftBuilderCore
import SwiftUI

struct AppBulkLocationMoveResult: Sendable {
    let plannedLineCount: Int
    let succeededLineCount: Int
    let rejectedLineCount: Int
    let movedQuantity: Int
    let rejectionCodes: [String]
    let synchronizationWarning: String?
}

enum AppBulkLocationMoveError: LocalizedError {
    case noMatchingInventory
    case executionFailed(completedLines: Int, reason: String)
    case executionAndReconciliationFailed(completedLines: Int, execution: String, reconciliation: String)

    var errorDescription: String? {
        switch self {
        case .noMatchingInventory:
            "No physical inventory lines match these cards and source location."
        case let .executionFailed(completedLines, reason):
            "The bulk move stopped after \(completedLines) line(s) succeeded: \(reason) Inventory was refreshed before returning."
        case let .executionAndReconciliationFailed(completedLines, execution, reconciliation):
            "The bulk move stopped after \(completedLines) line(s) succeeded (\(execution)), and inventory refresh also failed (\(reconciliation)). Synchronize before retrying."
        }
    }
}

protocol BulkLocationMoving: AppDataServicing {
    func bulkMoveInventory(nameSlugs: Set<String>, sourceLocationKey: String?, destinationLocationName: String) async throws -> AppBulkLocationMoveResult
}

extension BulkLocationMoving {
    func bulkMoveInventory(nameSlugs: Set<String>, sourceLocationKey: String?, destinationLocationName: String) async throws -> AppBulkLocationMoveResult {
        throw AppServiceError.unavailable("Bulk inventory movement is unavailable.")
    }
}

extension LiveAppDataService {
    func bulkMoveInventory(nameSlugs: Set<String>, sourceLocationKey: String?, destinationLocationName: String) async throws -> AppBulkLocationMoveResult {
        let snapshot = try await assemblyStore.assemblyInventorySnapshot()
        let plan = BulkLocationMovePlanner().makePlan(
            inventory: snapshot,
            nameSlugs: nameSlugs,
            sourceLocationKey: sourceLocationKey,
            destinationLocationName: destinationLocationName
        )
        guard !plan.movements.isEmpty else { throw AppBulkLocationMoveError.noMatchingInventory }

        let batches = stride(from: 0, to: plan.movements.count, by: 200).map {
            Array(plan.movements[$0 ..< min($0 + 200, plan.movements.count)])
        }
        var succeededLineCount = 0
        var rejectedLineCount = 0
        var movedQuantity = 0
        var rejectionCodes: Set<String> = []

        do {
            for (batchIndex, batch) in batches.enumerated() {
                try Task.checkCancellation()
                let response = try await cardNexus.bulkMoveInventoryLines(InventoryBulkMoveRequest(
                    idempotencyKey: "riftbuilder-bulk-move-\(plan.id.uuidString.lowercased())-\(batchIndex)",
                    moves: batch.map {
                        InventoryBulkLocationMove(
                            inventoryID: $0.inventoryID,
                            quantity: $0.quantity,
                            destinationLocationName: $0.destinationLocationName
                        )
                    }
                ))
                let resultsByIndex = Dictionary(response.results.map { ($0.index, $0.status) }, uniquingKeysWith: { first, _ in first })
                for (index, movement) in batch.enumerated() {
                    switch resultsByIndex[index] {
                    case .succeeded:
                        succeededLineCount += 1
                        movedQuantity += movement.quantity
                    case let .rejected(code, _):
                        rejectedLineCount += 1
                        rejectionCodes.insert(code)
                    case nil:
                        rejectedLineCount += 1
                        rejectionCodes.insert("MISSING_RESULT")
                    }
                }
            }
        } catch {
            let executionMessage = error.localizedDescription
            do {
                _ = try await synchronize()
            } catch let reconciliationError {
                throw AppBulkLocationMoveError.executionAndReconciliationFailed(
                    completedLines: succeededLineCount,
                    execution: executionMessage,
                    reconciliation: reconciliationError.localizedDescription
                )
            }
            throw AppBulkLocationMoveError.executionFailed(completedLines: succeededLineCount, reason: executionMessage)
        }

        let synchronizationWarning: String?
        do {
            _ = try await synchronize()
            synchronizationWarning = nil
        } catch {
            synchronizationWarning = error.localizedDescription
        }
        return AppBulkLocationMoveResult(
            plannedLineCount: plan.movements.count,
            succeededLineCount: succeededLineCount,
            rejectedLineCount: rejectedLineCount,
            movedQuantity: movedQuantity,
            rejectionCodes: rejectionCodes.sorted(),
            synchronizationWarning: synchronizationWarning
        )
    }
}

extension LiveAppDataService: BulkLocationMoving {}
extension DemoAppDataService: BulkLocationMoving {}
extension UnavailableAppDataService: BulkLocationMoving {}

extension AppModel {
    func bulkMoveInventory(nameSlugs: Set<String>, sourceLocationKey: String?, destinationLocationName: String) async -> Bool {
        guard let mover = service as? any BulkLocationMoving else {
            notice = "Bulk inventory movement is unavailable."
            return false
        }
        do {
            let result = try await mover.bulkMoveInventory(
                nameSlugs: nameSlugs,
                sourceLocationKey: sourceLocationKey,
                destinationLocationName: destinationLocationName
            )
            await loadInventory()
            var message = "Moved \(result.movedQuantity) card(s) across \(result.succeededLineCount) inventory line(s) to '\(destinationLocationName)'."
            if result.rejectedLineCount > 0 {
                message += " CardNexus rejected \(result.rejectedLineCount) of \(result.plannedLineCount) line(s)"
                if !result.rejectionCodes.isEmpty { message += " (\(result.rejectionCodes.joined(separator: ", ")))" }
                message += "."
            }
            if let warning = result.synchronizationWarning {
                message += " The move completed, but inventory refresh failed: \(warning) Synchronize before moving more cards."
            }
            notice = message
            return true
        } catch {
            await loadInventory()
            notice = "Bulk move failed: \(error.localizedDescription)"
            return false
        }
    }
}

struct BulkMoveSelection: Identifiable {
    let id = UUID()
    let cards: [AppInventoryCard]
    let initialSourceLocationKey: String?
    let filterSummary: String
}

struct BulkMoveInventoryView: View {
    let selection: BulkMoveSelection
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceLocationKey: String?
    @State private var destinationLocationKey: String?
    @State private var isMoving = false
    @State private var isConfirming = false

    init(selection: BulkMoveSelection, model: AppModel) {
        self.selection = selection
        self.model = model
        _sourceLocationKey = State(initialValue: selection.initialSourceLocationKey)
        let initialDestination = model.locations.first {
            $0.normalizedName != "__unlocated__" && $0.normalizedName != selection.initialSourceLocationKey
        }?.normalizedName
        _destinationLocationKey = State(initialValue: initialDestination)
    }

    private var destination: LocationPolicy? {
        model.locations.first { $0.normalizedName == destinationLocationKey }
    }

    private var sourceLocations: [LocationPolicy] {
        model.locations.filter { policy in
            selection.cards.contains { card in card.locations.contains { $0.normalizedName == policy.normalizedName && $0.quantity > 0 } }
        }
    }

    private var eligibleCards: [(card: AppInventoryCard, quantity: Int)] {
        selection.cards.compactMap { card in
            let quantity = card.locations.reduce(0) { total, location in
                guard location.quantity > 0,
                      location.normalizedName != destinationLocationKey,
                      sourceLocationKey.map({ $0 == location.normalizedName }) != false
                else { return total }
                return total + location.quantity
            }
            return quantity > 0 ? (card, quantity) : nil
        }
    }

    private var totalQuantity: Int { eligibleCards.reduce(0) { $0 + $1.quantity } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bulk Move Inventory").font(.title2.weight(.semibold))
                Text("Move every physical copy matching the captured inventory results.")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Captured results", value: "\(selection.cards.count) card name(s)")
            if !selection.filterSummary.isEmpty {
                Text(selection.filterSummary).font(.callout).foregroundStyle(.secondary)
            }

            Picker("From", selection: $sourceLocationKey) {
                Text("All locations").tag(nil as String?)
                ForEach(sourceLocations) { location in
                    Text(location.displayName).tag(location.normalizedName as String?)
                }
            }

            Picker("To", selection: $destinationLocationKey) {
                Text("Choose a destination").tag(nil as String?)
                ForEach(model.locations.filter { $0.normalizedName != "__unlocated__" }) { location in
                    Text(location.displayName).tag(location.normalizedName as String?)
                }
            }

            GroupBox {
                HStack {
                    Label("\(eligibleCards.count) card name(s)", systemImage: "rectangle.stack")
                    Spacer()
                    Text("\(totalQuantity) physical card(s)").fontWeight(.semibold)
                }
                .padding(.vertical, 4)
            } label: {
                Text("Move preview")
            }

            if sourceLocationKey == nil {
                Label("All locations includes storage, deck, unavailable, and unlocated inventory. Copies already at the destination are skipped.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isMoving ? "Moving…" : "Review Move") { isConfirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(isMoving || destination == nil || totalQuantity == 0)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .confirmationDialog(
            "Move \(totalQuantity) physical card(s) to \(destination?.displayName ?? "the destination")?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Move \(totalQuantity) Cards") { performMove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates CardNexus inventory and cannot be undone in RiftBuilder.")
        }
    }

    private func performMove() {
        guard let destination else { return }
        isMoving = true
        let nameSlugs = Set(selection.cards.map(\.id))
        Task {
            let succeeded = await model.bulkMoveInventory(
                nameSlugs: nameSlugs,
                sourceLocationKey: sourceLocationKey,
                destinationLocationName: destination.displayName
            )
            isMoving = false
            if succeeded { dismiss() }
        }
    }
}
