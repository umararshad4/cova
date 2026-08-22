import SwiftUI

struct IslandView: View {
    @ObservedObject var coordinator: IslandCoordinator

    /// Alcove's feel: opening is a quick spring with a soft settle; closing is faster and drier.
    /// One animation per direction — `.animation(_:value:)` takes whatever is current when the
    /// token flips, so switching on `isExpanded` here is enough.
    private var expansionAnimation: Animation {
        coordinator.isExpanded
            ? .spring(response: 0.42, dampingFraction: 0.82)
            : .spring(response: 0.32, dampingFraction: 0.9)
    }

    var body: some View {
        let size = coordinator.currentSize

        GeometryReader { proxy in
            island(size: size)
                // Hover comes from the panel's tracking area, not `.onHover` — SwiftUI reports a
                // spurious exit whenever the hosting view resizes, and the window now resizes on hover.
                .contentShape(Rectangle())
                .onTapGesture { coordinator.toggle() }
                // `position` makes the interpolation explicit: x stays centred while y tracks
                // half the changing height, so the visual top remains at y == 0 throughout.
                .position(x: proxy.size.width / 2, y: size.height / 2)
                .animation(expansionAnimation, value: coordinator.layoutToken)
        }
    }

    private func island(size: CGSize) -> some View {
        // Alcove's expanded card is noticeably rounder than the resting notch: 14 top, 28 bottom.
        NotchShape(
            topRadius: coordinator.isExpanded ? 14 : 8,
            bottomRadius: coordinator.isExpanded ? 28 : 11
        )
        .fill(.black)
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) { content(size: size) }
        .clipShape(NotchShape(
            topRadius: coordinator.isExpanded ? 14 : 8,
            bottomRadius: coordinator.isExpanded ? 28 : 11
        ))
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if coordinator.isExpanded {
            ExpandedView(coordinator: coordinator)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topTrailing) {
                    if coordinator.showsChargingAccessory {
                        ChargingBolt(active: coordinator.effectsActive)
                            .padding(.top, 6)
                            .padding(.trailing, 12)
                    }
                }
                .transition(.opacity)
        } else if let activity = coordinator.current {
            CompactActivityView(activity: activity, coordinator: coordinator)
                .frame(width: size.width, height: coordinator.geometry.collapsedSize.height)
                // Alcove's mini-cards pop: slight scale-up from behind the notch, not a bare fade.
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else if coordinator.ambientChipVisible {
            AmbientIdleView(
                title: coordinator.ambientEventTitle ?? "",
                notchWidth: coordinator.geometry.collapsedSize.width
            )
            .frame(width: size.width, height: coordinator.geometry.collapsedSize.height)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        } else if coordinator.showsChargingAccessory {
            HStack(spacing: 0) {
                Color.clear.frame(width: IslandCoordinator.chargingAccessorySideWidth)
                Color.clear.frame(width: coordinator.geometry.collapsedSize.width)
                ChargingBolt(active: coordinator.effectsActive)
                    .frame(width: IslandCoordinator.chargingAccessorySideWidth)
            }
            .frame(width: size.width, height: coordinator.geometry.collapsedSize.height)
            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
        }
    }
}

/// The bare-notch ambient chip: the next event's title, dimmed, left of the physical notch.
struct AmbientIdleView: View {
    let title: String
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: IslandCoordinator.ambientChipWidth - 8, alignment: .trailing)
            .padding(.leading, 6)

            Spacer(minLength: 0)
                .frame(width: notchWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next event: \(title)")
    }
}

/// The pill state: content sits to the left and right of the physical notch, never behind it.
struct CompactActivityView: View {
    let activity: Activity
    @ObservedObject var coordinator: IslandCoordinator
    @StateObject private var particles = ParticleField()

