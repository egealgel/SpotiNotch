import SwiftUI

private let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)

/// A Dynamic-Island-style widget: a black panel hanging from the notch that
/// shows a small album-art + equalizer while collapsed, and expands on hover
/// into full now-playing info with transport controls.
struct NotchView: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    @EnvironmentObject private var spotify: SpotifyController
    @EnvironmentObject private var state: NotchState

    private var hasTrack: Bool { spotify.isRunning && !spotify.title.isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            BottomRoundedRectangle(radius: 22).fill(.black)

            VStack(spacing: 0) {
                topStrip
                if state.isExpanded {
                    expandedBody
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(BottomRoundedRectangle(radius: 22))
        .onHover { hovering in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                state.isExpanded = hovering
            }
        }
    }

    // MARK: - Collapsed top strip (hugs the notch)

    private var topStrip: some View {
        HStack(spacing: 0) {
            artwork(size: notchHeight - 8)
                .frame(width: max(notchHeight, 42), alignment: .center)

            Spacer(minLength: notchWidth)

            Group {
                if hasTrack && spotify.isPlaying {
                    Equalizer()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: max(notchHeight, 42), alignment: .center)
        }
        .frame(height: notchHeight)
        .padding(.horizontal, 8)
    }

    // MARK: - Expanded body (revealed on hover)

    private var expandedBody: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                artwork(size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hasTrack ? spotify.title : "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(hasTrack ? spotify.artist : (spotify.isRunning ? "" : "Spotify isn’t running"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            progressBar
            controls
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    private var progressBar: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let frac = spotify.duration > 0 ? min(spotify.position / spotify.duration, 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(spotifyGreen)
                        .frame(width: max(0, geo.size.width * frac))
                }
            }
            .frame(height: 4)

            HStack {
                Text(timeString(spotify.position))
                Spacer()
                Text(timeString(spotify.duration))
            }
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            iconToggle("shuffle", on: spotify.isShuffling, action: spotify.toggleShuffle)
            icon("backward.fill", size: 15, action: spotify.previous)

            Button(action: spotify.playPause) {
                Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(.plain)

            icon("forward.fill", size: 15, action: spotify.next)
            iconToggle("repeat", on: spotify.isRepeating, action: spotify.toggleRepeat)
        }
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
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let t = Int(seconds)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Rounds only the bottom two corners so the panel looks like it hangs from the
/// top edge of the screen.
struct BottomRoundedRectangle: Shape {
    var radius: CGFloat
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

/// Four green bars that bob while music is playing.
struct Equalizer: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(spotifyGreen)
                        .frame(width: 3, height: barHeight(t, i))
                }
            }
            .frame(height: 16, alignment: .center)
        }
    }

    private func barHeight(_ t: Double, _ i: Int) -> CGFloat {
        let phase = Double(i) * 0.8
        return 4 + (sin(t * 7 + phase) * 0.5 + 0.5) * 12
    }
}
