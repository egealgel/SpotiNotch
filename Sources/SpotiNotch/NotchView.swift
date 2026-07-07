import SwiftUI

private let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)

/// A Dynamic-Island-style widget. The hosting NSWindow is fixed at the card's
/// full (expanded) size and never resized — `AppDelegate` drives
/// `state.isExpanded` by polling the real cursor position, not AppKit hover
/// events, so this view only needs to render each state; it doesn't need to
/// detect hover itself.
struct NotchView: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @EnvironmentObject private var spotify: SpotifyController
    @EnvironmentObject private var state: NotchState

    private let cardWidth: CGFloat = 380
    private let cardHeight: CGFloat = 172

    private var hasTrack: Bool { spotify.isRunning && !spotify.title.isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            BottomRoundedRectangle(radius: state.isExpanded ? 24 : 10)
                .fill(.black)
                .frame(
                    width: state.isExpanded ? cardWidth : notchWidth,
                    height: state.isExpanded ? cardHeight : notchHeight
                )

            content
                .opacity(state.isExpanded ? 1 : 0)
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Leave the physical notch clear at the top.
            Color.clear.frame(height: notchHeight)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    artwork(size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hasTrack ? spotify.title : "Nothing playing")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(hasTrack ? spotify.artist : (spotify.isRunning ? "" : "Spotify isn’t running"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                VStack(spacing: 10) {
                    progressBar
                    controls
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let frac = spotify.duration > 0 ? min(spotify.position / spotify.duration, 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(Color.white.opacity(0.95))
                        .frame(width: max(0, geo.size.width * frac))
                }
            }
            .frame(height: 3)

            HStack {
                Text(timeString(spotify.position))
                Spacer()
                Text(timeString(spotify.duration))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var controls: some View {
        HStack {
            iconToggle("shuffle", on: spotify.isShuffling, action: spotify.toggleShuffle)
            Spacer(minLength: 0)
            icon("backward.fill", size: 16, action: spotify.previous)
            Spacer(minLength: 0)
            icon(spotify.isPlaying ? "pause.fill" : "play.fill", size: 20, action: spotify.playPause)
            Spacer(minLength: 0)
            icon("forward.fill", size: 16, action: spotify.next)
            Spacer(minLength: 0)
            iconToggle("repeat", on: spotify.isRepeating, action: spotify.toggleRepeat)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Pieces

    private func artwork(size: CGFloat) -> some View {
        Group {
            if let img = spotify.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private func icon(_ system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func iconToggle(_ system: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? spotifyGreen : .white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let t = Int(seconds)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// Rounds only the bottom two corners so the panel looks like it hangs from the
/// top edge of the screen.
struct BottomRoundedRectangle: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(radius, min(rect.width, rect.height) / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}
