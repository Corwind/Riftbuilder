import RiftBuilderCore
import SwiftUI

struct LocationsView: View {
    @Bindable var model: AppModel
    @State private var isCreatingLocation = false

    var body: some View {
        Group {
            switch model.locationLoadState {
            case .idle where model.locations.isEmpty, .loading where model.locations.isEmpty:
                LoadingStateView(message: "Loading locations…")
            case let .failed(message) where model.locations.isEmpty:
                FailureStateView(title: "Locations unavailable", message: message) {
                    Task { await model.loadLocations() }
                }
            default:
                if model.locations.isEmpty {
                    ContentUnavailableView {
                        Label("No Locations", systemImage: "shippingbox")
                    } description: {
                        Text("Create a location here or synchronize locations already present in CardNexus.")
                    } actions: {
                        Button("Create Location") { isCreatingLocation = true }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            locationSummary
                            ForEach(model.locations) { policy in
                                LocationPolicyRow(policy: policy, model: model)
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Locations")
        .toolbar {
            Button {
                isCreatingLocation = true
            } label: {
                Label("Create Location", systemImage: "plus")
            }
            Button {
                Task { await model.loadLocations() }
            } label: {
                Label("Refresh Locations", systemImage: "arrow.clockwise")
            }
        }
        .sheet(isPresented: $isCreatingLocation) {
            CreateLocationView(model: model)
        }
    }

    private var locationSummary: some View {
        HStack(spacing: 18) {
            Label("\(model.locations.filter { $0.kind == .storage }.count) storage", systemImage: "shippingbox")
            Label("\(model.locations.filter { $0.kind == .deck }.count) decks", systemImage: "rectangle.stack")
            Label("\(model.locations.filter { $0.kind == .unavailable }.count) unavailable", systemImage: "nosign")
            Spacer()
            Text("Storage locations count as available when deck building.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background { ThemedCardSurface(cornerRadius: 12, tintStrength: 0.055, shadowStrength: 0.07) }
    }
}

private struct LocationPolicyRow: View {
    let policy: LocationPolicy
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            LocationColorSwatch(value: policy.color, size: 18)
            Image(systemName: policy.kind.systemImage)
                .font(.title2)
                .foregroundStyle(policy.kind == .storage ? .green : .secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(policy.displayName).font(.headline)
                Text(policy.normalizedName == "__unlocated__" ? "Cards without a CardNexus location" : "CardNexus location")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Classification", selection: Binding(
                get: { policy.kind },
                set: { kind in Task { await model.updateLocation(policy, kind: kind, linkedDeckID: policy.linkedDeckID) } }
            )) {
                ForEach(LocationKind.allCases, id: \.self) { kind in
                    Label(kind.appTitle, systemImage: kind.systemImage).tag(kind)
                }
            }
            .frame(width: 165)
            if policy.kind == .deck {
                Picker("Linked deck", selection: Binding<UUID?>(
                    get: { policy.linkedDeckID },
                    set: { id in Task { await model.updateLocation(policy, kind: .deck, linkedDeckID: id) } }
                )) {
                    Text("Not linked").tag(UUID?.none)
                    ForEach(model.decks) { deck in Text(deck.name).tag(Optional(deck.id)) }
                }
                .frame(width: 170)
            }
        }
        .padding(14)
        .background { ThemedCardSurface(cornerRadius: 12, tintStrength: 0.055, shadowStrength: 0.07) }
        .accessibilityElement(children: .contain)
    }
}
