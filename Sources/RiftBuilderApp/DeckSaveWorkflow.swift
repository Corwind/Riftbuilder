import Foundation
import Observation
import RiftBuilderCore
import SwiftUI

struct AppDeckSaveRequirement: Identifiable, Hashable, Sendable {
    let result: DeckSaveRequirementResult
    let cardName: String

    var id: DeckPhysicalRequirementKey { result.requirement }
}

struct AppDeckSaveProposal: Identifiable, Sendable {
    let plan: DeckSavePlan
    let draftUpdatedAt: Date
    let deckName: String
    let movements: [AppPhysicalMovement]
    let requirements: [AppDeckSaveRequirement]
    let storageLocations: [LocationPolicy]

    var id: UUID { plan.id }
    var canApply: Bool { plan.canApply }
    var hasPhysicalMovements: Bool { !plan.movements.isEmpty }
}

enum AppDeckSaveError: LocalizedError {
    case deckNotFound
    case draftNotFound
    case noChanges
    case noStorageForRemovals
    case planNotReady

    var errorDescription: String? {
        switch self {
        case .deckNotFound: "The selected deck could not be loaded."
        case .draftNotFound: "The selected deck has no editing draft."
        case .noChanges: "This deck has no unsaved changes."
        case .noStorageForRemovals: "At least one available Box location is required before removed cards can be saved."
        case .planNotReady: "Resolve every destination and missing card before saving."
        }
    }
}

protocol DeckSaveServicing: AppDataServicing {
    func makeDeckSaveProposal(deckID: UUID, removalDestinations: [DeckRemovalDestination]) async throws -> AppDeckSaveProposal
    func applyDeckSaveProposal(_ proposal: AppDeckSaveProposal) async throws -> DeckSaveApplicationOutcome
}

extension DeckSaveServicing {
    func makeDeckSaveProposal(deckID: UUID, removalDestinations: [DeckRemovalDestination]) async throws -> AppDeckSaveProposal {
        throw AppServiceError.unavailable("Deck saving is unavailable.")
    }

    func applyDeckSaveProposal(_ proposal: AppDeckSaveProposal) async throws -> DeckSaveApplicationOutcome {
        throw AppServiceError.unavailable("Deck saving is unavailable.")
    }
}

extension LiveAppDataService: DeckSaveInventoryReconciling {
    func reconcileDeckSaveInventory() async throws {
        _ = try await synchronize()
    }
}

extension LiveAppDataService {
    func makeDeckSaveProposal(deckID: UUID, removalDestinations: [DeckRemovalDestination]) async throws -> AppDeckSaveProposal {
        guard let saved = try await repository.deckSnapshot(id: deckID) else { throw AppDeckSaveError.deckNotFound }
        guard let draft = try await repository.deckDraftSnapshot(id: deckID) else { throw AppDeckSaveError.draftNotFound }
        guard !DeckDraftDiff(savedEntries: saved.entries, draftEntries: draft.entries).isEmpty else { throw AppDeckSaveError.noChanges }

        var inventory = try await assemblyStore.assemblyInventorySnapshot()
        var deckLocation = inventory.locationPolicies.first(where: { $0.kind == .deck && $0.linkedDeckID == deckID })
        if deckLocation == nil {
            let requestedName = "Deck: \(draft.deck.name)"
            let requestedKey = InventoryLocation.normalize(requestedName)
            let existing = inventory.locationPolicies.first(where: { $0.normalizedName == requestedKey })
            let policy = LocationPolicy(
                normalizedName: requestedKey,
                displayName: existing?.displayName ?? requestedName,
                color: existing?.color ?? "#8B5CF6",
                icon: existing?.icon ?? "rectangle.stack",
                kind: .deck,
                countsAsAvailable: false,
                linkedDeckID: deckID
            )
            inventory = AssemblyInventorySnapshot(
                lines: inventory.lines,
                printingsByProductID: inventory.printingsByProductID,
                locationPolicies: inventory.locationPolicies.filter { $0.normalizedName != requestedKey } + [policy]
            )
            deckLocation = policy
        }
        guard let deckLocation else { throw AppPhysicalAssemblyError.linkedDeckLocationMissing }

        let plan = try DeckSavePlanner().makePlan(DeckSavePlanRequest(
            savedDeck: saved,
            draft: draft,
            inventory: inventory,
            deckLocationName: deckLocation.displayName,
            removalDestinations: removalDestinations
        ))
        let identities = draft.identities.merging(saved.identities) { current, _ in current }
        let movements = plan.movements.map { movement in
            let printing = inventory.printingsByProductID[movement.productID]
            let details = [printing?.expansionSlug, printing?.printNumber, printing?.variant, printing?.rarity]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return AppPhysicalMovement(
                movement: movement,
                cardName: identities[movement.nameSlug]?.displayName ?? printing?.displayName ?? movement.nameSlug,
                printingDescription: details.isEmpty ? "Product \(movement.productID)" : "\(details) · Product \(movement.productID)"
            )
        }
        let requirements = plan.requirements.map { result in
            AppDeckSaveRequirement(result: result, cardName: identities[result.requirement.nameSlug]?.displayName ?? result.requirement.nameSlug)
        }
        let storage = inventory.locationPolicies.filter { $0.kind == .storage && $0.countsAsAvailable }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return AppDeckSaveProposal(plan: plan, draftUpdatedAt: draft.updatedAt, deckName: draft.deck.name, movements: movements, requirements: requirements, storageLocations: storage)
    }

