import AppKit
import SwiftUI

struct WindowAppearanceBridge: NSViewRepresentable {
    let appearance: AppAppearance
    let transparency: Double
    let accent: AppAccentPalette
    let secondaryAccent: AppAccentPalette?

    func makeNSView(context: Context) -> StableAppearanceView {
        let view = StableAppearanceView()
        view.configure(
            appearance: appearance,
            transparency: transparency,
            accent: accent,
            secondaryAccent: secondaryAccent
        )
        return view
    }

    func updateNSView(_ view: StableAppearanceView, context: Context) {
        view.configure(
            appearance: appearance,
            transparency: transparency,
            accent: accent,
            secondaryAccent: secondaryAccent
        )
    }
}

final class StableAppearanceView: NSView {
    private var desiredAppearance: AppAppearance = .system
    private var desiredTransparency = 0.0
    private var desiredAccent: AppAccentPalette = .riftBlue
    private var desiredSecondaryAccent: AppAccentPalette?
    private var fullscreenBackdropRequested = false
    private var fullscreenBackdrop: FullscreenBackdropHostingView?
    private var applyScheduled = false
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    func configure(
        appearance: AppAppearance,
        transparency: Double,
        accent: AppAccentPalette,
        secondaryAccent: AppAccentPalette?
    ) {
        let clampedTransparency = min(max(transparency, 0), 1)
        let changed = desiredAppearance != appearance
            || desiredTransparency != clampedTransparency
            || desiredAccent != accent
            || desiredSecondaryAccent != secondaryAccent
        desiredAppearance = appearance
        desiredTransparency = clampedTransparency
        desiredAccent = accent
        desiredSecondaryAccent = secondaryAccent
        if changed { scheduleApply() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        guard let window else { return }
        fullscreenBackdropRequested = window.styleMask.contains(.fullScreen)
        let windowNotifications = [
            NSWindow.willEnterFullScreenNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didResizeNotification,
        ]
        for name in windowNotifications {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == NSWindow.willEnterFullScreenNotification {
                        self.fullscreenBackdropRequested = true
                    } else if name == NSWindow.didExitFullScreenNotification {
                        self.fullscreenBackdropRequested = false
                    }
                    self.scheduleApply()
                    if name == NSWindow.didEnterFullScreenNotification {
                        self.scheduleSettledFullscreenApply()
                    }
                }
            })
        }
        windowObservers.append(NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleApply() }
        })
        scheduleApply()
    }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            self.applyToWindow()
        }
    }

    private func scheduleSettledFullscreenApply() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.scheduleApply()
        }
    }

    private func applyToWindow() {
        guard let window else { return }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }

        let desiredNSAppearance = desiredAppearance.appKitAppearance
        if desiredAppearance == .system || window.appearance?.name != desiredNSAppearance?.name {
            window.appearance = desiredNSAppearance
        }

        let isMatte = desiredTransparency <= 0.001
        window.isOpaque = isMatte
        window.backgroundColor = isMatte ? .windowBackgroundColor : .clear
        updateFullscreenBackdrop(in: window)
        window.attachedSheet?.appearance = desiredNSAppearance
        window.childWindows?.forEach { $0.appearance = desiredNSAppearance }
        window.contentView?.needsDisplay = true
    }

    private func updateFullscreenBackdrop(in window: NSWindow) {
        let shouldShow = fullscreenBackdropRequested || window.styleMask.contains(.fullScreen)
        guard shouldShow else {
            fullscreenBackdrop?.isHidden = true
            return
        }
        guard let contentView = window.contentView,
              let toolbarWindow = fullscreenToolbarWindow(for: window),
              let targetView = toolbarWindow.contentView
        else {
            fullscreenBackdrop?.isHidden = true
            return
        }

        let rootView = FullscreenWindowBackdrop(
            colors: [desiredAccent.color, desiredSecondaryAccent?.color].compactMap { $0 },
            transparency: desiredTransparency,
            sidebarWidth: measuredSidebarWidth(in: contentView),
            colorScheme: desiredAppearance.colorScheme
        )

        if let fullscreenBackdrop {
            fullscreenBackdrop.rootView = rootView
            if fullscreenBackdrop.superview !== targetView {
                fullscreenBackdrop.removeFromSuperview()
                insertBackdrop(fullscreenBackdrop, into: targetView)
            }
            fullscreenBackdrop.frame = targetView.bounds
            fullscreenBackdrop.isHidden = false
        } else {
            let backdrop = FullscreenBackdropHostingView(rootView: rootView)
            backdrop.frame = targetView.bounds
            backdrop.autoresizingMask = [.width, .height]
            insertBackdrop(backdrop, into: targetView)
            fullscreenBackdrop = backdrop
        }
    }

    private func fullscreenToolbarWindow(for mainWindow: NSWindow) -> NSWindow? {
        NSApp.windows.first { candidate in
            String(describing: type(of: candidate)).contains("ToolbarFullScreenWindow")
                && abs(candidate.frame.width - mainWindow.frame.width) < 2
        }
    }

    private func insertBackdrop(_ backdrop: NSView, into targetView: NSView) {
        if let firstSubview = targetView.subviews.first {
            targetView.addSubview(backdrop, positioned: .below, relativeTo: firstSubview)
        } else {
            targetView.addSubview(backdrop)
        }
    }

    private func measuredSidebarWidth(in contentView: NSView) -> CGFloat {
        let candidates = splitViews(in: contentView).filter { $0.isVertical && $0.subviews.count >= 2 }
        guard let splitView = candidates.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
            return 215
        }
        let sidebarCandidates = splitView.subviews.filter { subview in
            !subview.isHidden
                && subview.frame.minX <= 1
                && subview.frame.width >= 150
                && subview.frame.width <= 320
        }
        return sidebarCandidates.map(\.frame.width).max() ?? 215
    }

    private func splitViews(in view: NSView) -> [NSSplitView] {
        var result = view is NSSplitView ? [view as! NSSplitView] : []
        for subview in view.subviews {
            result.append(contentsOf: splitViews(in: subview))
        }
        return result
    }

    private func stopObservingWindow() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        fullscreenBackdrop?.removeFromSuperview()
        fullscreenBackdrop = nil
    }
}

private struct FullscreenWindowBackdrop: View {
    let colors: [Color]
    let transparency: Double
    let sidebarWidth: CGFloat
    let colorScheme: ColorScheme?

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
            .frame(width: sidebarWidth)

            ThemeTintedSurface(
                colors: colors,
                transparency: transparency,
                lightTintOpacity: 0.28,
                darkTintOpacity: 0.20,
                direction: (.leading, .trailing)
            )
        }
        .preferredColorScheme(colorScheme)
    }
}

private final class FullscreenBackdropHostingView: NSHostingView<FullscreenWindowBackdrop>, @unchecked Sendable {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
