import SwiftUI

/// The full island: Now Playing only.
struct ExpandedView: View {
    @ObservedObject var coordinator: IslandCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Clear the notch itself before any content starts.
            Color.clear.frame(height: coordinator.geometry.collapsedSize.height)

            NowPlayingPanel(coordinator: coordinator, textWidth: 258)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            Spacer(minLength: 0)

        }
        .background(alignment: .top) {
            // Album-art wash, the way Alcove tints the island to the current track.
            if let media = coordinator.media, media.hasTrack {
                LinearGradient(
                    colors: [media.accent.opacity(0.30), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 110)
                .blur(radius: 26)
                .animation(.easeInOut(duration: 0.45), value: media.artworkData)
            }
        }
    }

}

