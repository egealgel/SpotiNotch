import AppKit
import SwiftUI
import Combine
import ServiceManagement

// Menu-bar-less, dock-less agent that floats a Dynamic-Island-style widget at
// the notch. The process entry runs on the main thread, so assume main-actor.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// Shared expand/collapse state driven by hover.
@MainActor
final class NotchState: ObservableObject {
    @Published var isExpanded = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private let spotify = SpotifyController()
    private let state = NotchState()
    private var cancellables = Set<AnyCancellable>()

    private var notchSize: CGSize = .zero
    private let sidePad: CGFloat = 46          // room on each side of the notch
    private let expandedWidth: CGFloat = 380
    private let expandedDrop: CGFloat = 132     // how far it hangs below the notch

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        computeNotch(screen)
        buildPanel(screen)

        // The widget is always visible, so keep polling at the faster cadence.
        spotify.setPopoverOpen(true)
        registerLoginItem()

        state.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                guard let self, let screen = NSScreen.main else { return }
                let target = expanded ? self.expandedFrame(screen) : self.collapsedFrame(screen)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.34
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    self.panel.animator().setFrame(target, display: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    private func computeNotch(_ screen: NSScreen) {
        let topInset = screen.safeAreaInsets.top
        let height = topInset > 0 ? topInset : 32
        var width: CGFloat = 205
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width,
           left > 0, right > 0 {
            width = screen.frame.width - left - right
        }
        notchSize = CGSize(width: width, height: height)
    }

    private func collapsedFrame(_ screen: NSScreen) -> NSRect {
        let w = notchSize.width + sidePad * 2
        let h = notchSize.height
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    private func expandedFrame(_ screen: NSScreen) -> NSRect {
        let w = max(expandedWidth, notchSize.width + sidePad * 2)
        let h = notchSize.height + expandedDrop
        return NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
    }

    // MARK: - Window

    /// Opens automatically at login (idempotent), like SpotiWidget.
    private func registerLoginItem() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        try? service.register()
    }

    private func buildPanel(_ screen: NSScreen) {
        let frame = collapsedFrame(screen)
        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        let root = NotchView(notchWidth: notchSize.width, notchHeight: notchSize.height)
            .environmentObject(spotify)
            .environmentObject(state)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFrontRegardless()
    }
}