    func applyDeckSaveProposal(_ proposal: AppDeckSaveProposal) async throws -> DeckSaveApplicationOutcome {
        guard proposal.canApply else { throw AppDeckSaveError.planNotReady }
        let policies = try await repository.locationPolicies()
        if !policies.contains(where: { $0.kind == .deck && $0.linkedDeckID == proposal.plan.deckID }) {
            let existing = policies.first(where: { $0.normalizedName == InventoryLocation.normalize(proposal.plan.deckLocationName) })
            let remote = try await cardNexus.upsertInventoryLocation(InventoryLocationUpsertRequest(
                name: proposal.plan.deckLocationName,
                color: existing?.color ?? "#8B5CF6",
                icon: existing?.icon ?? "rectangle.stack"
            ))
            try await repository.saveLocationPolicy(LocationPolicy(
                normalizedName: remote.normalizedName,
                displayName: remote.name,
                color: remote.color,
                icon: remote.icon,
                kind: .deck,
                countsAsAvailable: false,
                linkedDeckID: proposal.plan.deckID
            ))
        }
        let coordinator = DeckSaveCoordinator(
            store: repository,
            executor: assemblyExecutor,
            reconciler: self,
            executionJournal: assemblyStore
        )
        return try await coordinator.apply(DeckSaveOperation(plan: proposal.plan, draftUpdatedAt: proposal.draftUpdatedAt))
    }
}

extension LiveAppDataService: DeckSaveServicing {}
extension DemoAppDataService: DeckSaveServicing {}
extension UnavailableAppDataService: DeckSaveServicing {}

@MainActor
@Observable
final class DeckSaveWorkflowModel {
    enum Phase: Equatable {
        case idle
        case planning
        case applying
    }

    var phase: Phase = .idle
    var proposal: AppDeckSaveProposal?
    var outcome: DeckSaveApplicationOutcome?
    var isPresented = false
    var removalDestinations: [DeckPhysicalRequirementKey: String] = [:]

    private let service: any DeckSaveServicing

    init(service: any DeckSaveServicing) {
        self.service = service
    }

    func begin(deckID: UUID?, appModel: AppModel) async {
        guard let deckID else { appModel.notice = AppDeckSaveError.deckNotFound.localizedDescription; return }
        phase = .planning
        outcome = nil
        removalDestinations = [:]
        do {
            var proposal = try await service.makeDeckSaveProposal(deckID: deckID, removalDestinations: [])
            let removals = proposal.requirements.filter { $0.result.direction == .outOfDeck }
            if !removals.isEmpty {
                guard let defaultLocation = proposal.storageLocations.first?.displayName else { throw AppDeckSaveError.noStorageForRemovals }
                for removal in removals { removalDestinations[removal.result.requirement] = defaultLocation }
                proposal = try await service.makeDeckSaveProposal(deckID: deckID, removalDestinations: destinationValues)
            }
            self.proposal = proposal
            isPresented = true
        } catch {
            appModel.notice = error.localizedDescription
        }
        phase = .idle
    }

    func setDestination(_ locationName: String, for requirement: DeckPhysicalRequirementKey, deckID: UUID?, appModel: AppModel) async {
        guard let deckID else { return }
        removalDestinations[requirement] = locationName
        phase = .planning
        do {
            proposal = try await service.makeDeckSaveProposal(deckID: deckID, removalDestinations: destinationValues)
        } catch {
            appModel.notice = "Save plan could not be updated: \(error.localizedDescription)"
        }
        phase = .idle
    }

    func apply(appModel: AppModel) async {
        guard let proposal else { return }
        phase = .applying
        do {
            let outcome = try await service.applyDeckSaveProposal(proposal)
            self.outcome = outcome
            await appModel.reloadAll()
            if outcome.isFinalized {
                appModel.notice = proposal.hasPhysicalMovements ? "Deck saved and CardNexus inventory reconciled." : "Deck definition saved. No physical card movement was required."
            } else if let message = outcome.message {
                appModel.notice = message
            }
        } catch {
            appModel.notice = error.localizedDescription
        }
        phase = .idle
    }

    func close() {
        isPresented = false
        proposal = nil
        outcome = nil
        removalDestinations = [:]
    }

