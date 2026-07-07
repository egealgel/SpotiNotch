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

/// Shared expand/collapse state driven by mouse-position polling.
@MainActor
final class NotchState: ObservableObject {
    @Published var isExpanded = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single panel, created once at the fixed (expanded) size and never
    // resized. SwiftUI's `.onHover` turned out to be unreliable here: dynamically
    // toggling `ignoresMouseEvents` (needed so the collapsed notch doesn't block
    // clicks to nearby menu bar icons) means the window sometimes never gets a
    // paired "mouse entered" event, so it can silently fail to fire the
    // matching "exited" — the island can get stuck expanded. Instead we poll
    // the global mouse location directly, which sidesteps AppKit's
    // tracking-area/window-activation edge cases entirely.
    private var panel: NSPanel!
    private let spotify = SpotifyController()
    private let state = NotchState()
    private var pollTimer: Timer?
    // Asymmetric hit-testing, like the iPhone Dynamic Island: a small precise
    // zone (the notch itself) triggers opening, but once open the much larger
    // card footprint is what's checked for "did the mouse truly leave" — so
    // brushing near the edge of the expanded card doesn't instantly close it.
    private var notchFrame: NSRect = .zero
    private var cardFrame: NSRect = .zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        let notchSize = Self.computeNotch(screen)
        buildPanel(screen, notchSize: notchSize)

        // Starts collapsed, so start at the slower poll cadence too (see
        // setExpanded, which speeds this up while the card is visible).
        spotify.setPopoverOpen(false)
        registerLoginItem()
        startHoverPolling()
    }

    // MARK: - Geometry

    private static func computeNotch(_ screen: NSScreen) -> CGSize {
        let topInset = screen.safeAreaInsets.top
        let height = topInset > 0 ? topInset : 32
        var width: CGFloat = 205
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width,
           left > 0, right > 0 {
            width = screen.frame.width - left - right
        }
        return CGSize(width: width, height: height)
    }

    /// Opens automatically at login (idempotent), like SpotiWidget.
    private func registerLoginItem() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        try? service.register()
    }

    // Debounce before collapsing, borrowed from boring.notch's ~100ms close
    // delay: a mouse pass that briefly clips the card edge shouldn't cause a
    // visible flicker. Opening stays instant — only closing waits.
    private var outsideSince: Date?
    private let closeDebounce: TimeInterval = 0.12

    /// Checks the real cursor position ~15x/second against `hitFrame`. Cheap
    /// (one point-in-rect test) and immune to the tracking-area pitfalls above.
    private func startHoverPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            let wantsExpanded = self.state.isExpanded
                ? self.cardFrame.contains(mouse)   // already open: generous zone
                : self.notchFrame.contains(mouse)  // closed: precise trigger

            if wantsExpanded {
                self.outsideSince = nil
                if !self.state.isExpanded { self.setExpanded(true) }
            } else if self.state.isExpanded {
                let since = self.outsideSince ?? Date()
                self.outsideSince = since
                if Date().timeIntervalSince(since) >= self.closeDebounce {
                    self.outsideSince = nil
                    self.setExpanded(false)
                }
            }
            }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            state.isExpanded = expanded
        }
        // Only accept clicks while expanded, so the collapsed notch never
        // blocks nearby menu bar icons.
        panel.ignoresMouseEvents = !expanded
        // Nothing is visible while collapsed, so there's no need to poll
        // Spotify at the fast (1s) cadence — back off to 2s, same as
        // SpotiWidget does when its popover is closed. Halves the osascript
        // process spawns during the ~99% of the time nobody's hovering.
        spotify.setPopoverOpen(expanded)
    }

    // MARK: - Window

    private func buildPanel(_ screen: NSScreen, notchSize: CGSize) {
        let w = max(360, notchSize.width + 92)
        let h = notchSize.height + 132
        let frame = NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h)
        cardFrame = frame
        notchFrame = NSRect(x: screen.frame.midX - notchSize.width / 2,
                            y: screen.frame.maxY - notchSize.height,
                            width: notchSize.width, height: notchSize.height)

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
        panel.ignoresMouseEvents = true   // starts collapsed: fully click-through

        let root = NotchView(notchWidth: notchSize.width, notchHeight: notchSize.height,
                             cardWidth: w, cardHeight: h)
            .environmentObject(spotify)
            .environmentObject(state)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFrontRegardless()
    }
}
