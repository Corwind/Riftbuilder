import Foundation
import Observation
import RiftBuilderCore
import SwiftUI

struct AppPhysicalMovement: Identifiable, Hashable, Sendable {
    let movement: PlannedInventoryMovement
    let cardName: String
    let printingDescription: String

    var id: String { movement.id }
}

struct AppMissingRequirement: Identifiable, Hashable, Sendable {
    let requirement: AssemblyRequirementResult
    let cardName: String

    var id: String { requirement.id }
}

struct AppPhysicalPlan: Identifiable, Sendable {
    enum Payload: Sendable {
        case assembly(AssemblyPlan)
        case disassembly(DisassemblyPlan)
    }

    enum Kind: String, Equatable, Sendable {
        case assembly
        case disassembly
    }

    let payload: Payload
    let deckName: String
    let movements: [AppPhysicalMovement]
    let missingRequirements: [AppMissingRequirement]

    var id: UUID {
        switch payload {
        case let .assembly(plan): plan.id
        case let .disassembly(plan): plan.id
        }
    }

    var kind: Kind {
        switch payload {
        case .assembly: .assembly
        case .disassembly: .disassembly
        }
    }

    var canExecute: Bool { missingRequirements.isEmpty && !movements.isEmpty }
}

struct AppPhysicalExecutionOutcome: Sendable {
    let report: AssemblyExecutionReport
    let reconciledAt: Date?
    let reconciliationError: String?
}

enum AppPhysicalAssemblyError: LocalizedError {
    case deckNotFound
    case linkedDeckLocationMissing
    case noStorageLocations
    case executionFailed(String)
    case executionAndReconciliationFailed(execution: String, reconciliation: String)

    var errorDescription: String? {
        switch self {
        case .deckNotFound: "The selected deck could not be loaded."
        case .linkedDeckLocationMissing: "Classify a CardNexus location as Deck and link it to this deck before assembly."
        case .noStorageLocations: "Classify at least one CardNexus location as Storage before disassembly."
        case let .executionFailed(message): "CardNexus could not execute the movement: \(message)"
        case let .executionAndReconciliationFailed(execution, reconciliation): "The movement failed (\(execution)) and inventory reconciliation also failed (\(reconciliation)). Synchronize before retrying."
        }
    }
}

protocol PhysicalAssemblyServicing: AppDataServicing {
    func makeAssemblyPlan(deckID: UUID) async throws -> AppPhysicalPlan
    func makeDisassemblyPlan(deckID: UUID, destinationStorageLocationName: String) async throws -> AppPhysicalPlan
    func assemblyStorageLocations() async throws -> [LocationPolicy]
    func executePhysicalPlan(_ plan: AppPhysicalPlan) async throws -> AppPhysicalExecutionOutcome
}

extension PhysicalAssemblyServicing {
    func makeAssemblyPlan(deckID: UUID) async throws -> AppPhysicalPlan { throw AppServiceError.unavailable("Physical assembly is unavailable.") }
    func makeDisassemblyPlan(deckID: UUID, destinationStorageLocationName: String) async throws -> AppPhysicalPlan { throw AppServiceError.unavailable("Physical disassembly is unavailable.") }
    func assemblyStorageLocations() async throws -> [LocationPolicy] { [] }
    func executePhysicalPlan(_ plan: AppPhysicalPlan) async throws -> AppPhysicalExecutionOutcome { throw AppServiceError.unavailable("Physical inventory writing is unavailable.") }
}

extension LiveAppDataService {
    func makeAssemblyPlan(deckID: UUID) async throws -> AppPhysicalPlan {
        guard let deck = try await repository.deckSnapshot(id: deckID) else { throw AppPhysicalAssemblyError.deckNotFound }
        let inventory = try await assemblyStore.assemblyInventorySnapshot()
        guard let destination = inventory.locationPolicies.first(where: { $0.kind == .deck && $0.linkedDeckID == deckID }) else {
            throw AppPhysicalAssemblyError.linkedDeckLocationMissing
        }
        let plan = try DeckAssemblyPlanner().makePlan(AssemblyPlanRequest(
            deck: deck,
            inventory: inventory,
            destinationLocationName: destination.displayName
        ))
        return Self.present(plan: .assembly(plan), deck: deck, inventory: inventory)
    }