    private var destinationValues: [DeckRemovalDestination] {
        removalDestinations.map { DeckRemovalDestination(requirement: $0.key, locationName: $0.value) }
    }
}

struct DeckSaveReviewView: View {
    @Bindable var workflow: DeckSaveWorkflowModel
    let appModel: AppModel
    @State private var acknowledged = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Deck Save").font(.title2.weight(.semibold))
                    Text(workflow.proposal?.deckName ?? "Deck").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { workflow.close() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if let proposal = workflow.proposal {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        removalDestinations(proposal)
                        shortages(proposal)
                        movements(proposal)
                        if let outcome = workflow.outcome { results(outcome) }
                        if workflow.outcome == nil {
                            Toggle("I found the added cards, reviewed every destination, and want to update CardNexus.", isOn: $acknowledged)
                                .toggleStyle(.checkbox)
                        }
                    }
                    .padding(20)
                }
                Divider()
                footer(proposal)
            } else {
                LoadingStateView(message: "Preparing save review…")
            }
        }
        .frame(minWidth: 820, minHeight: 620)
    }

    @ViewBuilder
    private func removalDestinations(_ proposal: AppDeckSaveProposal) -> some View {
        let removals = proposal.requirements.filter { $0.result.direction == .outOfDeck }
        if !removals.isEmpty {
            GroupBox("Return removed cards") {
                VStack(spacing: 10) {
                    ForEach(removals) { item in
                        HStack {
                            Text("\(item.result.requested) × \(item.cardName)").fontWeight(.medium)
                            Spacer()
                            Picker("Destination", selection: Binding(
                                get: { workflow.removalDestinations[item.result.requirement] ?? "" },
                                set: { location in
                                    Task { await workflow.setDestination(location, for: item.result.requirement, deckID: appModel.selectedDeckID, appModel: appModel) }
                                }
                            )) {
                                ForEach(proposal.storageLocations) { location in Text(location.displayName).tag(location.displayName) }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func shortages(_ proposal: AppDeckSaveProposal) -> some View {
        let missing = proposal.requirements.filter { $0.result.missing > 0 }
        if !missing.isEmpty {
            GroupBox("Cannot save yet") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(missing) { item in
                        Label("Missing \(item.result.missing) × \(item.cardName)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    private func movements(_ proposal: AppDeckSaveProposal) -> some View {
        GroupBox("Physical movements (\(proposal.movements.count))") {
            if proposal.movements.isEmpty {
                Text("Only the deck definition changed; no physical cards need to move.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(proposal.movements) { item in
                        HStack(alignment: .top, spacing: 14) {
                            Text(item.movement.quantity, format: .number).font(.headline.monospacedDigit()).frame(width: 30, alignment: .trailing)
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

    private func results(_ outcome: DeckSaveApplicationOutcome) -> some View {
        GroupBox("Save result") {
            VStack(alignment: .leading, spacing: 8) {
                if let report = outcome.report {
                    ForEach(report.results) { result in
                        HStack {
                            Image(systemName: result.status.appSystemImage).foregroundStyle(result.status.appColor)
                            Text(result.movement.nameSlug)
                            Spacer()
                            Text(result.status.appDescription).foregroundStyle(.secondary)
                        }
                    }
                }
                Label(outcome.isFinalized ? "Saved definition and inventory are reconciled." : (outcome.message ?? "The draft was retained."), systemImage: outcome.isFinalized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.isFinalized ? .green : .orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func footer(_ proposal: AppDeckSaveProposal) -> some View {
        HStack {
            Text(proposal.hasPhysicalMovements ? "CardNexus will move the listed inventory lines, then RiftBuilder will synchronize before finalizing the deck." : "This save only updates the local deck definition.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            if let outcome = workflow.outcome, outcome.isFinalized {
                Button("Done") { workflow.close() }.buttonStyle(.borderedProminent)
            } else {
                Button(workflow.phase == .applying ? "Saving…" : "Confirm and Save") {
                    Task { await workflow.apply(appModel: appModel) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!proposal.canApply || !acknowledged || workflow.phase != .idle)
            }
        }
        .padding()
    }
}

struct DeckSaveWorkflowHost: ViewModifier {
    @Bindable var workflow: DeckSaveWorkflowModel
    let appModel: AppModel

    func body(content: Content) -> some View {
        content
            .toolbar {
                if appModel.destination == .decks, appModel.selectedDeckID != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await workflow.begin(deckID: appModel.selectedDeckID, appModel: appModel) }
                        } label: {
                            Label("Save Deck", systemImage: "checkmark.circle")
                        }
                        .keyboardShortcut("s", modifiers: [.command])
                        .disabled(workflow.phase != .idle)
                    }
                }
            }
            .sheet(isPresented: $workflow.isPresented) {
                DeckSaveReviewView(workflow: workflow, appModel: appModel)
            }
    }
}
