import Foundation
import AppKit
import Combine
import SwiftUI

enum MusicPlayer {
    case spotify
    case appleMusic
}

@MainActor
final class MusicController: ObservableObject {
    @Published var isRunning = false
    @Published var isPlaying = false
    @Published var title = ""
    @Published var artist = ""
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var isShuffling = false
    @Published var isRepeating = false
    @Published var artwork: NSImage?

    var isScrubbing = false
    private(set) var activePlayer: MusicPlayer = .spotify

    private var trackID = ""
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var syncedPosition: Double = 0
    private var syncedAt = Date()
    private var lastSeekSent = Date.distantPast
    private var playStateHoldUntil = Date.distantPast
    private var shuffleRepeatHoldUntil = Date.distantPast
    private var isPolling = false
    private var isPopoverOpen = false

    init() {
        refresh()
        configureTimers()
    }

    func setPopoverOpen(_ open: Bool) {
        guard open != isPopoverOpen else { return }
        isPopoverOpen = open
        configureTimers()
        if open { refresh() }
    }

    private func configureTimers() {
        pollTimer?.invalidate()
        let poll = Timer(timeInterval: isPopoverOpen ? 1.0 : 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll

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

    private func interpolate() {
        guard isPlaying, !isScrubbing, duration > 0 else { return }
        let elapsed = Date().timeIntervalSince(syncedAt)
        position = min(syncedPosition + elapsed, duration)
    }

    func livePosition(at date: Date = Date()) -> Double {
        guard isPlaying, !isScrubbing, duration > 0 else { return position }
        let elapsed = date.timeIntervalSince(syncedAt)
        return min(syncedPosition + elapsed, duration)
    }

    // MARK: - Commands

    func playPause() {
        isPlaying.toggle()
        if isPlaying { syncedPosition = position; syncedAt = Date() }
        playStateHoldUntil = Date().addingTimeInterval(0.6)
        run(commandScript: "playpause")
        refreshSoon()
    }

    func next()         { run(commandScript: "next track"); refreshSoon() }
    func previous()     { run(commandScript: "previous track"); refreshSoon() }

    func toggleShuffle() {
        isShuffling.toggle()
        shuffleRepeatHoldUntil = Date().addingTimeInterval(0.6)
        switch activePlayer {
        case .spotify:
            run("tell application \"Spotify\" to set shuffling to \(isShuffling)")
        case .appleMusic:
            run("tell application \"Music\" to set shuffle enabled to \(isShuffling)")
        }
        refreshSoon()
    }

    func toggleRepeat() {
        isRepeating.toggle()
        shuffleRepeatHoldUntil = Date().addingTimeInterval(0.6)
        switch activePlayer {
        case .spotify:
            run("tell application \"Spotify\" to set repeating to \(isRepeating)")
        case .appleMusic:
            let mode = isRepeating ? "all" : "off"
            run("tell application \"Music\" to set song repeat to \(mode)")
        }
        refreshSoon()
    }

    func seek(to seconds: Double) {
        let s = max(0, seconds)
        position = s; syncedPosition = s; syncedAt = Date()
        let app = activePlayer == .spotify ? "Spotify" : "Music"
        run("tell application \"\(app)\" to set player position to \(Int(s))")
    }

    func seekLive(_ seconds: Double) {
        let s = max(0, seconds)
        position = s; syncedPosition = s; syncedAt = Date()
        let now = Date()
        if now.timeIntervalSince(lastSeekSent) > 0.15 {
            lastSeekSent = now
            let app = activePlayer == .spotify ? "Spotify" : "Music"
            run("tell application \"\(app)\" to set player position to \(Int(s))")
        }
    }

    // MARK: - Polling

    /// Polls preferred player first, falls back to the other if idle or
    /// not installed. Uses NSWorkspace to check if Spotify.app exists
    /// BEFORE running any AppleScript that references it — osascript
    /// throws a -2741 compiler error when `tell application "Spotify"`
    /// is used and the .app bundle has been deleted.
    private func refresh() {
        if isPolling { return }
        isPolling = true
        let requestTime = Date()

        Task.detached { [weak self] in
            guard let self else { return }

            let spotifyOK = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.spotify.client") != nil

            // Pick player: skip Spotify if not installed
            var player = await self.activePlayer
            if player == .spotify && !spotifyOK { player = .appleMusic }

            // Poll first choice (only if installed)
            var output: String? = nil
            if player == .spotify || player == .appleMusic {
                output = Self.runScriptSync(Self.pollScript(for: player))
            }
            var text = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // Fallback to other player
            if text == "notrunning" || text == "stopped" || text.isEmpty {
                let other: MusicPlayer = player == .spotify ? .appleMusic : .spotify
                if other == .appleMusic || spotifyOK {
                    let otherOutput = Self.runScriptSync(Self.pollScript(for: other))
                    let otherText = (otherOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if otherText != "notrunning" && otherText != "stopped" && !otherText.isEmpty {
                        output = otherOutput
                        player = other
                        text = otherText
                    }
                }
            }

            await self.apply(output, measuredAt: requestTime, player: player)
            await self.finishPoll()
        }
    }

    private func finishPoll() { isPolling = false }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - AppleScript

    /// Poll script for a single player only. Never references more than
    /// one application to avoid osascript compiler bugs.
    private nonisolated static func pollScript(for player: MusicPlayer) -> String {
        switch player {
        case .spotify:
            return """
            if application "Spotify" is running then
                tell application "Spotify"
                    set playerState to player state as string
                    if playerState is "stopped" then return "stopped"
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackArt to artwork url of current track
                    set trackDur to duration of current track
                    set trackPos to player position
                    set trackID to id of current track
                    set trackShuffle to shuffling
                    set trackRepeat to repeating
                    return playerState & "\\n" & trackName & "\\n" & trackArtist & "\\n" & trackArt & "\\n" & trackDur & "\\n" & trackPos & "\\n" & trackID & "\\n" & trackShuffle & "\\n" & trackRepeat
                end tell
            else
                return "notrunning"
            end if
            """
        case .appleMusic:
            return """
            if application "Music" is running then
                tell application "Music"
                    set playerState to player state as string
                    if playerState is "stopped" then return "stopped"
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackDur to duration of current track
                    set trackPos to player position
                    set trackID to database ID of current track
                    set trackShuffle to shuffle enabled
                    set trackRepeat to song repeat as string
                    return playerState & "\\n" & trackName & "\\n" & trackArtist & "\\n" & "no-url" & "\\n" & trackDur & "\\n" & trackPos & "\\n" & trackID & "\\n" & trackShuffle & "\\n" & trackRepeat
                end tell
            else
                return "notrunning"
            end if
            """
        }
    }

    private func run(commandScript: String) {
        let app = activePlayer == .spotify ? "Spotify" : "Music"
        run("tell application \"\(app)\" to \(commandScript)")
    }

    // MARK: - State application

    private func apply(_ output: String?, measuredAt requestTime: Date, player: MusicPlayer) {
        let text = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if text == "notrunning" || text.isEmpty {
            isRunning = false; isPlaying = false
            title = ""; artist = ""
            position = 0; duration = 0
            artwork = nil; trackID = ""
            return
        }

        isRunning = true

        if text == "stopped" {
            activePlayer = player
            isPlaying = false
            title = ""; artist = ""
            position = 0; duration = 0
            artwork = nil; trackID = ""
            return
        }

        let f = text.components(separatedBy: "\n")
        guard f.count >= 9 else { return }

        activePlayer = player

        if Date() >= playStateHoldUntil { isPlaying = (f[0] == "playing") }
        title = f[1]
        artist = f[2]
        let artField = f[3]
        let rawDur = number(f[4])
        duration = player == .spotify ? rawDur / 1000.0 : rawDur
        if !isScrubbing {
            position = number(f[5])
            syncedPosition = position
            syncedAt = requestTime
        }

        if f.count >= 9, Date() >= shuffleRepeatHoldUntil {
            isShuffling = (f[7] == "true")
            isRepeating = player == .appleMusic ? (f[8] != "off") : (f[8] == "true")
        }

        let newTrackID = f[6]
        if newTrackID != trackID {
            trackID = newTrackID
            if player == .spotify {
                loadArtwork(from: artField)
            } else {
                loadAppleMusicArtwork()
            }
        }
    }

    // MARK: - Artwork

    private func loadArtwork(from urlString: String) {
        guard let url = URL(string: urlString) else { artwork = nil; return }
        Task.detached { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data) else { return }
            await self?.setArtwork(image)
        }
    }

    private func loadAppleMusicArtwork() {
        Task.detached { [weak self] in
            guard let image = Self.fetchAppleMusicArtworkSync() else { return }
            await self?.setArtwork(image)
        }
    }

    private func setArtwork(_ image: NSImage) { artwork = image }

    nonisolated static func fetchAppleMusicArtworkSync() -> NSImage? {
        let tmpPath = NSTemporaryDirectory() + "spotinotch_art_\(UUID().uuidString)"
        let script = """
        tell application "Music"
            try
                set artData to raw data of artwork 1 of current track
                set tmpPath to "\(tmpPath)"
                set tmpFile to open for access tmpPath with write permission
                set eof tmpFile to 0
                write artData to tmpFile
                close access tmpFile
            on error errMsg
                try
                    close access tmpFile
                end try
            end try
        end tell
        """
        let _ = runScriptSync(script)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tmpPath)),
              !data.isEmpty else {
            try? FileManager.default.removeItem(atPath: tmpPath)
            return nil
        }
        try? FileManager.default.removeItem(atPath: tmpPath)
        return NSImage(data: data)
    }

    // MARK: - Helpers

    private func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func run(_ script: String) {
        Task.detached { _ = Self.runScriptSync(script) }
    }

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
                FileHandle.standardError.write(Data("[SpotiNotch] osascript error: \(err)".utf8))
            }
            return out
        } catch {
            FileHandle.standardError.write(Data("[SpotiNotch] launch failed: \(error)\n".utf8))
            return nil
        }
    }
}
