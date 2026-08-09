import SwiftUI

/// Battery level as a ring arc, the way the real Dynamic Island renders AirPods.
/// Canvas rather than stacked `Circle().trim(...)` shapes — same reason as `Waveform`.
///
/// `Animatable` is what buys the sweep: Canvas contents aren't animatable on their own, but a View
/// that vends `animatableData` gets its body re-evaluated on every frame of the interpolation.
struct BatteryRing: View, Animatable {
    let percent: Int
    /// 0…1 of the arc that is drawn. Animate it to make the ring draw itself in.
    var fill: Double = 1
    var diameter: CGFloat = 26
    var lineWidth: CGFloat = 2.5

    var animatableData: Double {
        get { fill }
        set { fill = newValue }
    }

    static func tint(for percent: Int) -> Color {
        switch percent {
        case ..<20: return .red
        case ..<50: return .yellow
        default: return .green
        }
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let inset = lineWidth / 2
            let rect = CGRect(x: inset, y: inset,
                              width: size.width - lineWidth,
                              height: size.height - lineWidth)
            let swept = min(max(fill, 0), 1)
            let fraction = min(max(Double(percent) / 100, 0), 1) * swept

            context.stroke(
                Path(ellipseIn: rect),
                with: .color(.white.opacity(0.18 * swept)),
                lineWidth: lineWidth
            )

            // Start at 12 o'clock and fill clockwise.
            var arc = Path()
            arc.addArc(
                center: CGPoint(x: size.width / 2, y: size.height / 2),
                radius: rect.width / 2,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * fraction),
                clockwise: false
            )
            context.stroke(
                arc,
                with: .color(Self.tint(for: percent)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Compact connection flourish: a coloured device icon with wireless waves, never a battery ring.
struct DeviceGlyph: View {
    static let connectedTint = Color(red: 0.25, green: 0.72, blue: 1)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let device: DeviceEvent
    let effectsActive: Bool
    @State private var shown = false

    var body: some View {
        ZStack {
            if device.connected {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Self.connectedTint)
                    .opacity(0.75)
                    .symbolEffect(
                        .pulse,
                        options: .repeating,
                        isActive: effectsActive && !reduceMotion
                    )
            }

            Image(systemName: device.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(device.connected ? Self.connectedTint : .red)
                .shadow(
                    color: (device.connected ? Self.connectedTint : .red).opacity(0.65),
                    radius: 4
                )
        }
        .frame(width: 28, height: 28)
        .scaleEffect(shown ? 1 : 0.6)
        .opacity(shown ? 1 : 0)
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { shown = true }
            }
        }
    }
}

/// The device name, revealed just behind the glyph. Long names truncate — "Umar's AirPo…".
struct DeviceLabel: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .blur(radius: shown ? 0 : 3)
            .opacity(shown ? 1 : 0)
            .offset(x: shown ? 0 : -8)
            .onAppear {
                withAnimation(.interpolatingSpring(stiffness: 220, damping: 20).delay(0.09)) {
                    shown = true
                }
            }
    }
}

/// Expanded card: per-bud and case levels, as iOS shows when you tap the island.
struct DeviceCard: View {
    let device: DeviceEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: device.symbol)
                    .font(.system(size: 20, weight: .medium))
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }

            if device.hasDetailedBattery {
                HStack(spacing: 16) {
                    if let left = device.batteryLeft { level("L", left) }
                    if let right = device.batteryRight { level("R", right) }
                    if let caseLevel = device.batteryCase { level("Case", caseLevel) }
                }
            } else if let percent = device.ringPercent {
                level("Battery", percent)
            } else {
                Text(device.connected ? "Connected" : "Disconnected")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func level(_ label: String, _ percent: Int) -> some View {
        VStack(spacing: 4) {
            BatteryRing(percent: percent, diameter: 30)
                .overlay(
                    Text("\(percent)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                )
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}
