import SwiftUI

struct AppShellView: View {
    @Bindable var model: AppModel
    @Bindable var deckTransfer: DeckTransferModel
    @Bindable var physicalAssembly: PhysicalAssemblyModel
    @Environment(AppTheme.self) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            ZStack {
                sidebarBackground
                    .ignoresSafeArea(.container, edges: [.top, .bottom])

                List {
                    Section("Library") {
                        ForEach(AppDestination.allCases) { destination in
                            sidebarButton(for: destination)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) { SidebarStatusView(model: model) }
            }
            .navigationTitle("RiftBuilder")
            .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 260)
            .tint(theme.accent.color)
        } detail: {
            destinationView
                .frame(minWidth: 760, minHeight: 580)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await model.synchronize() } } label: {
                            if model.syncState.isSyncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Synchronize", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .help("Synchronize CardNexus inventory")
                        .disabled(model.syncState.isSyncing || model.credentialState != .stored)
                    }
                }
        }
        .containerBackground(for: .window) { windowBackground }
        .background { windowBackground.ignoresSafeArea() }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task { await model.bootstrap() }
        .fileImporter(
            isPresented: $deckTransfer.isImporterPresented,
            allowedContentTypes: [.riftDeck, .json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                Task { await deckTransfer.importDeck(from: urls, into: model) }
            case let .failure(error):
                model.notice = "Deck import failed: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $deckTransfer.isExporterPresented,
            document: deckTransfer.exportDocument,
            contentType: deckTransfer.exportContentType,
            defaultFilename: deckTransfer.exportFilename
        ) { result in
            deckTransfer.exportCompleted(result, appModel: model)
        }
        .sheet(item: $model.deckNamingRequest) { request in
            DeckNamingSheet(request: request, model: model)
        }
        .alert("RiftBuilder", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    private var sidebarBackground: some View {
        ThemeTintedSurface(
            colors: theme.colors,
            transparency: theme.backgroundTransparency,
            lightTintOpacity: 0.42,
            darkTintOpacity: 0.32
        )
    }

    private var windowBackground: some View {
        ThemeTintedSurface(
            colors: theme.colors,
            transparency: theme.backgroundTransparency,
            lightTintOpacity: 0.28,
            darkTintOpacity: 0.20,
            direction: (.leading, .trailing)
        )
    }

    private func sidebarButton(for destination: AppDestination) -> some View {
        let isSelected = model.destination == destination

        return Button {
            model.destination = destination
        } label: {
            Label(destination.title, systemImage: destination.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.clear))
                        .opacity(isSelected ? (colorScheme == .dark ? 0.34 : 0.20) : 0)
                }
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.destination ?? .inventory {
        case .inventory: InventoryView(model: model)
        case .catalogue: CatalogueView(model: model)
        case .decks: DecksView(model: model, deckTransfer: deckTransfer, physicalAssembly: physicalAssembly)
        case .locations: LocationsView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

private struct SidebarStatusView: View {
    @Bindable var model: AppModel
    @Environment(AppTheme.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if model.credentialState == .missing {
                Button { model.destination = .settings } label: {
                    Label("Connect CardNexus", systemImage: "key")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            } else if case let .syncing(progress, message) = model.syncState {
                ProgressView(value: progress)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                HStack {
                    Image(systemName: model.isOffline ? "wifi.slash" : "checkmark.circle.fill")
                        .foregroundStyle(model.isOffline ? .orange : theme.accent.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.isOffline ? "Using cached data" : "Collection ready")
                        if let date = model.lastSuccessfulSync {
                            Text("Synced \(date.formatted(.relative(presentation: .named)))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

struct RiftBuilderCommands: Commands {
    let model: AppModel
    let deckTransfer: DeckTransferModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Deck") { model.requestNewDeckNaming() }
                .keyboardShortcut("n", modifiers: [.command])
            Divider()
            Button("Import Deck…") { deckTransfer.requestImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(deckTransfer.isWorking)
            Button("Export RiftDeck Text…") {
                Task { await deckTransfer.prepareRiftDeckTextExport(deckID: model.selectedDeckID, appModel: model) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.selectedDeckID == nil || deckTransfer.isWorking)
            Button("Copy RiftDeck List") {
                Task { await deckTransfer.copyDeckList(deckID: model.selectedDeckID, appModel: model) }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(model.selectedDeckID == nil || deckTransfer.isWorking)
            Button("Export RiftBuilder Deck File…") {
                Task { await deckTransfer.prepareExport(deckID: model.selectedDeckID, appModel: model) }
            }
            .disabled(model.selectedDeckID == nil || deckTransfer.isWorking)
        }
        CommandMenu("Collection") {
            Button("Synchronize with CardNexus") { Task { await model.synchronize() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.syncState.isSyncing || model.credentialState != .stored)
            Button("Search Inventory") { model.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command])
        }
    }
}
