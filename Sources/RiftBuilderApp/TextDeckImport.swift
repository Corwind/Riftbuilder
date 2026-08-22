import AppKit
import Foundation
import Observation
import RiftBuilderCore
import SwiftUI

struct AppTextDeckLocationAllocation: Identifiable, Hashable, Sendable {
    let normalizedName: String
    let displayName: String
    let quantity: Int

    var id: String { normalizedName }
}

struct AppTextDeckReadinessRow: Identifiable, Hashable, Sendable {
    let nameSlug: String
    let displayName: String
    let zones: [DeckZone]
    let required: Int
    let readyInStorage: Int
    let virtualRuneQuantity: Int
    let storageLocations: [AppTextDeckLocationAllocation]
    let unavailableInDecks: Int
    let deckLocations: [AppTextDeckLocationAllocation]
    let otherwiseUnavailable: Int
    let otherLocations: [AppTextDeckLocationAllocation]
    let notOwned: Int

    var id: String { nameSlug }
    var buildShortage: Int { max(0, required - readyInStorage) }
}

struct AppTextDeckImportOutcome: Sendable {
    let deckID: UUID
    let deckName: String
    let rows: [AppTextDeckReadinessRow]

    var totalRequired: Int { rows.reduce(0) { $0 + $1.required } }
    var totalReadyInStorage: Int { rows.reduce(0) { $0 + $1.readyInStorage } }
    var totalVirtualRuneQuantity: Int { rows.reduce(0) { $0 + $1.virtualRuneQuantity } }
    var totalUnavailableInDecks: Int { rows.reduce(0) { $0 + $1.unavailableInDecks } }
    var totalOtherwiseUnavailable: Int { rows.reduce(0) { $0 + $1.otherwiseUnavailable } }
    var totalNotOwned: Int { rows.reduce(0) { $0 + $1.notOwned } }
    var totalBuildShortage: Int { rows.reduce(0) { $0 + $1.buildShortage } }
}

enum AppTextDeckImportError: LocalizedError {
    case emptyDeckList
    case emptyDeckName
    case resolutionIssues([String])
    case quantityOverflow(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyDeckList:
            "Paste a deck export containing at least one card."
        case .emptyDeckName:
            "Enter a name for the new deck."
        case let .resolutionIssues(issues):
            "The deck was not created because some names could not be resolved:\n\(issues.joined(separator: "\n"))"
        case let .quantityOverflow(name):
            "The combined quantity for \(name) is too large."
        case let .saveFailed(message):
            "The deck could not be saved, so the partial import was removed. \(message)"
        }
    }
}

protocol TextDeckImportServicing: DeckTransferServicing {
    func importTextDeck(_ text: String, deckName: String) async throws -> AppTextDeckImportOutcome
}

extension TextDeckImportServicing {
    func importTextDeck(_ text: String, deckName requestedName: String) async throws -> AppTextDeckImportOutcome {
        let document = try TextDeckTextParser.parse(text)
        guard !document.entries.isEmpty else { throw AppTextDeckImportError.emptyDeckList }
        let deckName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deckName.isEmpty else { throw AppTextDeckImportError.emptyDeckName }

        let catalogue = try await appCatalogueCards(search: nil).map(\.identity)
        let deckID = UUID()
        let resolved = TextDeckNameResolver.resolve(document, against: catalogue, deckID: deckID)
        var issues = resolved.unresolvedCards.map {
            "Line \($0.entry.lineNumber): \($0.entry.displayName) was not found in the synced catalogue."
        }
        issues.append(contentsOf: resolved.ambiguousCards.map {
            let candidates = $0.candidates.map(\.displayName).joined(separator: ", ")
            return "Line \($0.entry.lineNumber): \($0.entry.displayName) is ambiguous (\(candidates))."
        })
        guard issues.isEmpty else { throw AppTextDeckImportError.resolutionIssues(issues) }

        let deck = Deck(id: deckID, name: deckName, state: .planned)
        do {
            try await saveDeck(deck)
            _ = try await beginDeckDraft(id: deckID)
            for entry in resolved.entries {
                try Task.checkCancellation()
                try await saveDeckDraftEntry(entry)
            }
        } catch {
            try? await deleteDeck(id: deckID)
            throw AppTextDeckImportError.saveFailed(error.localizedDescription)
        }

        do {
            let inventory = try await inventoryCards(search: nil, targetDeckID: deckID)
            return try Self.readinessOutcome(deck: deck, resolved: resolved, inventory: inventory)
        } catch {
            try? await deleteDeck(id: deckID)
            throw AppTextDeckImportError.saveFailed(error.localizedDescription)
        }
    }

