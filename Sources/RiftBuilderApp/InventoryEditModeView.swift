import RiftBuilderCore
import SwiftUI

struct InventoryEditModeView: View {
    @Bindable var model: AppModel
    let finishEditing: () -> Void

    @State private var drafts: [InventoryQuantityDraftKey: Int] = [:]
    @State private var isSaving = false
    @State private var isConfirmingDiscard = false

    private let locationColumns = [GridItem(.adaptive(minimum: 270), spacing: 10)]

    private var editLocations: [LocationPolicy] {
        model.locations
            .filter { $0.kind != .unavailable }
            .sorted { lhs, rhs in
                if lhs.normalizedName == model.inventoryLocationFilter { return true }
                if rhs.normalizedName == model.inventoryLocationFilter { return false }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private var changedCardIDs: Set<String> {
        Set(
            drafts.compactMap { key, quantity in
                quantity == originalQuantity(cardID: key.cardID, locationKey: key.locationKey)
                    ? nil : key.cardID
            })
    }


    private var hasChanges: Bool { !changedCardIDs.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            editHeader
            Divider()
            if model.filteredInventory.isEmpty {
                ContentUnavailableView.search(text: model.inventorySearch)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.filteredInventory) { card in
                            inventoryCardEditor(card)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Discard inventory changes?", isPresented: $isConfirmingDiscard) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive, action: finishEditing)
        } message: {
            Text("Your unsaved location quantities will be lost. CardNexus has not been changed.")
        }
    }

    private var editHeader: some View {
        HStack(spacing: 8) {
            if hasChanges {
                StatusPill(
                    title: "\(changedCardIDs.count) changed",
                    systemImage: "pencil",
                    tint: .accentColor
                )
            }
            Spacer()
            if isSaving { ProgressView().controlSize(.small) }
            Button("Revert") { drafts.removeAll() }
                .disabled(!hasChanges || isSaving)
            Button("Cancel") {
                if hasChanges {
                    isConfirmingDiscard = true
                } else {
                    finishEditing()
                }
            }
            .disabled(isSaving)
            Button("Save Changes") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasChanges || isSaving)
            .help(saveButtonHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var saveButtonHelp: String {
        if !hasChanges { return "Change a location quantity before saving" }
        return "Save location quantities to CardNexus"
    }
    private func inventoryCardEditor(_ card: AppInventoryCard) -> some View {
        let editedTotal = editedTotal(for: card)
        let totalDelta = editedTotal - card.availability.totalOwned
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CardArtwork(card: card, width: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.identity.displayName).font(.headline)
                    Text([card.identity.cardType, card.expansion].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    QuantityBadge(title: "Owned", value: editedTotal)
                    if changedCardIDs.contains(card.id) {
                        Label(
                            totalDelta == 0
                                ? "Locations changed"
                                : "\(totalDelta > 0 ? "+" : "")\(totalDelta) total",
                            systemImage: totalDelta == 0
                                ? "arrow.left.arrow.right"
                                : totalDelta > 0 ? "plus.circle.fill" : "minus.circle.fill"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }

            LazyVGrid(columns: locationColumns, alignment: .leading, spacing: 10) {
                ForEach(editLocations) { location in
                    InventoryLocationQuantityControl(
                        location: location,
                        quantity: quantityBinding(card: card, location: location),
                        isReadOnly: location.normalizedName == "__unlocated__"
                    )
                }
            }
        }
        .padding(14)
        .background {
            ThemedCardSurface(
                cornerRadius: 12,
                tintStrength: changedCardIDs.contains(card.id) ? 0.10 : 0.055,
                shadowStrength: 0.07
            )
        }
    }
    private func quantityBinding(card: AppInventoryCard, location: LocationPolicy) -> Binding<Int> {
        let key = InventoryQuantityDraftKey(cardID: card.id, locationKey: location.normalizedName)
        let original = originalQuantity(card: card, locationKey: location.normalizedName)
        return Binding(
            get: { drafts[key] ?? original },
            set: { newValue in
                let quantity = max(0, newValue)
                if quantity == original {
                    drafts[key] = nil
                } else {
                    drafts[key] = quantity
                }
            }
        )
    }

    private func editedTotal(for card: AppInventoryCard) -> Int {
        var quantities = card.locations.reduce(into: [String: Int]()) { result, location in
            result[location.normalizedName, default: 0] += location.quantity
        }
        for location in editLocations {
            let key = InventoryQuantityDraftKey(cardID: card.id, locationKey: location.normalizedName)
            if let draft = drafts[key] { quantities[location.normalizedName] = draft }
        }
        return quantities.values.reduce(0, +)
    }

    private func originalQuantity(cardID: String, locationKey: String) -> Int {
        guard let card = model.inventory.first(where: { $0.id == cardID }) else { return 0 }
        return originalQuantity(card: card, locationKey: locationKey)
    }

    private func originalQuantity(card: AppInventoryCard, locationKey: String) -> Int {
        card.locations
            .filter { $0.normalizedName == locationKey }
            .reduce(0) { $0 + $1.quantity }
    }

    private var edits: [InventoryLocationQuantityEdit] {
        model.inventory.compactMap { card in
            guard changedCardIDs.contains(card.id) else { return nil }
            var quantities = card.locations.reduce(into: [String: Int]()) { result, location in
                result[location.normalizedName, default: 0] += location.quantity
            }
            for location in editLocations {
                let key = InventoryQuantityDraftKey(cardID: card.id, locationKey: location.normalizedName)
                if let draft = drafts[key] { quantities[location.normalizedName] = draft }
            }
            return InventoryLocationQuantityEdit(nameSlug: card.id, quantitiesByLocation: quantities)
        }
    }

    private func save() async {
        guard hasChanges else { return }
        isSaving = true
        let saved = await model.saveInventoryLocationQuantities(edits)
        isSaving = false
        if saved { finishEditing() }
    }
}

private struct InventoryQuantityDraftKey: Hashable {
    let cardID: String
    let locationKey: String
}

private struct InventoryLocationQuantityControl: View {
    let location: LocationPolicy
    @Binding var quantity: Int
    let isReadOnly: Bool

    var body: some View {
        HStack(spacing: 9) {
            LocationColorSwatch(value: location.color, size: 13)
            Image(systemName: location.kind.systemImage)
                .foregroundStyle(location.kind == .storage ? .green : .secondary)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(location.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(isReadOnly ? "Move out only" : location.kind.appTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                Button {
                    quantity = max(0, quantity - 1)
                } label: {
                    Image(systemName: "minus")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(quantity == 0)
                .accessibilityLabel("Remove one from \(location.displayName)")

                Text(quantity, format: .number)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 28)
                    .accessibilityLabel("\(quantity) at \(location.displayName)")

                Button {
                    quantity += 1
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .disabled(isReadOnly)
                .accessibilityLabel("Add one to \(location.displayName)")
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
    }
}
