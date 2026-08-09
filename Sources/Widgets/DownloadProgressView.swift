import SwiftUI

extension DownloadProgress {
    var compactLabel: String {
        if let fraction { return "\(Int(fraction * 100))%" }
        if count > 1 { return "\(count) files" }
        if receivedBytes > 0 { return Self.bytes(receivedBytes) }
        return "Starting"
    }

    var summaryLabel: String {
        if count > 1 { return "\(count) files · \(Self.bytes(receivedBytes))" }
        if let totalBytes {
            return "\(Self.bytes(receivedBytes)) of \(Self.bytes(totalBytes))"
        }
        return receivedBytes > 0 ? "\(Self.bytes(receivedBytes)) downloaded" : "Starting download"
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file)
    }
}

struct DownloadProgressGlyph: View {
    let progress: DownloadProgress
    var diameter: CGFloat = 24
    var tint: Color = .blue

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 2.2)

            if let fraction = progress.fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.22), value: fraction)
            } else {
                Circle()
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [2, 3])
                    )
            }

            Image(systemName: "arrow.down")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Download \(progress.compactLabel)")
    }
}

struct DownloadProgressBar: View {
    let progress: DownloadProgress
    var tint: Color = .blue

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))

                if let fraction = progress.fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, geometry.size.width * fraction))
                        .animation(.easeOut(duration: 0.22), value: fraction)
                } else {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, tint.opacity(0.85), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }
}