    private static func readinessOutcome(deck: Deck, resolved: ResolvedTextDeckImport, inventory: [AppInventoryCard]) throws -> AppTextDeckImportOutcome {
        let inventoryBySlug = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        var requiredBySlug: [String: Int] = [:]
        var runeQuantityBySlug: [String: Int] = [:]
        var zonesBySlug: [String: Set<DeckZone>] = [:]
        for entry in resolved.entries {
            let (quantity, overflow) = requiredBySlug[entry.nameSlug, default: 0].addingReportingOverflow(entry.quantity)
            guard !overflow else {
                throw AppTextDeckImportError.quantityOverflow(resolved.identities[entry.nameSlug]?.displayName ?? entry.nameSlug)
            }
            requiredBySlug[entry.nameSlug] = quantity
            if entry.zone == .rune {
                let (runeQuantity, runeOverflow) = runeQuantityBySlug[entry.nameSlug, default: 0].addingReportingOverflow(entry.quantity)
                guard !runeOverflow else {
                    throw AppTextDeckImportError.quantityOverflow(resolved.identities[entry.nameSlug]?.displayName ?? entry.nameSlug)
                }
                runeQuantityBySlug[entry.nameSlug] = runeQuantity
            }
            zonesBySlug[entry.nameSlug, default: []].insert(entry.zone)
        }

        let rows: [AppTextDeckReadinessRow] = requiredBySlug.map { nameSlug, required in
            let card = inventoryBySlug[nameSlug]
            let availability = card?.availability ?? CardAvailability(totalOwned: 0, availableInStorage: 0)
            let virtualRunes = min(required, runeQuantityBySlug[nameSlug, default: 0])
            let physicalRequired = required - virtualRunes
            let readyFromStorage = min(physicalRequired, availability.availableInStorage)
            let ready = virtualRunes + readyFromStorage
            var remaining = physicalRequired - readyFromStorage
            let inDecks = min(remaining, availability.inTargetDeck + availability.inOtherDecks)
            remaining -= inDecks
            let otherwiseUnavailable = min(remaining, availability.otherwiseUnavailable)
            remaining -= otherwiseUnavailable

            let locations = card?.locations ?? []
            return AppTextDeckReadinessRow(
                nameSlug: nameSlug,
                displayName: resolved.identities[nameSlug]?.displayName ?? nameSlug,
                zones: Array(zonesBySlug[nameSlug, default: []]).sorted { $0.appSortOrder < $1.appSortOrder },
                required: required,
                readyInStorage: ready,
                virtualRuneQuantity: virtualRunes,
                storageLocations: allocate(locations.filter(\.isAvailable), limit: readyFromStorage),
                unavailableInDecks: inDecks,
                deckLocations: allocate(locations.filter { $0.kind == .deck }, limit: inDecks),
                otherwiseUnavailable: otherwiseUnavailable,
                otherLocations: allocate(locations.filter { !$0.isAvailable && $0.kind != .deck && $0.kind != .unavailable }, limit: otherwiseUnavailable),
                notOwned: remaining
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        return AppTextDeckImportOutcome(deckID: deck.id, deckName: deck.name, rows: rows)
    }

    private static func allocate(_ locations: [AppLocationBreakdown], limit: Int) -> [AppTextDeckLocationAllocation] {
        var remaining = limit
        var result: [AppTextDeckLocationAllocation] = []
        for location in locations.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) where remaining > 0 {
            let quantity = min(remaining, location.quantity)
            guard quantity > 0 else { continue }
            result.append(AppTextDeckLocationAllocation(normalizedName: location.normalizedName, displayName: location.displayName, quantity: quantity))
            remaining -= quantity
        }
        return result
    }
}

extension LiveAppDataService: TextDeckImportServicing {}
extension DemoAppDataService: TextDeckImportServicing {}
extension UnavailableAppDataService: TextDeckImportServicing {}

@MainActor
@Observable
final class TextDeckImportModel {
    var isPresented = false
    var text = ""
    var deckName = ""
    var errorMessage: String?
    var outcome: AppTextDeckImportOutcome?
    var isWorking = false

    private let service: any TextDeckImportServicing

    init(service: any TextDeckImportServicing) {
        self.service = service
    }

    func present() {
        text = ""
        deckName = ""
        errorMessage = nil
        outcome = nil
        isPresented = true
    }

    func pasteFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty else {
            errorMessage = "The clipboard does not contain text."
            return
        }
        text = pasted
        errorMessage = nil
        updateSuggestedName()
    }

    func updateSuggestedName() {
        guard deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document = try? TextDeckTextParser.parse(text),
              let suggestion = document.suggestedDeckName
        else { return }
        deckName = suggestion
    }

    func createDeck(appModel: AppModel) async {
        guard !isWorking else { return }
        updateSuggestedName()
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await service.importTextDeck(text, deckName: deckName)
            outcome = result
            await appModel.loadDecks()
            appModel.selectedDeckID = result.deckID
            appModel.destination = .decks
            await appModel.loadSelectedDeck()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TextDeckImportHost: ViewModifier {
    @Bindable var workflow: TextDeckImportModel
    let appModel: AppModel

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button { workflow.present() } label: {
                        Label("New Deck from Text", systemImage: "doc.badge.plus")
                    }
                    .help("Create a new deck from a pasted RiftDeck text export")
                }
            }
            .sheet(isPresented: $workflow.isPresented) {
                TextDeckImportView(workflow: workflow, appModel: appModel)
            }
    }
}

