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
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    @EnvironmentObject private var spotify: SpotifyController
    @EnvironmentObject private var state: NotchState

    private var hasTrack: Bool { spotify.isRunning && !spotify.title.isEmpty }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(
                topCornerRadius: state.isExpanded ? 14 : 6,
                bottomCornerRadius: state.isExpanded ? 24 : 12
            )
                .fill(.black)
                .frame(
                    width: state.isExpanded ? cardWidth : notchWidth,
                    height: state.isExpanded ? cardHeight : notchHeight
                )
                .animation(.spring(response: 0.45, dampingFraction: 0.82), value: state.isExpanded)

            content
                .opacity(state.isExpanded ? 1 : 0)
                .scaleEffect(state.isExpanded ? 1 : 0.92, anchor: .top)
                .animation(.easeOut(duration: state.isExpanded ? 0.32 : 0.16), value: state.isExpanded)
        }
        .frame(width: cardWidth, height: cardHeight, alignment: .top)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Leave the physical notch clear at the top.
            Color.clear.frame(height: notchHeight)

            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    artwork(size: 48)
                        .id(spotify.title)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasTrack ? spotify.title : "Nothing playing")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(hasTrack ? spotify.artist : (spotify.isRunning ? "" : "Spotify isn’t running"))
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    .id(spotify.title)
                    .transition(.opacity)
                    Spacer(minLength: 0)
                }
                .animation(.easeOut(duration: 0.28), value: spotify.title)

                progressBar
                controls
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private var progressBar: some View {
        HStack(spacing: 8) {
            Text(timeString(spotify.position))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))

            GeometryReader { geo in
                let frac = spotify.duration > 0 ? min(spotify.position / spotify.duration, 1) : 0
                let fillWidth = max(0, geo.size.width * frac)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                        .frame(height: 6)
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: fillWidth, height: 6)
                        .animation(spotify.isScrubbing ? nil : .linear(duration: 0.25), value: frac)
                    // A thumb only appears while actively dragging, popping in
                    // for a tactile "grabbed" feel, and follows the finger 1:1.
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .offset(x: fillWidth - 7)
                        .opacity(spotify.isScrubbing ? 1 : 0)
                        .scaleEffect(spotify.isScrubbing ? 1 : 0.4)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: spotify.isScrubbing)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    // Larger invisible hit area than the thin 4pt bar, so the
                    // track is comfortable to grab and drag.
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard spotify.duration > 0 else { return }
                            spotify.isScrubbing = true
                            let frac = min(max(0, value.location.x / geo.size.width), 1)
                            spotify.seekLive(frac * spotify.duration)
                        }
                        .onEnded { value in
                            guard spotify.duration > 0 else { return }
                            let frac = min(max(0, value.location.x / geo.size.width), 1)
                            spotify.seek(to: frac * spotify.duration)
                            spotify.isScrubbing = false
                        }
                )
            }
            .frame(height: 20)

            Text(timeString(spotify.duration))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            iconToggle("shuffle", on: spotify.isShuffling, size: 15, action: spotify.toggleShuffle)
            Spacer(minLength: 0)
            icon("backward.fill", size: 22, action: spotify.previous)
            Spacer(minLength: 0)
            playPauseButton
            Spacer(minLength: 0)
            icon("forward.fill", size: 22, action: spotify.next)
            Spacer(minLength: 0)
            iconToggle("repeat", on: spotify.isRepeating, size: 15, action: spotify.toggleRepeat)
        }
        .padding(.top, 2)
    }

    /// A dedicated view (rather than reusing `icon`) so the play/pause glyph
    /// can crossfade with a little pop instead of flipping instantly.
    private var playPauseButton: some View {
        Button(action: spotify.playPause) {
            Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .id(spotify.isPlaying)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .buttonStyle(PressableIconStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: spotify.isPlaying)
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
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }

    private func icon(_ system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(PressableIconStyle())
    }

    private func iconToggle(_ system: String, on: Bool, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(on ? spotifyGreen : .white.opacity(0.4))
                .animation(.easeOut(duration: 0.18), value: on)
        }
        .buttonStyle(PressableIconStyle())
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let t = Int(seconds)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

/// Scales a control down slightly while pressed for tactile feedback.
private struct PressableIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// The classic "notch ear" shape (ported from the open-source boring.notch
/// project's `NotchShape`): concave curves at the top corners so the panel
/// flows smoothly out of the physical notch instead of looking like a
/// separate rectangle, plus ordinary convex rounded corners at the bottom.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set { topCornerRadius = newValue.first; bottomCornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))

        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))

        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))

        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))

        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))

        return path
    }
}
