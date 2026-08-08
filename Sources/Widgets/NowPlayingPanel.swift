import SwiftUI

struct NowPlayingPanel: View {
    @ObservedObject var coordinator: IslandCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Definite width for the text column. The island is a fixed size, so a `.infinity` chain
    /// wrapped around a `GeometryReader` leaves the layout unresolved and the window never
    /// composites — AppKit reports it visible while the window server holds a 0x0 surface.
    var textWidth: CGFloat = 186

    private var media: MediaState { coordinator.media ?? MediaState() }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Artwork(image: media.artwork, size: 54, cornerRadius: 11)

            VStack(alignment: .leading, spacing: 3) {
                Text(media.hasTrack ? media.displayTitle : "Nothing Playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(media.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                // `liveElapsed` reads the clock, but nothing publishes between helper events, so
                // the body never re-ran and the bar sat frozen until the track changed. Tick just
                // this subtree: 60 Hz drives the wave while playing, Reduce Motion returns to 2 Hz,
                // and the schedule idles while paused.
                TimelineView(.animation(
                    minimumInterval: reduceMotion ? 0.5 : 1.0 / 60.0,
                    paused: !media.isPlaying
                )) { timeline in
                    Scrubber(
                        progress: media.progress,
                        elapsed: media.liveElapsed,
                        duration: media.duration,
                        tint: media.accent,
                        isPlaying: media.isPlaying,
                        wavePhase: reduceMotion ? 0 : CGFloat(
                            timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(
                                    dividingBy: Double(ScrubberBar.wavelength / ScrubberBar.waveSpeed)
                                )
                        ) * ScrubberBar.waveSpeed
                    ) { fraction in
                        coordinator.mediaSeek?(fraction * media.duration)
                    }
                }
                .padding(.top, 3)

                TransportControls(isPlaying: media.isPlaying) { command in
                    coordinator.mediaCommand?(command)
                }
                .padding(.top, 1)
            }
            .frame(width: textWidth, alignment: .leading)
        }
        .foregroundStyle(.white)
    }
}

/// Seek bar with elapsed / remaining, draggable.
struct Scrubber: View {
    let progress: Double
    let elapsed: Double
    let duration: Double
    var tint: Color = .white
    let isPlaying: Bool
    let wavePhase: CGFloat
    var onSeek: (Double) -> Void

    @State private var dragFraction: Double?
    @State private var hovering = false

    private var shown: Double { dragFraction ?? progress }
    private var active: Bool { hovering || dragFraction != nil }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ScrubberBar(
                    width: geo.size.width,
                    fraction: shown,
                    tint: tint,
                    active: active,
                    waving: isPlaying && dragFraction == nil,
                    wavePhase: wavePhase
                )
                    // A 3pt bar is impossible to grab; the gesture gets a taller invisible target.
                    .contentShape(Rectangle().inset(by: -7))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { value in
                                let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                                dragFraction = nil
                                guard duration > 0 else { return }
                                onSeek(fraction)
                            }
                    )
            }
            // GeometryReader takes whatever it is proposed rather than sizing to its content,
            // so the row's height is pinned here and cannot follow the bar.
            .frame(height: ScrubberBar.restHeight)
            .animation(.easeOut(duration: 0.15), value: active)
            .onHover { hovering = $0 }

            HStack {
                Text(Self.time(elapsed))
                Spacer(minLength: 0)
                Text(duration > 0 ? "-" + Self.time(max(duration - elapsed, 0)) : "")
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// The seek bar itself, split out so the no-layout-shift invariant is directly assertable.
///
/// The bar thickens on hover, but the view it hands back to the layout is always `restHeight`
/// tall — the thick state overflows its slot instead of pushing the elapsed/remaining row and the
/// whole transport row down. Letting the outer frame follow the bar cost 2pt of jitter every time
/// the pointer crossed the scrubber. `SelfTest` asserts both states measure the same.
struct ScrubberBar: View {
    let width: CGFloat
    let fraction: Double
    let tint: Color
    let active: Bool
    var waving = false
    var wavePhase: CGFloat = 0

    /// Alcove's resting bar: 3pt, measured off the shipping app at 2x (6 device pixels).
    static let restHeight: CGFloat = 3
    static let activeHeight: CGFloat = 5
    static let waveHeight: CGFloat = 9
    static let waveAmplitude: CGFloat = 2
    static let wavelength: CGFloat = 10
    static let waveSpeed: CGFloat = 7

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.16))
                .frame(height: active ? Self.activeHeight : Self.restHeight)
            SquigglyProgressShape(
                amplitude: waving ? Self.waveAmplitude : 0,
                wavelength: Self.wavelength,
                phase: wavePhase
            )
            .stroke(
                tint,
                style: StrokeStyle(
                    lineWidth: active ? Self.activeHeight : Self.restHeight,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: max(0, width * min(max(fraction, 0), 1)), height: Self.waveHeight)
            .animation(.easeOut(duration: 0.18), value: waving)
        }
        .frame(height: Self.waveHeight)
        .frame(height: Self.restHeight)
    }
}

struct SquigglyProgressShape: Shape {
    var amplitude: CGFloat
    let wavelength: CGFloat
    let phase: CGFloat

    var animatableData: CGFloat {
        get { amplitude }
        set { amplitude = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0 else { return path }

        let wavelength = max(wavelength, 1)
        let step = max(0.5, wavelength / 20)
        func point(at x: CGFloat) -> CGPoint {
            let angle = ((x - rect.minX + phase) / wavelength) * 2 * .pi
            let variation = 0.72 + 0.28 * sin(angle * 0.37 + 1.1)
            return CGPoint(x: x, y: rect.midY + amplitude * variation * sin(angle))
        }

        path.move(to: point(at: rect.minX))
        var x = rect.minX + step
        while x < rect.maxX {
            path.addLine(to: point(at: x))
            x += step
        }
        path.addLine(to: point(at: rect.maxX))
        return path
    }
}

/// Previous / play-pause / next, spread across the scrubber's width with hover feedback.
///
/// Alcove spaces these against the ends of the seek bar rather than centring a fixed-width
/// cluster: measured off the shipping app, the outer glyphs sit at 15% and 84% of the bar and
/// the play glyph at its midpoint. A fixed `HStack` spacing only reproduces that at one column
/// width — at ours it bunched all three into the middle third.
struct TransportControls: View {
    let isPlaying: Bool
    var send: (MediaCommand) -> Void

    var body: some View {
        HStack(spacing: 0) {
            TransportButton(symbol: "backward.fill", size: 13) { send(.previous) }
            Spacer(minLength: 8)
            TransportButton(symbol: isPlaying ? "pause.fill" : "play.fill", size: 17) {
                send(.togglePlayPause)
            }
            Spacer(minLength: 8)
            TransportButton(symbol: "forward.fill", size: 13) { send(.next) }
        }
        .padding(.horizontal, 9)
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.82))
            .contentTransition(.symbolEffect(.replace))
            // Generous hit area without a visible frame — the icons stay small, the target doesn't.
            .frame(width: size + 14, height: size + 10)
            .contentShape(Rectangle())
            .scaleEffect(pressed ? 0.86 : (hovering ? 1.08 : 1))
            .animation(.interpolatingSpring(stiffness: 520, damping: 22), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in
                        pressed = false
                        action()
                    }
            )
    }
}
