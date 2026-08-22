import SwiftUI

struct PhysicalAssemblyHost: ViewModifier {
    @Bindable var workflow: PhysicalAssemblyModel
    let appModel: AppModel

    func body(content: Content) -> some View {
        content
            .toolbar {
                if appModel.destination == .decks, appModel.selectedDeck?.state == .assembled {
                    ToolbarItemGroup {
                        Button {
                            Task { await workflow.beginAssembly(deckID: appModel.selectedDeckID, appModel: appModel) }
                        } label: {
                            Label("Assemble", systemImage: "shippingbox.and.arrow.backward")
                        }
                        .help("Review physical cards to move into this deck")
                        .disabled(workflow.phase != .idle)

                        Button {
                            Task { await workflow.beginDisassembly(deckID: appModel.selectedDeckID, appModel: appModel) }
                        } label: {
                            Label("Disassemble", systemImage: "shippingbox.and.arrow.forward")
                        }
                        .help("Move this deck's physical cards to an explicit storage location")
                        .disabled(workflow.phase != .idle)
                    }
                }
            }
            .sheet(isPresented: $workflow.isConfirmationPresented) {
                PhysicalAssemblyConfirmationView(workflow: workflow, appModel: appModel)
            }
            .sheet(isPresented: $workflow.isStoragePickerPresented) {
                DisassemblyDestinationView(workflow: workflow, deckID: appModel.selectedDeckID, appModel: appModel)
            }
    }
}