    func makeDisassemblyPlan(deckID: UUID, destinationStorageLocationName: String) async throws -> AppPhysicalPlan {
        guard let deck = try await repository.deckSnapshot(id: deckID) else { throw AppPhysicalAssemblyError.deckNotFound }
        let inventory = try await assemblyStore.assemblyInventorySnapshot()
        guard let source = inventory.locationPolicies.first(where: { $0.kind == .deck && $0.linkedDeckID == deckID }) else {
            throw AppPhysicalAssemblyError.linkedDeckLocationMissing
        }
        let plan = try DeckDisassemblyPlanner().makePlan(DisassemblyPlanRequest(
            deckID: deckID,
            inventory: inventory,
            sourceDeckLocationName: source.displayName,
            destinationStorageLocationName: destinationStorageLocationName
        ))
        return Self.present(plan: .disassembly(plan), deck: deck, inventory: inventory)
    }

    func assemblyStorageLocations() async throws -> [LocationPolicy] {
        try await repository.locationPolicies()
            .filter { $0.kind == .storage && $0.countsAsAvailable }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func executePhysicalPlan(_ plan: AppPhysicalPlan) async throws -> AppPhysicalExecutionOutcome {
        let report: AssemblyExecutionReport
        do {
            switch plan.payload {
            case let .assembly(value): report = try await assemblyExecutor.execute(value)
            case let .disassembly(value): report = try await assemblyExecutor.execute(value)
            }
        } catch {
            do {
                _ = try await synchronize()
            } catch let reconciliationError {
                throw AppPhysicalAssemblyError.executionAndReconciliationFailed(
                    execution: error.localizedDescription,
                    reconciliation: reconciliationError.localizedDescription
                )
            }
            throw AppPhysicalAssemblyError.executionFailed(error.localizedDescription)
        }

        do {
            let reconciledAt = try await synchronize()
            try await assemblyStore.markAssemblyExecutionReconciled(planID: report.planID)
            return AppPhysicalExecutionOutcome(report: report, reconciledAt: reconciledAt, reconciliationError: nil)
        } catch {
            return AppPhysicalExecutionOutcome(report: report, reconciledAt: nil, reconciliationError: error.localizedDescription)
        }
    }

    private static func present(plan payload: AppPhysicalPlan.Payload, deck: DeckSnapshot, inventory: AssemblyInventorySnapshot) -> AppPhysicalPlan {
        let rawMovements: [PlannedInventoryMovement]
        let requirements: [AssemblyRequirementResult]
        switch payload {
        case let .assembly(plan):
            rawMovements = plan.movements
            requirements = plan.requirements
        case let .disassembly(plan):
            rawMovements = plan.movements
            requirements = []
        }
        let movements = rawMovements.map { movement in
            let printing = inventory.printingsByProductID[movement.productID]
            let details = [printing?.expansionSlug, printing?.printNumber, printing?.variant, printing?.rarity]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return AppPhysicalMovement(
                movement: movement,
                cardName: deck.identities[movement.nameSlug]?.displayName ?? printing?.displayName ?? movement.nameSlug,
                printingDescription: details.isEmpty ? "Product \(movement.productID)" : "\(details) · Product \(movement.productID)"
            )
        }
        let missing = requirements.filter { $0.missing > 0 }.map {
            AppMissingRequirement(requirement: $0, cardName: deck.identities[$0.nameSlug]?.displayName ?? $0.nameSlug)
        }
        return AppPhysicalPlan(payload: payload, deckName: deck.deck.name, movements: movements, missingRequirements: missing)
    }
}

extension LiveAppDataService: PhysicalAssemblyServicing {}
extension DemoAppDataService: PhysicalAssemblyServicing {}
extension UnavailableAppDataService: PhysicalAssemblyServicing {}

@MainActor
@Observable
final class PhysicalAssemblyModel {
    enum Phase: Equatable {
        case idle
        case planning
        case executing
    }

