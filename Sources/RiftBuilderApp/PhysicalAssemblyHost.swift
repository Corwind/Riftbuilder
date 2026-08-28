import SwiftUI

struct PhysicalAssemblyHost: ViewModifier {
    @Bindable var workflow: PhysicalAssemblyModel
    let appModel: AppModel

    func body(content: Content) -> some View {
        content
            .toolbar {
                if appModel.destination == .decks, let deck = appModel.selectedDeck {
                    ToolbarItemGroup {
                        if deck.state == .assembled {
                            Button {
                                Task { await workflow.beginDisassembly(deckID: appModel.selectedDeckID, appModel: appModel) }
                            } label: {
                                Label("Disassemble", systemImage: "rectangle.stack.badge.minus")
                            }
                            .help("Return this deck's physical cards to their previous storage locations")
                            .disabled(workflow.phase != .idle)
                        }
                    }
                }
            }
            .inWindowModal(isPresented: $workflow.isConfirmationPresented, preferredSize: CGSize(width: 900, height: 700)) {
                PhysicalAssemblyConfirmationView(workflow: workflow, appModel: appModel)
            }
    }
}
