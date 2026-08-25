import AppKit
import Foundation
import Observation
import RiftBuilderCore
import SwiftUI
import UniformTypeIdentifiers

struct AppDeckImportResult: Sendable {
    let deckID: UUID
    let deckName: String
    let importedEntryCount: Int
    let unresolvedNameSlugs: [String]
}

struct AppDeckExportPayload: Sendable {
    let data: Data
    let plainText: String
    let suggestedFilename: String
}

enum AppDeckTransferError: LocalizedError {
    case noSelectedDeck
    case deckNotFound
    case emptyDocument
    case importSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSelectedDeck: "Select a deck before exporting."
        case .deckNotFound: "The selected deck could not be loaded."
        case .emptyDocument: "The selected file does not contain a deck document."
        case let .importSaveFailed(message): "The deck could not be saved, so the partial import was removed. \(message)"
        }
    }
}

protocol DeckTransferServicing: CatalogueServicing {
    func importDeckDocument(_ data: Data) async throws -> AppDeckImportResult
    func exportDeckDocument(id: UUID) async throws -> AppDeckExportPayload
}

extension DeckTransferServicing {
    func importDeckDocument(_ data: Data) async throws -> AppDeckImportResult {
        guard !data.isEmpty else { throw AppDeckTransferError.emptyDocument }
        let document = try RiftDeckCodec.decodeDocument(from: data)
        let identities = try await cardIdentities(nameSlugs: document.referencedNameSlugs)
        let unresolved = document.referencedNameSlugs.subtracting(identities.keys).sorted()
        let newDeckID = UUID()
        let decoded = try RiftDeckCodec.decodeSnapshot(
            from: data,
            deckID: newDeckID,
            importedAt: Date(),
            identities: identities
        )
        let resolvedEntries = decoded.entries.filter { identities[$0.nameSlug] != nil }

        do {
            try await saveDeck(decoded.deck)
            _ = try await beginDeckDraft(id: newDeckID)
            for entry in resolvedEntries {
                try Task.checkCancellation()
                try await saveDeckDraftEntry(entry)
            }
        } catch {
            try? await deleteDeck(id: newDeckID)
            throw AppDeckTransferError.importSaveFailed(error.localizedDescription)
        }

        return AppDeckImportResult(
            deckID: newDeckID,
            deckName: decoded.deck.name,
            importedEntryCount: resolvedEntries.count,
            unresolvedNameSlugs: unresolved
        )
    }

    func exportDeckDocument(id: UUID) async throws -> AppDeckExportPayload {
        let draft = try await deckDraftSnapshot(id: id)
        let snapshot: DeckSnapshot?
        if let draft {
            snapshot = draft.deckSnapshot
        } else {
            snapshot = try await deckSnapshot(id: id)
        }
        guard let snapshot else { throw AppDeckTransferError.deckNotFound }
        return AppDeckExportPayload(
            data: try RiftDeckCodec.encode(snapshot: snapshot, prettyPrinted: true),
            plainText: HumanReadableDeckExporter.export(snapshot),
            suggestedFilename: Self.safeFilename(snapshot.deck.name)
        )
    }

    private static func safeFilename(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let sanitized = name.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Untitled Deck" : sanitized
    }
}

extension LiveAppDataService: DeckTransferServicing {}
extension DemoAppDataService: DeckTransferServicing {}
extension UnavailableAppDataService: DeckTransferServicing {}

extension UTType {
    static let riftDeck = UTType(filenameExtension: "riftdeck", conformingTo: .json) ?? UTType(exportedAs: "com.riftbuilder.deck", conformingTo: .json)
}

struct RiftDeckFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.riftDeck, .json, .plainText]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw AppDeckTransferError.emptyDocument }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
@Observable
final class DeckTransferModel {
    var isImporterPresented = false
    var isExporterPresented = false
    var exportDocument: RiftDeckFileDocument?
    var exportFilename = "Deck"
    var exportContentType: UTType = .riftDeck
    var isWorking = false

    private let service: any DeckTransferServicing

    init(service: any DeckTransferServicing) {
        self.service = service
    }

    func requestImport() {
        guard !isWorking else { return }
        isImporterPresented = true
    }

    func importDeck(from urls: [URL], into appModel: AppModel) async {
        guard let url = urls.first else { return }
        isWorking = true
        defer { isWorking = false }
        let hasSecurityAccess = url.startAccessingSecurityScopedResource()
        defer { if hasSecurityAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let result = try await service.importDeckDocument(Data(contentsOf: url, options: .mappedIfSafe))
            await appModel.loadDecks()
            appModel.selectedDeckID = result.deckID
            appModel.destination = .decks
            await appModel.loadSelectedDeck()
            if result.unresolvedNameSlugs.isEmpty {
                appModel.notice = "Imported \(result.deckName) with \(result.importedEntryCount) entries as a new deck."
            } else {
                let names = result.unresolvedNameSlugs.joined(separator: ", ")
                appModel.notice = "Imported \(result.deckName) as a new deck. Skipped unresolved cards: \(names). Synchronize the catalogue and import again if these cards should be available."
            }
        } catch {
            appModel.notice = "Deck import failed: \(error.localizedDescription)"
        }
    }

    func prepareExport(deckID: UUID?, appModel: AppModel) async {
        await prepareExport(deckID: deckID, format: .riftBuilderDocument, appModel: appModel)
    }

    func prepareRiftDeckTextExport(deckID: UUID?, appModel: AppModel) async {
        await prepareExport(deckID: deckID, format: .riftDeckText, appModel: appModel)
    }

    private enum ExportFormat {
        case riftBuilderDocument
        case riftDeckText
    }

    private func prepareExport(deckID: UUID?, format: ExportFormat, appModel: AppModel) async {
        guard let deckID else {
            appModel.notice = AppDeckTransferError.noSelectedDeck.localizedDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let payload = try await service.exportDeckDocument(id: deckID)
            switch format {
            case .riftBuilderDocument:
                exportDocument = RiftDeckFileDocument(data: payload.data)
                exportFilename = payload.suggestedFilename + ".riftdeck"
                exportContentType = .riftDeck
            case .riftDeckText:
                exportDocument = RiftDeckFileDocument(data: Data(payload.plainText.utf8))
                exportFilename = payload.suggestedFilename + ".txt"
                exportContentType = .plainText
            }
            isExporterPresented = true
        } catch {
            appModel.notice = "Deck export failed: \(error.localizedDescription)"
        }
    }

    func copyDeckList(deckID: UUID?, appModel: AppModel) async {
        guard let deckID else {
            appModel.notice = AppDeckTransferError.noSelectedDeck.localizedDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let payload = try await service.exportDeckDocument(id: deckID)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(payload.plainText, forType: .string) else {
                throw AppServiceError.unavailable("macOS could not write the deck list to the clipboard.")
            }
            appModel.notice = "Copied the RiftDeck-compatible deck list to the clipboard."
        } catch {
            appModel.notice = "Clipboard export failed: \(error.localizedDescription)"
        }
    }

    func exportCompleted(_ result: Result<URL, any Error>, appModel: AppModel) {
        switch result {
        case let .success(url):
            appModel.notice = "Exported \(url.lastPathComponent)."
        case let .failure(error):
            appModel.notice = "Deck export failed: \(error.localizedDescription)"
        }
        exportDocument = nil
    }
}
