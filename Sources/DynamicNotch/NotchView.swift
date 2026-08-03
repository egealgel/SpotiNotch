import SwiftUI
import AppKit

// (spotifyGreen removed — shuffle/repeat now use Dynamic Island-style bold
// white instead of green, matching the clean monochrome aesthetic.)

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
    @EnvironmentObject private var controller: MusicController
    @EnvironmentObject private var state: NotchState
    @EnvironmentObject private var audio: AudioVisualizer

    private var hasTrack: Bool { controller.isRunning && !controller.title.isEmpty }

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
        // Right-click anywhere on the expanded card to quit — the only way to
        // stop the app used to be deleting it (it's a KeepAlive-style login
        // item), which isn't a real quit path.
        .contextMenu {
            Button("Quit DynamicNotch") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Leave the physical notch clear at the top.
            Color.clear.frame(height: notchHeight)

            VStack(spacing: 9) {
                HStack(spacing: 12) {
                    artwork(size: 40)
                        .id(controller.title)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hasTrack ? controller.title : "Nothing playing")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(hasTrack ? controller.artist : (controller.isRunning ? "" : "No music app running"))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    .id(controller.title)
                    .transition(.opacity)
                    visualizer
                        .id(controller.title)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                }
                .animation(.easeOut(duration: 0.28), value: controller.title)
                .padding(.leading, 6)

                progressBar
                controls
                    .padding(.horizontal, 10)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }

    private var progressBar: some View {
        // TimelineView interpolates the live position from wall-clock time each
        // frame (the same technique boring.notch uses for its slider: elapsed
        // time + delta since the last snapshot, rather than a Timer mutating
        // published state). State only needs to change when a real playback
        // event arrives via DistributedNotificationCenter (see MusicController.
        // observePlaybackNotifications), so nothing here depends on polling.
        // Gated on `state.isExpanded` too — this view stays in the hierarchy
        // (just faded to opacity 0) while collapsed, so without this check it
        // would keep redrawing 5x/second in the background any time music is
        // playing, even though nobody can see it. `paused:` (not a nil
        // minimumInterval, which would mean "no cap" i.e. every frame) is what
        // actually stops the ticking.
        // 0.2s (5fps) is plenty smooth for a progress bar and keeps the redraw
        // load to a minimum; the remaining-time label below is derived from the
        // same single livePosition so it always matches the fill exactly.
        let shouldTick = state.isExpanded && controller.isPlaying && !controller.isScrubbing
        return TimelineView(.animation(minimumInterval: 0.2, paused: !shouldTick)) { timeline in
            let livePosition = controller.livePosition(at: timeline.date)

            HStack(spacing: 8) {
                Text(timeString(livePosition))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))

                GeometryReader { geo in
                    let frac = controller.duration > 0 ? min(livePosition / controller.duration, 1) : 0
                    let fillWidth = max(0, geo.size.width * frac)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.22))
                            .frame(height: 6)
                        Capsule().fill(Color.white.opacity(0.85))
                            .frame(width: fillWidth, height: 6)
                        // A thumb only appears while actively dragging, popping in
                        // for a tactile "grabbed" feel, and follows the finger 1:1.
                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                            .offset(x: fillWidth - 7)
                            .opacity(controller.isScrubbing ? 1 : 0)
                            .scaleEffect(controller.isScrubbing ? 1 : 0.4)
                            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: controller.isScrubbing)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        // Larger invisible hit area than the thin 4pt bar, so the
                        // track is comfortable to grab and drag.
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard controller.duration > 0 else { return }
                                controller.isScrubbing = true
                                let frac = min(max(0, value.location.x / geo.size.width), 1)
                                controller.seekLive(frac * controller.duration)
                            }
                            .onEnded { value in
                                guard controller.duration > 0 else { return }
                                let frac = min(max(0, value.location.x / geo.size.width), 1)
                                controller.seek(to: frac * controller.duration)
                                controller.isScrubbing = false
                            }
                    )
                }
                .frame(height: 20)

                // Remaining time, counting down like the iPhone Dynamic Island
                // (e.g. "-2:31" → "-2:30" → ...). Clamped so it can't go negative.
                Text("-" + timeString(max(0, controller.duration - livePosition)))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            iconToggle("shuffle", on: controller.isShuffling, size: 13, action: controller.toggleShuffle)
            Spacer(minLength: 0)
            icon("backward.fill", size: 19, action: controller.previous)
            Spacer(minLength: 0)
            playPauseButton
            Spacer(minLength: 0)
            icon("forward.fill", size: 19, action: controller.next)
            Spacer(minLength: 0)
            iconToggle("repeat", on: controller.isRepeating, size: 13, action: controller.toggleRepeat)
        }
    }

    /// A dedicated view (rather than reusing `icon`) so the play/pause glyph
    /// can crossfade with a little pop instead of flipping instantly.
    private var playPauseButton: some View {
        HoverIconButton(system: controller.isPlaying ? "pause.fill" : "play.fill", size: 20, action: controller.playPause) {
            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .id(controller.isPlaying)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: controller.isPlaying)
    }

    // MARK: - Pieces

    private func artwork(size: CGFloat) -> some View {
        Group {
            if let img = controller.artwork {
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
        HoverIconButton(system: system, size: size, action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    /// Shuffle / repeat toggle rendered Dynamic-Island-style: bold white when
    /// active, subtle dimmed when off. Active state gets a soft rounded glow
    /// (halo) behind the icon — like the iPhone Dynamic Island's active control.
    private func iconToggle(_ system: String, on: Bool, size: CGFloat, action: @escaping () -> Void) -> some View {
        HoverIconButton(system: system, size: size, action: action) {
            ZStack {
                // Soft rounded halo that fades in when the toggle is active.
                Capsule()
                    .fill(.white.opacity(0.14))
                    .shadow(color: .white.opacity(0.55), radius: 5, y: 0)
                    .opacity(on ? 1 : 0)
                    .scaleEffect(on ? 1 : 0.7)
                    .animation(.spring(response: 0.28, dampingFraction: 0.7), value: on)
                Image(systemName: system)
                    .font(.system(size: size, weight: on ? .heavy : .regular))
                    .foregroundStyle(on ? .white : .white.opacity(0.3))
                    .animation(.easeOut(duration: 0.18), value: on)
            }
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let t = Int(seconds)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: - Equalizer (Dynamic Island style)
    //
    // Three modes, in order of preference:
    //   1. Real-time  — driven by the actual audio of the playing app via the
    //      CoreAudio process tap (AudioVisualizer). Reacts to the track's real
    //      rhythm, exactly like the Dynamic Island.
    //   2. Animated   — lightweight deterministic fallback (boring.notch's
    //      shipped look) when the tap API is unavailable (< macOS 14.2), no
    //      supported player is running, or the tap couldn't start. Each bar
    //      oscillates on its own sine phase so it still looks alive.
    //   3. Resting    — paused / no track: bars sit at minimum height.

    private var visualizer: some View {
        Group {
            if audio.isActive {
                realTimeEqualizer
            } else {
                // Always animate the fallback when expanded — boring.notch
                // ships this by default; it looks alive even when no real
                // audio tap is available.
                animatedEqualizer
            }
        }
    }

    private var realTimeEqualizer: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<audio.levels.count, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(controller.isPlaying ? 0.9 : 0.3))
                    .frame(width: 2.5, height: 12)
                    .scaleEffect(x: 1, y: max(0.3, audio.levels[i]), anchor: .center)
            }
        }
        .frame(width: 20, height: 12)
        .opacity(controller.isPlaying ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.3), value: controller.isPlaying)
    }

    private var animatedEqualizer: some View {
        // Tick continuously while the card is expanded (the content is hidden
        // behind opacity 0 when collapsed, so we gate on expanded here to save
        // cycles — just like the progress bar).
        let ticking = state.isExpanded && !audio.isActive
        return TimelineView(.animation(minimumInterval: 0.12, paused: !ticking)) { timeline in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<AudioTapEngine.bandCount, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(controller.isPlaying && hasTrack ? 0.9 : 0.4))
                        .frame(width: 2.5, height: 12)
                        .scaleEffect(x: 1, y: animatedLevel(i, at: timeline.date), anchor: .center)
                }
            }
            .frame(width: 20, height: 12)
        }
    }

    /// Deterministic per-bar sine walk for the non-reactive fallback equalizer.
    private func animatedLevel(_ index: Int, at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let phases: [Double] = [0.0, 2.1, 4.2, 1.1, 3.3, 5.4]
        let speeds: [Double] = [1.7, 2.3, 1.2, 2.8, 1.9, 2.5]
        let v = 0.5 + 0.5 * sin(t * speeds[index % speeds.count] + phases[index % phases.count])
        return CGFloat(0.35 + 0.65 * v)
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

/// An icon button with a soft capsule that fades in on hover, adapted from
/// boring.notch's `HoverButton` — gives the controls the same tactile,
/// "alive" feel as that app, on top of the existing press-scale feedback.
private struct HoverIconButton<Content: View>: View {
    let system: String
    var size: CGFloat = 16
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule()
                    .fill(isHovering ? Color.white.opacity(0.14) : .clear)
                content()
            }
            .frame(width: size * 1.9, height: size * 1.9)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableIconStyle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) { isHovering = hovering }
        }
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
