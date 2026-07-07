import Foundation
import AppKit
import Combine
import SwiftUI

/// Talks to the Spotify desktop app over AppleScript (via `osascript`) and
/// publishes now-playing state for the SwiftUI views to observe.
@MainActor
final class SpotifyController: ObservableObject {
    // Now-playing state
    @Published var isRunning = false
    @Published var isPlaying = false
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var position: Double = 0      // seconds
    @Published var duration: Double = 0      // seconds
    @Published var volume: Double = 0        // 0...100
    @Published var isShuffling = false
    @Published var isRepeating = false
    @Published var artwork: NSImage?

    // Album-derived gradient colors for the panel background.
    @Published var gradientTop: Color = Color(white: 0.17)
    @Published var gradientBottom: Color = Color(white: 0.06)

    // Track whether the user is dragging a slider so polling doesn't fight them.
    var isScrubbing = false
    var isAdjustingVolume = false

    private var trackID = ""
    private var pollTimer: Timer?
    private var tickTimer: Timer?

    // For smooth local interpolation of the progress bar between polls.
    private var syncedPosition: Double = 0
    private var syncedAt = Date()

    private var lastVolumeSent = Date.distantPast
    private var lastSeekSent = Date.distantPast
    private var volumeHoldUntil = Date.distantPast
    private var playStateHoldUntil = Date.distantPast
    private var shuffleRepeatHoldUntil = Date.distantPast
    private var isPolling = false
    private var isPopoverOpen = false

    init() {
        refresh()
        configureTimers()
    }

    /// The popover reports its visibility so we can back off when it's closed:
    /// no per-frame interpolation and slower polling (the menu bar only needs
    /// the occasional title change), which cuts idle CPU and AppleScript spawns.
    func setPopoverOpen(_ open: Bool) {
        guard open != isPopoverOpen else { return }
        isPopoverOpen = open
        configureTimers()
        if open { refresh() }   // update immediately on open
    }

