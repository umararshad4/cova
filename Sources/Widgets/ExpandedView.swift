import AppKit
import SwiftUI

/// The full island.
///
/// It used to render Now Playing and nothing else: with no music, an expanded island showed an
/// empty box with dead transport buttons, while the calendar events and download progress it had
/// already fetched went unused. Now it picks the most useful thing it has.
struct ExpandedView: View {
    @ObservedObject var coordinator: IslandCoordinator

    private enum Content {
        case nowPlaying
        case agenda
        case downloads
        case empty
    }

    private var content: Content {
        if let media = coordinator.media, media.hasTrack { return .nowPlaying }
        if let download = coordinator.download, download.count > 0 { return .downloads }
        if !coordinator.events.isEmpty { return .agenda }
        return .empty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Clear the notch itself before any content starts.
            Color.clear.frame(height: coordinator.geometry.collapsedSize.height)

            Group {
                switch content {
                case .nowPlaying:
                    NowPlayingPanel(coordinator: coordinator)
                case .agenda:
                    AgendaPanel(events: coordinator.events)
                case .downloads:
                    DownloadsPanel(progress: coordinator.download)
                case .empty:
                    EmptyPanel()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .background {
            ZStack {
                if let media = coordinator.media, media.hasTrack {
                    RadialGradient(
                        colors: [media.accent.opacity(0.36), .clear],
                        center: UnitPoint(x: 0.12, y: 0.48),
                        startRadius: 0,
                        endRadius: 230
                    )
                    .animation(.easeInOut(duration: 0.4), value: media.artworkData)
                }

                LinearGradient(
                    colors: [.white.opacity(0.055), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.58)
                )
            }
        }
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.clear, .white.opacity(0.18), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.5)
            .padding(.horizontal, 38)
            .offset(y: coordinator.geometry.collapsedSize.height)
        }
    }
}

/// What's next, from the events the calendar service already fetches.
struct AgendaPanel: View {
    let events: [CalendarEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Up Next")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
                .kerning(0.6)

            ForEach(events.prefix(3)) { event in
                AgendaRow(event: event)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgendaRow: View {
    let event: CalendarEvent

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(countdown)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer(minLength: 4)

            if let meeting = event.meetingURL {
                Button {
                    NSWorkspace.shared.open(meeting)
                } label: {
                    Text("Join")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help(meeting.absoluteString)
            }
        }
        .foregroundStyle(.white)
    }

    private var tint: Color {
        event.tint.map { Color(cgColor: $0) } ?? .accentColor
    }

    /// "in 12 min" reads better than a clock time for the thing about to happen.
    private var countdown: String {
        if event.isAllDay { return "All day" }
        let minutes = event.minutesAway
        if minutes < 0 { return "Now · \(event.subtitle)" }
        if minutes < 60 { return "in \(minutes) min · \(event.subtitle)" }
        let hours = Double(minutes) / 60
        return "in \(hours < 2 ? String(format: "%.1f", hours) : String(Int(hours.rounded()))) h · \(event.subtitle)"
    }
}

/// Shown while downloads are in flight and nothing is playing.
struct DownloadsPanel: View {
    let progress: DownloadProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress?.count == 1 ? "Downloading" : "Downloading \(progress?.count ?? 0) files")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
                .kerning(0.6)

            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
                    .tint(.white)
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.white)
                Text(byteCount)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var byteCount: String {
        ByteCountFormatter.string(
            fromByteCount: progress?.receivedBytes ?? 0, countStyle: .file
        ) + " so far"
    }
}

/// Nothing to show. Says so, and says what the island can do — the gestures are otherwise
/// undiscoverable.
struct EmptyPanel: View {
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text("Nothing playing")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Text("Two fingers on the notch: swipe down to open, up to close,\nleft and right to change track.")
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}
