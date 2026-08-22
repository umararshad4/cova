import SwiftUI

/// Bar visualiser fed by real output levels from `AudioTapService`.
/// Falls back to a resting state when there is no signal, rather than faking motion.
///
/// Drawn with `Canvas`, not `ForEach` over shapes: at 20 Hz the ForEach version rebuilt a
/// `DynamicViewList` on every update and dominated the profile. Canvas is one draw pass with no
/// view-graph churn.
struct Waveform: View {
    @ObservedObject var store: LevelStore
    var tint: Color = .white
    var barCount: Int = 4
    var maxHeight: CGFloat = 14

    private let barWidth: CGFloat = 2.5
    private let spacing: CGFloat = 2.5

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
            var x = (size.width - totalWidth) / 2

            for index in 0..<barCount {
                let level = index < store.levels.count ? CGFloat(store.levels[index]) : 0
                let height = max(3, level * maxHeight)
                let rect = CGRect(
                    x: x,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint))
                x += barWidth + spacing
            }
        }
        .frame(height: maxHeight)
    }
}

/// Alcove's HUD readout: one continuous capsule filling over a dim track, not macOS's segments.
struct LevelBar: View {
    let value: Float
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, geo.size.width * Double(min(max(value, 0), 1))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.12), value: value)
    }
}
