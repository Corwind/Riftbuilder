import SwiftUI

@main
struct RiftBuilderApp: App {
    @NSApplicationDelegateAdaptor(ForegroundApplicationDelegate.self) private var applicationDelegate
    @State private var model: AppModel
    @State private var deckTransfer: DeckTransferModel
    @State private var textDeckImport: TextDeckImportModel
    @State private var physicalAssembly: PhysicalAssemblyModel
    @State private var deckSave: DeckSaveWorkflowModel
    @State private var theme: AppTheme
    @State private var debugLog: DebugLogModel

    init() {
        let debugLog = DebugLogModel()
        let service: any TextDeckImportServicing & PhysicalAssemblyServicing & DeckSaveServicing
        do {
            service = try LiveAppDataService(debugLogger: debugLog)
        } catch {
            service = UnavailableAppDataService(error: error)
        }
        _model = State(initialValue: AppModel(service: service))
        _deckTransfer = State(initialValue: DeckTransferModel(service: service))
        _textDeckImport = State(initialValue: TextDeckImportModel(service: service))
        _physicalAssembly = State(initialValue: PhysicalAssemblyModel(service: service))
        _deckSave = State(initialValue: DeckSaveWorkflowModel(service: service))
        _theme = State(initialValue: AppTheme())
        _debugLog = State(initialValue: debugLog)
    }

    var body: some Scene {
        WindowGroup {
            AppShellView(model: model, deckTransfer: deckTransfer, physicalAssembly: physicalAssembly, debugLog: debugLog)
                .modifier(TextDeckImportHost(workflow: textDeckImport, appModel: model))
                .modifier(PhysicalAssemblyHost(workflow: physicalAssembly, appModel: model))
                .modifier(DeckSaveWorkflowHost(workflow: deckSave, appModel: model))
                .environment(theme)
                .background {
                    WindowAppearanceBridge(
                        appearance: theme.appearance,
                        transparency: theme.backgroundTransparency,
                        accent: theme.accent,
                        secondaryAccent: theme.secondaryAccent
                    )
                        .frame(width: 0, height: 0)
                }
                .tint(theme.accent.color)
                .task {
                    await model.bootstrap()
                    if model.credentialState != .stored {
                        model.destination = .settings
                    }
                }
        }
        .defaultSize(width: 1220, height: 780)
        .commands {
            RiftBuilderCommands(model: model, deckTransfer: deckTransfer)
            TextDeckImportCommands(workflow: textDeckImport)
        }
    }
}
