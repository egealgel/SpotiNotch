import Foundation
import AppKit
import Combine
import SwiftUI

/// Which music player is currently being controlled.
enum MusicPlayer {
    case spotify
    case appleMusic
}

/// Talks to Spotify or Apple Music over AppleScript (via `osascript`) and
/// publishes now-playing state for the SwiftUI views to observe.
@MainActor
final class MusicController: ObservableObject {
    // Now-playing state
    @Published var isRunning = false
    @Published var isPlaying = false
    @Published var title = ""
    @Published var artist = ""
    @Published var position: Double = 0      // seconds
    @Published var duration: Double = 0      // seconds
    @Published var isShuffling = false
    @Published var isRepeating = false
    @Published var artwork: NSImage?

    /// Track whether the user is dragging the progress bar.
    var isScrubbing = false

    /// The currently active player, updated every poll based on which app is
    /// actually playing.
    private(set) var activePlayer: MusicPlayer = .spotify

    private var trackID = ""
    private var pollTimer: Timer?
    private var tickTimer: Timer?

    // For smooth local interpolation of the progress bar between polls.
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

    /// The popover reports its visibility so we can back off when it's closed.
    func setPopoverOpen(_ open: Bool) {
        guard open != isPopoverOpen else { return }
        isPopoverOpen = open
        configureTimers()
        if open { refresh() }
    }

    private func configureTimers() {
        pollTimer?.invalidate()
        let interval: TimeInterval = isPopoverOpen ? 1.0 : 2.0
        let poll = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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

    /// Moves the progress bar forward locally between polls.
    private func interpolate() {
        guard isPlaying, !isScrubbing, duration > 0 else { return }
        let elapsed = Date().timeIntervalSince(syncedAt)
        position = min(syncedPosition + elapsed, duration)
    }

    /// Computes live playback position for TimelineView (smooth progress bar).
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
        position = s
        syncedPosition = s
        syncedAt = Date()
        let app = activePlayer == .spotify ? "Spotify" : "Music"
        run("tell application \"\(app)\" to set player position to \(Int(s))")
    }

    func seekLive(_ seconds: Double) {
        let s = max(0, seconds)
        position = s
        syncedPosition = s
        syncedAt = Date()
        let now = Date()
        if now.timeIntervalSince(lastSeekSent) > 0.15 {
            lastSeekSent = now
            let app = activePlayer == .spotify ? "Spotify" : "Music"
            run("tell application \"\(app)\" to set player position to \(Int(s))")
        }
    }

    // MARK: - Polling

    /// Runs one osascript that checks both players and returns the state of
    /// whichever has the highest priority (playing > paused > stopped).
    private func refresh() {
        if isPolling { return }
        isPolling = true
        let requestTime = Date()

        Task.detached { [weak self] in
            let output = Self.runScriptSync(Self.unifiedPollScript())
            await self?.applyUnified(output, measuredAt: requestTime)
            await self?.finishPoll()
        }
    }

    private func finishPoll() { isPolling = false }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - AppleScript

    /// One script checking both players. Priority: playing > paused > stopped.
    /// Returns a tagged first line ("SPOTIFY" / "MUSIC" / "SPOTIFY_STOPPED" /
    /// "MUSIC_STOPPED" / "notrunning") + 10 data fields.
    private nonisolated static func unifiedPollScript() -> String {
        return """
        -- ── Spotify (playing) ──
        if application "Spotify" is running then
            tell application "Spotify"
                set spState to player state as string
                if spState is "playing" then
                    set spName to name of current track
                    set spArtist to artist of current track
                    set spArt to artwork url of current track
                    set spDur to duration of current track
                    set spPos to player position
                    set spID to id of current track
                    set spShuffle to shuffling
                    set spRepeat to repeating
                    return "SPOTIFY" & "\\n" & spState & "\\n" & spName & "\\n" & spArtist & "\\n" & spArt & "\\n" & spDur & "\\n" & spPos & "\\n" & spID & "\\n" & spShuffle & "\\n" & spRepeat
                end if
            end tell
        end if

        -- ── Music (playing) ──
        if application "Music" is running then
            tell application "Music"
                set amState to player state as string
                if amState is "playing" then
                    set amName to name of current track
                    set amArtist to artist of current track
                    set amDur to duration of current track
                    set amPos to player position
                    set amID to database ID of current track
                    set amShuffle to shuffle enabled
                    set amRepeat to song repeat as string
                    return "MUSIC" & "\\n" & amState & "\\n" & amName & "\\n" & amArtist & "\\n" & "no-url" & "\\n" & amDur & "\\n" & amPos & "\\n" & amID & "\\n" & amShuffle & "\\n" & amRepeat
                end if
            end tell
        end if

        -- ── Spotify (paused) ──
        if application "Spotify" is running then
            tell application "Spotify"
                set spState to player state as string
                if spState is "paused" then
                    set spName to name of current track
                    set spArtist to artist of current track
                    set spArt to artwork url of current track
                    set spDur to duration of current track
                    set spPos to player position
                    set spID to id of current track
                    set spShuffle to shuffling
                    set spRepeat to repeating
                    return "SPOTIFY" & "\\n" & spState & "\\n" & spName & "\\n" & spArtist & "\\n" & spArt & "\\n" & spDur & "\\n" & spPos & "\\n" & spID & "\\n" & spShuffle & "\\n" & spRepeat
                end if
            end tell
        end if

        -- ── Music (paused) ──
        if application "Music" is running then
            tell application "Music"
                set amState to player state as string
                if amState is "paused" then
                    set amName to name of current track
                    set amArtist to artist of current track
                    set amDur to duration of current track
                    set amPos to player position
                    set amID to database ID of current track
                    set amShuffle to shuffle enabled
                    set amRepeat to song repeat as string
                    return "MUSIC" & "\\n" & amState & "\\n" & amName & "\\n" & amArtist & "\\n" & "no-url" & "\\n" & amDur & "\\n" & amPos & "\\n" & amID & "\\n" & amShuffle & "\\n" & amRepeat
                end if
            end tell
        end if

        -- ── Neither playing nor paused ──
        if application "Spotify" is running then return "SPOTIFY_STOPPED"
        if application "Music" is running then return "MUSIC_STOPPED"
        return "notrunning"
        """
    }

