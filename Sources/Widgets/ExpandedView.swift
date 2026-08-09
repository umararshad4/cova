import SwiftUI

/// The full island: Now Playing only.
struct ExpandedView: View {
    @ObservedObject var coordinator: IslandCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Clear the notch itself before any content starts.
            Color.clear.frame(height: coordinator.geometry.collapsedSize.height)

            NowPlayingPanel(coordinator: coordinator)
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