struct TextDeckImportCommands: Commands {
    let workflow: TextDeckImportModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Deck from Text…") { workflow.present() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}

private struct TextDeckImportView: View {
    @Bindable var workflow: TextDeckImportModel
    let appModel: AppModel
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let outcome = workflow.outcome {
                readinessReport(outcome)
            } else {
                editor
            }
        }
        .frame(minWidth: 900, minHeight: 700)
        .onAppear { textFocused = true }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.outcome == nil ? "New Deck from RiftDeck Text" : "Deck Readiness")
                    .font(.title2.weight(.semibold))
                Text(workflow.outcome == nil ? "Paste the exported list exactly as RiftDeck provides it." : (workflow.outcome?.deckName ?? "Imported Deck"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { workflow.isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Deck name", text: $workflow.deckName, prompt: Text("Suggested after pasting"))
                    .textFieldStyle(.roundedBorder)
                Button("Paste from Clipboard") { workflow.pasteFromClipboard() }
            }
            Text("Supported sections: Legend, Champion, MainDeck, Battlefields, Rune Pool, and Sideboard.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Rune Pool cards are always considered available and never need to exist in inventory.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $workflow.text)
                .font(.system(.body, design: .monospaced))
                .focused($textFocused)
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
                .onChange(of: workflow.text) { _, _ in workflow.errorMessage = nil }
            if let error = workflow.errorMessage {
                ScrollView {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
            HStack {
                Text("No deck is saved until every card name resolves uniquely against the synced catalogue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(workflow.isWorking ? "Creating…" : "Create Deck and Check Availability") {
                    Task { await workflow.createDeck(appModel: appModel) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(workflow.isWorking || workflow.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func readinessReport(_ outcome: AppTextDeckImportOutcome) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextImportMetricCard(title: "Required", value: outcome.totalRequired.formatted(), systemImage: "rectangle.stack")
                TextImportMetricCard(title: "Ready to build", value: outcome.totalReadyInStorage.formatted(), systemImage: "checkmark.circle.fill")
                TextImportMetricCard(title: "In other decks", value: outcome.totalUnavailableInDecks.formatted(), systemImage: "lock.fill")
                TextImportMetricCard(title: "Not owned", value: outcome.totalNotOwned.formatted(), systemImage: "cart.badge.questionmark")
                TextImportMetricCard(title: "Build shortage", value: outcome.totalBuildShortage.formatted(), systemImage: "exclamationmark.triangle.fill")
            }
            .padding()
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(outcome.rows) { row in readinessRow(row) }
                }
                .padding()
            }
            Divider()
            HStack {
                Text(outcome.totalBuildShortage == 0 ? "Every required physical card is available; runes are supplied automatically." : "Build shortage includes physical cards in other decks and cards you do not own. Runes never contribute to shortages.")
                    .foregroundStyle(outcome.totalBuildShortage == 0 ? .green : .secondary)
                Spacer()
                Button("Open Imported Deck") {
                    appModel.selectedDeckID = outcome.deckID
                    appModel.destination = .decks
                    workflow.isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func readinessRow(_ row: AppTextDeckReadinessRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName).font(.headline)
                    Text(row.zones.map(\.appTitle).joined(separator: " • "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                QuantityBadge(title: "Need", value: row.required)
                QuantityBadge(title: "Ready", value: row.readyInStorage, tint: .green)
                if row.virtualRuneQuantity > 0 { QuantityBadge(title: "Unlimited runes", value: row.virtualRuneQuantity, tint: .green) }
                if row.unavailableInDecks > 0 { QuantityBadge(title: "In decks", value: row.unavailableInDecks, tint: .orange) }
                if row.otherwiseUnavailable > 0 { QuantityBadge(title: "Unavailable", value: row.otherwiseUnavailable, tint: .orange) }
                if row.notOwned > 0 { QuantityBadge(title: "Not owned", value: row.notOwned, tint: .red) }
                if row.buildShortage > 0 { QuantityBadge(title: "Short", value: row.buildShortage, tint: .red) }
            }
            locationLine("Ready", allocations: row.storageLocations, color: .green)
            locationLine("In decks", allocations: row.deckLocations, color: .orange)
            locationLine("Other unavailable", allocations: row.otherLocations, color: .orange)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func locationLine(_ title: String, allocations: [AppTextDeckLocationAllocation], color: Color) -> some View {
        if !allocations.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(title):").fontWeight(.medium).foregroundStyle(color)
                Text(allocations.map { "\($0.displayName) (\($0.quantity))" }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}