    /// Runs a simple command against the active player.
    private func run(commandScript: String) {
        let app = activePlayer == .spotify ? "Spotify" : "Music"
        run("tell application \"\(app)\" to \(commandScript)")
    }

    // MARK: - State application

    /// Parses the unified poll output. First line is the player tag;
    /// lines 2-11 are: state, title, artist, artURL, duration, position,
    /// trackID, shuffle, repeat.
    private func applyUnified(_ output: String?, measuredAt requestTime: Date) {
        let text = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if text == "notrunning" || text.isEmpty {
            isRunning = false
            isPlaying = false
            title = ""; artist = ""
            position = 0; duration = 0
            artwork = nil
            trackID = ""
            return
        }

        if text == "SPOTIFY_STOPPED" {
            activePlayer = .spotify
            isRunning = true; isPlaying = false
            title = ""; artist = ""
            position = 0; duration = 0
            artwork = nil; trackID = ""
            return
        }
        if text == "MUSIC_STOPPED" {
            activePlayer = .appleMusic
            isRunning = true; isPlaying = false
            title = ""; artist = ""
            position = 0; duration = 0
            artwork = nil; trackID = ""
            return
        }

        // Full data: player tag + 9 fields = 10 lines total
        let f = text.components(separatedBy: "\n")
        guard f.count >= 10 else { return }

        let playerTag = f[0]
        let player: MusicPlayer = playerTag == "MUSIC" ? .appleMusic : .spotify
        activePlayer = player
        isRunning = true

        if Date() >= playStateHoldUntil { isPlaying = (f[1] == "playing") }
        title = f[2]
        artist = f[3]
        let artField = f[4]
        let rawDur = number(f[5])
        duration = player == .spotify ? rawDur / 1000.0 : rawDur
        if !isScrubbing {
            position = number(f[6])
            syncedPosition = position
            syncedAt = requestTime
        }

        // f[0]=tag, f[1]=state, f[2]=title, f[3]=artist, f[4]=artURL,
        // f[5]=dur, f[6]=pos, f[7]=id, f[8]=shuffle, f[9]=repeat
        if f.count >= 10, Date() >= shuffleRepeatHoldUntil {
            isShuffling = (f[8] == "true")
            isRepeating = player == .appleMusic ? (f[9] != "off") : (f[9] == "true")
        }

        let newTrackID = f[7]
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

    /// Spotify: load from URL string returned in the poll.
    private func loadArtwork(from urlString: String) {
        guard let url = URL(string: urlString) else { artwork = nil; return }
        Task.detached { [weak self] in
            guard let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data) else { return }
            await self?.setArtwork(image)
        }
    }

    /// Apple Music: write artwork to temp file via osascript, read in Swift.
    private func loadAppleMusicArtwork() {
        Task.detached { [weak self] in
            guard let image = Self.fetchAppleMusicArtworkSync() else { return }
            await self?.setArtwork(image)
        }
    }

    private func setArtwork(_ image: NSImage) {
        artwork = image
    }

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

    /// Runs an AppleScript via `osascript` and returns stdout.
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
            FileHandle.standardError.write(Data("[SpotiNotch] osascript launch failed: \(error)\n".utf8))
            return nil
        }
    }
}
