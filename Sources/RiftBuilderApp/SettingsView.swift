import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var apiKey = ""
    @State private var showingReplaceField = false
    @State private var showingDeleteConfirmation = false
    @FocusState private var apiKeyFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsCard("Appearance") {
                    ThemeSettingsSection()
                }

                settingsCard("Deck inventory") {
                    Toggle("Always consider Runes available", isOn: $model.alwaysAvailableRunes)
                    Text("When enabled, Rune cards never need to be scanned, moved into a deck, or counted as missing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Divider()
                    Toggle("Always consider Battlefields available", isOn: $model.alwaysAvailableBattlefields)
                    Text("When enabled, Battlefield cards never need to be scanned, moved into a deck, or counted as missing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Divider()
                    Text("Turn either option off to use CardNexus inventory and locations normally for that card type. These settings affect availability and physical movement only; deck-building rules are unchanged.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                settingsCard("CardNexus account") {
                    credentialContent
                }

                settingsCard("Synchronization") {
                    LabeledContent("Status") { syncStatus }
                    Divider()
                    LabeledContent("Last successful sync") {
                        if let date = model.lastSuccessfulSync {
                            Text(date, format: .dateTime.day().month().year().hour().minute())
                        } else {
                            Text("Never").foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Button {
                        Task { await model.synchronize() }
                    } label: {
                        Label(model.syncState.isSyncing ? "Synchronizing…" : "Synchronize Now", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.syncState.isSyncing || model.credentialState != .stored)
                }

                settingsCard("Local data") {
                    LabeledContent("Cached cards", value: model.inventoryTotal.formatted())
                    Divider()
                    LabeledContent("Available in storage", value: model.availableTotal.formatted())
                    Divider()
                    Text("Deck definitions are local. Inventory ownership and physical locations remain authoritative in CardNexus.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Settings")
        .onAppear {
            if model.credentialState != .stored { apiKeyFocused = true }
        }
        .confirmationDialog("Remove the stored API key?", isPresented: $showingDeleteConfirmation) {
            Button("Remove API Key", role: .destructive) { Task { await model.deleteCredential() } }
        } message: {
            Text("Cached cards and local deck definitions will remain on this Mac.")
        }
    }

    private func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 14) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background { ThemedCardSurface(cornerRadius: 18, tintStrength: 0.075, shadowStrength: 0.14) }
        }
    }

    @ViewBuilder
    private var credentialContent: some View {
        switch model.credentialState {
        case .stored where !showingReplaceField:
            HStack {
                StatusPill(title: "API key stored", systemImage: "checkmark.shield.fill", tint: .green)
                Spacer()
                Button("Replace") {
                    showingReplaceField = true
                    apiKeyFocused = true
                }
                Button("Remove", role: .destructive) { showingDeleteConfirmation = true }
            }
            Text("Your API key stays in the macOS login Keychain. RiftBuilder requires Touch ID before its first read, keeps it only in process memory for up to 24 hours, and never displays it after saving.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .validating:
            HStack {
                ProgressView().controlSize(.small)
                Text("Verifying with CardNexus…")
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                Text("CardNexus API key")
                    .font(.headline)
                SecureField("Paste your cnk_live_… key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .focused($apiKeyFocused)
                    .onSubmit { saveKey() }
                    .accessibilityLabel("CardNexus API key")
                    .accessibilityHint("The value is cleared immediately after it is saved")
                HStack {
                    Button("Verify and Save") { saveKey() }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if showingReplaceField {
                        Button("Cancel") {
                            apiKey = ""
                            showingReplaceField = false
                        }
                    }
                }
            }
            .frame(maxWidth: 520, alignment: .leading)

            if case let .invalid(message) = model.credentialState {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text("Create a CardNexus key with exactly inventory:read and inventory:write access; no other scope is needed. Write access lets RiftBuilder move or split physical inventory lines between storage and deck locations. Saving verifies inventory:read only; CardNexus will report a missing inventory:write scope when a physical move is attempted. RiftBuilder stores the key in the macOS login Keychain and requires Touch ID before accessing it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch model.syncState {
        case .idle:
            StatusPill(title: model.isOffline ? "Offline" : "Ready", systemImage: model.isOffline ? "wifi.slash" : "checkmark.circle", tint: model.isOffline ? .orange : .green)
        case let .syncing(progress, message):
            HStack {
                ProgressView(value: progress).frame(width: 90)
                Text(message).foregroundStyle(.secondary)
            }
        case let .failed(message, _):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func saveKey() {
        let submittedKey = apiKey
        apiKey = ""
        Task {
            let saved = await model.saveCredential(submittedKey)
            if saved { showingReplaceField = false }
        }
    }
}