    private func configureTimers() {
        // Poll: 1s while open (for accurate progress), 2s while closed.
        // `.common` mode so it keeps firing during popover/slider tracking.
        pollTimer?.invalidate()
        let poll = Timer(timeInterval: isPopoverOpen ? 1.0 : 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

        // The 0.25s progress interpolation only matters while the popover is
        // visible, so it doesn't run at all when closed.
        tickTimer?.invalidate()
        tickTimer = nil
        if isPopoverOpen {
            let tick = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.interpolate() }
            }
            RunLoop.main.add(tick, forMode: .common)
            tickTimer = tick
        }
    }

    /// Moves the progress bar forward locally so it doesn't visibly jump once a second.
    private func interpolate() {
        // Skip while the user is dragging a slider so we don't add extra
        // re-renders that make the drag feel like it's snagging.
        guard isPlaying, !isScrubbing, !isAdjustingVolume, duration > 0 else { return }
        let elapsed = Date().timeIntervalSince(syncedAt)
        position = min(syncedPosition + elapsed, duration)
    }

    /// Computes the current playback position at `date` without waiting for
    /// the next poll/tick — call this from a `TimelineView` for a genuinely
    /// smooth (not stepped) progress bar, since it can be evaluated on every
    /// frame instead of only every 0.25s.
    func livePosition(at date: Date = Date()) -> Double {
        guard isPlaying, !isScrubbing, duration > 0 else { return position }
        let elapsed = date.timeIntervalSince(syncedAt)
        return min(syncedPosition + elapsed, duration)
    }

    // MARK: - Commands

    func playPause() {
        // Flip immediately so the icon reacts to the click, then reconcile with
        // Spotify on the next poll (held briefly so a stale read can't flicker).
        isPlaying.toggle()
        if isPlaying { syncedPosition = position; syncedAt = Date() }
        playStateHoldUntil = Date().addingTimeInterval(0.6)
        run("tell application \"Spotify\" to playpause")
        refreshSoon()
    }

    func next()         { run("tell application \"Spotify\" to next track"); refreshSoon() }
    func previous()     { run("tell application \"Spotify\" to previous track"); refreshSoon() }

    func toggleShuffle() {
        isShuffling.toggle()
        shuffleRepeatHoldUntil = Date().addingTimeInterval(0.6)
        run("tell application \"Spotify\" to set shuffling to \(isShuffling)")
        refreshSoon()
    }

    func toggleRepeat() {
        isRepeating.toggle()
        shuffleRepeatHoldUntil = Date().addingTimeInterval(0.6)
        run("tell application \"Spotify\" to set repeating to \(isRepeating)")
        refreshSoon()
    }

    func setVolume(_ value: Double) {
        let v = Int(max(0, min(100, value)))
        // Trust our local value briefly so a stale poll can't snap the thumb
        // back before Spotify reports the new volume.
        volumeHoldUntil = Date().addingTimeInterval(0.6)
        run("tell application \"Spotify\" to set sound volume to \(v)")
    }

    /// Called continuously while dragging the volume slider. Applies immediately
    /// but throttles the AppleScript calls so we don't spawn dozens of processes.
    func setVolumeLive(_ value: Double) {
        volume = value
        let now = Date()
        if now.timeIntervalSince(lastVolumeSent) > 0.1 {
            lastVolumeSent = now
            setVolume(value)
        }
    }

    func seek(to seconds: Double) {
        let s = max(0, seconds)
        // Rebase interpolation to the new spot so the thumb doesn't snap back to
        // the old position after release, before the next poll catches up.
        position = s
        syncedPosition = s
        syncedAt = Date()
        run("tell application \"Spotify\" to set player position to \(Int(s))")
    }

    /// Called continuously while dragging the progress bar. Tracks the thumb
    /// immediately and seeks Spotify live (throttled), like the volume slider.
    func seekLive(_ seconds: Double) {
        let s = max(0, seconds)
        position = s
        syncedPosition = s
        syncedAt = Date()
        let now = Date()
        if now.timeIntervalSince(lastSeekSent) > 0.15 {
            lastSeekSent = now
            run("tell application \"Spotify\" to set player position to \(Int(s))")
        }
    }

    func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Polling

    /// Fetches the full state in one AppleScript round-trip on a background queue.
    private func refresh() {
        // Skip if a previous poll is still in flight so slow responses can't
        // pile up and cause the UI to flicker between stale and fresh values.
        if isPolling { return }
        isPolling = true

        let script = """
        if application "Spotify" is running then
            tell application "Spotify"
                set playerState to player state as string
                if playerState is "stopped" then
                    return "stopped"
                end if
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackArt to artwork url of current track
                set trackDur to duration of current track
                set trackPos to player position
                set trackVol to sound volume
                set trackIdent to id of current track
                set trackShuffle to shuffling
                set trackRepeat to repeating
                return playerState & "\\n" & trackName & "\\n" & trackArtist & "\\n" & trackAlbum & "\\n" & trackArt & "\\n" & trackDur & "\\n" & trackPos & "\\n" & trackVol & "\\n" & trackIdent & "\\n" & trackShuffle & "\\n" & trackRepeat
            end tell
        else
            return "notrunning"
        end if
        """

        // Stamp the request time *before* the AppleScript round-trip (which can
        // take 100-200ms) rather than after, so `syncedAt` reflects when Spotify
        // actually measured `player position`, not when we finished hearing
        // back about it. Using the post-completion time biased every poll's
        // baseline by however long that particular call happened to take,
        // which showed up as the progress bar visibly jumping/correcting itself
        // each time a new poll landed.
        let requestTime = Date()
        Task.detached { [weak self] in
            let output = SpotifyController.runScriptSync(script)
            await self?.apply(output, measuredAt: requestTime)
            await self?.finishPoll()
        }
    }

    private func finishPoll() {
        isPolling = false
    }

    /// Poll again shortly after a command so the UI reflects the change quickly.
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh()
        }
    }

    private func apply(_ output: String?, measuredAt requestTime: Date) {
        let text = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if text == "notrunning" || text.isEmpty {
            isRunning = false
            isPlaying = false
            title = ""; artist = ""; album = ""
            position = 0; duration = 0
            artwork = nil
            trackID = ""
            return
        }

        isRunning = true

        if text == "stopped" {
            isPlaying = false
            title = ""; artist = ""; album = ""
            position = 0; duration = 0
            artwork = nil
            trackID = ""
            return
        }

        let f = text.components(separatedBy: "\n")
        guard f.count >= 9 else { return }

        if Date() >= playStateHoldUntil { isPlaying = (f[0] == "playing") }
        title = f[1]
        artist = f[2]
        album = f[3]
        let artURL = f[4]
        duration = number(f[5]) / 1000.0                 // ms -> s
        if !isScrubbing {
            position = number(f[6])
            syncedPosition = position
            syncedAt = requestTime
        }
        if !isAdjustingVolume, Date() >= volumeHoldUntil { volume = number(f[7]) }

        if f.count >= 11, Date() >= shuffleRepeatHoldUntil {
            isShuffling = (f[9] == "true")
            isRepeating = (f[10] == "true")
        }

        let newTrackID = f[8]
        if newTrackID != trackID {
            trackID = newTrackID
            loadArtwork(from: artURL)
        }
    }

    /// Parses a number from AppleScript, tolerating locales that use a comma
    /// decimal separator (e.g. Turkish returns "277,84" for player position).
    private func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func loadArtwork(from urlString: String) {
        guard let url = URL(string: urlString) else { artwork = nil; return }
        Task.detached { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data) else { return }
            await self?.setArtwork(image)
        }
    }

    private func setArtwork(_ image: NSImage) {
        artwork = image
        // Derive the background gradient from the album's dominant color.
        Task.detached { [weak self] in
            guard let base = SpotifyController.averageColor(image) else { return }
            let top = base.adjustedForBackground()
            let bottom = base.darkened(to: 0.12)
            await self?.setGradient(top: Color(nsColor: top), bottom: Color(nsColor: bottom))
        }
    }

    private func setGradient(top: Color, bottom: Color) {
        gradientTop = top
        gradientBottom = bottom
    }

    /// Averages the whole artwork down to a single representative color by
    /// drawing it into a 1×1 bitmap.
    nonisolated static func averageColor(_ image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                       blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    // MARK: - AppleScript plumbing

    private func run(_ script: String) {
        Task.detached { _ = SpotifyController.runScriptSync(script) }
    }

    /// Runs an AppleScript via `osascript` and returns stdout. Safe to call off the main thread.
    nonisolated static func runScriptSync(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                FileHandle.standardError.write(Data("[SpotiWidget] osascript error: \(err)".utf8))
            }
            return out
        } catch {
            FileHandle.standardError.write(Data("[SpotiWidget] osascript launch failed: \(error)\n".utf8))
            return nil
        }
    }
}

private extension NSColor {
    /// Punches up an averaged (usually muted) color into a pleasing, legible
    /// background tone: more saturated, mid brightness.
    func adjustedForBackground() -> NSColor {
        guard let c = usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        s = min(max(s * 1.5, 0.4), 0.85)
        b = min(max(b * 1.1, 0.34), 0.62)
        return NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
    }

    /// Same hue at a fixed low brightness for the bottom gradient stop.
    func darkened(to brightness: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.deviceRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: s * 0.9, brightness: brightness, alpha: 1)
    }
}