    var body: some View {
        HStack(spacing: 0) {
            if coordinator.showsChargingAccessory {
                Color.clear.frame(width: IslandCoordinator.chargingAccessorySideWidth)
            }
            leading
                .frame(width: activity.sideWidths.leading)
            Spacer(minLength: 0)
                .frame(width: coordinator.geometry.collapsedSize.width)
            trailing
                .frame(width: activity.sideWidths.trailing)
            if coordinator.showsChargingAccessory {
                ChargingBolt(active: coordinator.effectsActive)
                    .frame(width: IslandCoordinator.chargingAccessorySideWidth)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.white)
        .background {
            // Only the flourish activities pay for a GeometryReader and a Canvas. Attaching this
            // unconditionally cost ~7% on the common now-playing path.
            if let style = particleStyle, coordinator.particlesEnabled {
                GeometryReader { geo in
                    ParticleEmitter(field: particles, tint: particleTint)
                        .onAppear {
                            if coordinator.effectsActive { particles.start(style: style, in: geo.size) }
                        }
                        // Single-parameter form: the two-parameter `onChange` is macOS 14+.
                        .onChange(of: coordinator.effectsActive) { active in
                            if active {
                                particles.start(style: style, in: geo.size)
                            } else {
                                particles.stop()
                            }
                        }
                        .onDisappear { particles.stop() }
                }
            }
        }
    }

    private var particleStyle: ParticleField.Style? {
        switch activity {
        case .power(.pluggedIn), .power(.fullyCharged): return .sparkle
        case .device(let device) where device.connected: return .burst
        default: return nil
        }
    }

    private var particleTint: Color {
        if case .power(.pluggedIn) = activity { return ChargingBolt.purple }
        if case .power = activity { return .green }
        if case .device(let device) = activity, device.connected {
            return coordinator.useAccentColor ? Color.accentColor : DeviceGlyph.defaultTint
        }
        return .white
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .volume(_, let muted):
            symbol(muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        case .brightness:
            symbol("sun.max.fill")
        case .keyboardBacklight:
            symbol("keyboard.fill")
        case .power(.pluggedIn):
            symbol("powerplug.fill", tint: ChargingBolt.purple)
        case .power(let event):
            symbol(powerSymbol(event), tint: powerTint(event))
        case .device(let device):
            DeviceGlyph(
                device: device,
                effectsActive: coordinator.effectsActive,
                useAccentColor: coordinator.useAccentColor
            )
        case .nowPlaying:
            Artwork(image: coordinator.media?.artwork)
        case .focus(_, let symbolName):
            symbol(symbolName, tint: .indigo)
        case .recording(let kind):
            symbol(kind.symbol, tint: kind.tint)
        case .download(let progress):
            DownloadProgressGlyph(progress: progress, diameter: 23)
        case .route(let estimate):
            symbol("car.fill", tint: estimate.isUrgent ? .orange : .white)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .volume(let level, let muted):
            HUDLabel(name: "Sound") { LevelBar(value: muted ? 0 : level) }
        case .brightness(let level):
            HUDLabel(name: "Brightness") { LevelBar(value: level) }
        case .keyboardBacklight(let level):
            HUDLabel(name: "Keyboard") { LevelBar(value: level) }
        case .power(let event):
            Text(powerLabel(event))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        case .device(let device):
            // The ring on the leading side already shows the level, so name the device here.
            // Truncated, not shrunk — a long name reads "Umar's AirPo…" at full size.
            DeviceLabel(text: device.connected ? device.name : "Disconnected")
        case .nowPlaying:
            Waveform(store: coordinator.levelStore, tint: coordinator.media?.accent ?? .white)
        case .focus(let name, _):
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        case .recording:
            EmptyView()
        case .download(let progress):
            Text(progress.compactLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .route(let estimate):
            Text(estimate.leaveInMinutes <= 0
                 ? "Leave now"
                 : "Leave in \(estimate.leaveInMinutes)m")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func symbol(_ name: String, tint: Color = .white) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .symbolReplaceTransition()
    }
}

/// Alcove's HUD pill: the control's name sits between the icon and the level bar.
struct HUDLabel<Bar: View>: View {
    let name: String
    @ViewBuilder let bar: () -> Bar

    var body: some View {
        HStack(spacing: 7) {
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            bar()
                .frame(maxWidth: .infinity)
        }
    }
}

private func powerSymbol(_ event: PowerEvent) -> String {
    switch event {
    case .pluggedIn, .fullyCharged: return "battery.100percent.bolt"
    case .unplugged: return "battery.75percent"
    case .lowBattery: return "battery.25percent"
    }
}

private func powerTint(_ event: PowerEvent) -> Color {
    switch event {
    case .pluggedIn: return ChargingBolt.purple
    case .fullyCharged: return .green
    case .lowBattery: return .red
    case .unplugged: return .white
    }
}

private func powerLabel(_ event: PowerEvent) -> String {
    switch event {
    case .pluggedIn(let p), .unplugged(let p), .lowBattery(let p): return "\(p)%"
    case .fullyCharged: return "Full"
    }
}

struct ChargingBolt: View {
    static let purple = Color(red: 0.68, green: 0.34, blue: 1)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let active: Bool
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.62, weight: .bold))
                .foregroundStyle(Self.purple)
                .pulsingSymbol(active && !reduceMotion)

            Image(systemName: "wave.3.right")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Self.purple)
                .offset(x: size * 0.43)
                .opacity(0.75)
                .pulsingSymbol(active && !reduceMotion)
        }
        .frame(width: size, height: size)
        .shadow(color: Self.purple.opacity(0.65), radius: 5)
        .accessibilityLabel("Charging")
    }
}

struct Artwork: View {
    let image: NSImage?
    var size: CGFloat = 22
    var cornerRadius: CGFloat = 5

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.42))
                            .foregroundStyle(.white.opacity(0.5))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