    var phase: Phase = .idle
    var proposal: AppPhysicalPlan?
    var executionOutcome: AppPhysicalExecutionOutcome?
    var isConfirmationPresented = false
    var isStoragePickerPresented = false
    var storageLocations: [LocationPolicy] = []
    var selectedStorageLocationName = ""

    private let service: any PhysicalAssemblyServicing

    init(service: any PhysicalAssemblyServicing) {
        self.service = service
    }

    func beginAssembly(deckID: UUID?, appModel: AppModel) async {
        guard let deckID else { appModel.notice = AppPhysicalAssemblyError.deckNotFound.localizedDescription; return }
        phase = .planning
        executionOutcome = nil
        do {
            proposal = try await service.makeAssemblyPlan(deckID: deckID)
            isConfirmationPresented = true
        } catch {
            appModel.notice = "Assembly plan could not be created: \(error.localizedDescription)"
        }
        phase = .idle
    }

    func beginDisassembly(deckID: UUID?, appModel: AppModel) async {
        guard deckID != nil else { appModel.notice = AppPhysicalAssemblyError.deckNotFound.localizedDescription; return }
        phase = .planning
        do {
            storageLocations = try await service.assemblyStorageLocations()
            guard !storageLocations.isEmpty else { throw AppPhysicalAssemblyError.noStorageLocations }
            selectedStorageLocationName = storageLocations.first?.displayName ?? ""
            isStoragePickerPresented = true
        } catch {
            appModel.notice = "Disassembly could not start: \(error.localizedDescription)"
        }
        phase = .idle
    }

    func prepareDisassembly(deckID: UUID?, appModel: AppModel) async {
        guard let deckID else { return }
        isStoragePickerPresented = false
        phase = .planning
        executionOutcome = nil
        do {
            proposal = try await service.makeDisassemblyPlan(deckID: deckID, destinationStorageLocationName: selectedStorageLocationName)
            isConfirmationPresented = true
        } catch {
            appModel.notice = "Disassembly plan could not be created: \(error.localizedDescription)"
        }
        phase = .idle
    }

    func execute(appModel: AppModel) async {
        guard let proposal, proposal.canExecute else { return }
        phase = .executing
        do {
            let outcome = try await service.executePhysicalPlan(proposal)
            executionOutcome = outcome
            await appModel.reloadAll()
            if let error = outcome.reconciliationError {
                appModel.notice = "CardNexus returned movement results, but reconciliation failed: \(error). Synchronize before retrying or moving more cards."
            }
        } catch {
            appModel.notice = error.localizedDescription
        }
        phase = .idle
    }

