import SwiftUI

extension View {
    func inWindowModal<ModalContent: View>(
        isPresented: Binding<Bool>,
        preferredSize: CGSize,
        @ViewBuilder content: @escaping () -> ModalContent
    ) -> some View {
        modifier(InWindowModalModifier(isPresented: isPresented, preferredSize: preferredSize, modalContent: content))
    }

    func inWindowModal<Item: Identifiable, ModalContent: View>(
        item: Binding<Item?>,
        preferredSize: CGSize,
        @ViewBuilder content: @escaping (Item) -> ModalContent
    ) -> some View {
        modifier(InWindowItemModalModifier(item: item, preferredSize: preferredSize, modalContent: content))
    }
}

private struct InWindowModalModifier<ModalContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let preferredSize: CGSize
    @ViewBuilder let modalContent: () -> ModalContent

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                InWindowModalContainer(preferredSize: preferredSize, modalContent: modalContent)
            }
        }
    }
}

private struct InWindowItemModalModifier<Item: Identifiable, ModalContent: View>: ViewModifier {
    @Binding var item: Item?
    let preferredSize: CGSize
    @ViewBuilder let modalContent: (Item) -> ModalContent

    func body(content: Content) -> some View {
        content.overlay {
            if let item {
                InWindowModalContainer(preferredSize: preferredSize) {
                    modalContent(item)
                }
            }
        }
    }
}

private struct InWindowModalContainer<ModalContent: View>: View {
    let preferredSize: CGSize
    @ViewBuilder let modalContent: () -> ModalContent

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()

                modalContent()
                    .frame(
                        width: max(0, min(preferredSize.width, geometry.size.width - 40)),
                        height: max(0, min(preferredSize.height, geometry.size.height - 40))
                    )
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.separator.opacity(0.55))
                    }
                    .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .zIndex(10_000)
    }
}
