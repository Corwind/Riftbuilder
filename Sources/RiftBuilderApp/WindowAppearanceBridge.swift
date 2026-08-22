import AppKit
import SwiftUI

struct LegacyWindowAppearanceBridgeUnused: NSViewRepresentable {
    let appearance: AppAppearance

    func makeNSView(context: Context) -> LegacyAppearanceViewUnused {
        let view = LegacyAppearanceViewUnused()
        view.appAppearance = appearance
        return view
    }

    func updateNSView(_ view: LegacyAppearanceViewUnused, context: Context) {
        view.appAppearance = appearance
        view.applyToWindow()
    }
}

final class LegacyAppearanceViewUnused: NSView {
    var appAppearance: AppAppearance = .system {
        didSet { applyToWindow() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    func applyToWindow() {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.appearance = appAppearance.appKitAppearance
        window.contentView?.needsDisplay = true
        window.contentView?.displayIfNeeded()
    }
}