    func closeConfirmation() {
        isConfirmationPresented = false
        proposal = nil
        executionOutcome = nil
    }
}

struct PhysicalAssemblyConfirmationView: View {
    @Bindable var workflow: PhysicalAssemblyModel
    let appModel: AppModel
    @State private var explicitlyConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let proposal = workflow.proposal {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !proposal.missingRequirements.isEmpty { missingSection(proposal) }
                        movementSection(proposal)
                        if let outcome = workflow.executionOutcome { resultSection(outcome) }
                        if workflow.executionOutcome == nil {
                            Toggle("I reviewed every movement and want to update these physical CardNexus inventory lines.", isOn: $explicitlyConfirmed)
                                .toggleStyle(.checkbox)
                        }
                    }
                    .padding(20)
                }
                Divider()
                footer(proposal)
            }
        }
        .frame(minWidth: 780, minHeight: 600)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(workflow.proposal?.kind == .disassembly ? "Review Disassembly" : "Review Assembly")
                    .font(.title2.weight(.semibold))
                Text(workflow.proposal?.deckName ?? "Deck").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { workflow.closeConfirmation() }.keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private func missingSection(_ proposal: AppPhysicalPlan) -> some View {
        GroupBox("Missing Requirements") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Execution is disabled because storage does not contain every required card.")
                    .foregroundStyle(.red)
                ForEach(proposal.missingRequirements) { item in
                    LabeledContent(item.cardName, value: "Missing \(item.requirement.missing) of \(item.requirement.required)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func movementSection(_ proposal: AppPhysicalPlan) -> some View {
        GroupBox("Physical movements (\(proposal.movements.count))") {
            if proposal.movements.isEmpty {
                Text(proposal.kind == .assembly ? "Every required card is already in this deck location." : "No inventory lines are present in this deck location.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(proposal.movements) { item in
                        HStack(alignment: .top, spacing: 14) {
                            Text(item.movement.quantity, format: .number)
                                .font(.headline.monospacedDigit())
                                .frame(width: 30, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.cardName).fontWeight(.medium)
                                Text(item.printingDescription).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.movement.sourceLocationName ?? "No location")
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(item.movement.destinationLocationName).fontWeight(.medium)
                        }
                        .padding(.vertical, 8)
                        if item.id != proposal.movements.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func resultSection(_ outcome: AppPhysicalExecutionOutcome) -> some View {
        GroupBox("CardNexus results") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(outcome.report.results) { result in
                    HStack {
                        Image(systemName: result.status.appSystemImage).foregroundStyle(result.status.appColor)
                        Text(result.movement.nameSlug)
                        Spacer()
                        Text(result.status.appDescription).foregroundStyle(.secondary)
                    }
                }
                if let error = outcome.reconciliationError {
                    Label("Reconciliation failed: \(error)", systemImage: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.orange)
                } else {
                    Label("Inventory reconciled with CardNexus.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func footer(_ proposal: AppPhysicalPlan) -> some View {
        HStack {
            Text(proposal.canExecute ? "This changes CardNexus, which may split source inventory lines." : "Resolve missing cards or choose a plan with physical movements.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            if workflow.executionOutcome == nil {
                Button(workflow.phase == .executing ? "Updating CardNexus…" : "Confirm and Move \(proposal.movements.count) Lines") {
                    Task { await workflow.execute(appModel: appModel) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!proposal.canExecute || !explicitlyConfirmed || workflow.phase == .executing)
            } else {
                Button("Done") { workflow.closeConfirmation() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

struct DisassemblyDestinationView: View {
    @Bindable var workflow: PhysicalAssemblyModel
    let deckID: UUID?
    let appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose Storage Destination").font(.title2.weight(.semibold))
            Text("Disassembly moves every physical inventory line in the linked deck location. Choose exactly where those cards should be stored.")
                .foregroundStyle(.secondary)
            Picker("Storage location", selection: $workflow.selectedStorageLocationName) {
                ForEach(workflow.storageLocations) { location in Text(location.displayName).tag(location.displayName) }
            }
            HStack {
                Spacer()
                Button("Cancel") { workflow.isStoragePickerPresented = false }.keyboardShortcut(.cancelAction)
                Button("Review Movements") { Task { await workflow.prepareDisassembly(deckID: deckID, appModel: appModel) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(workflow.selectedStorageLocationName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

extension AssemblyMovementStatus {
    var appSystemImage: String {
        switch self {
        case .succeeded: "checkmark.circle.fill"
        case .rejected: "xmark.octagon.fill"
        case .indeterminate: "questionmark.diamond.fill"
        case .notAttempted: "minus.circle.fill"
        case .pending: "clock.fill"
        }
    }

    var appColor: Color {
        switch self {
        case .succeeded: .green
        case .rejected: .red
        case .indeterminate: .orange
        case .notAttempted, .pending: .secondary
        }
    }

    var appDescription: String {
        switch self {
        case .succeeded: "Moved"
        case let .rejected(code, _): "Rejected: \(code)"
        case let .indeterminate(message, requestID): "Uncertain: \(message)\(requestID.map { " (\($0))" } ?? "")"
        case let .notAttempted(reason): "Not attempted: \(reason)"
        case .pending: "Pending"
        }
    }
}
