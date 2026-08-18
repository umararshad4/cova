import SwiftUI

/// Deliberately separate from `IslandCoordinator` — see `levelStore`.
@MainActor
final class LevelStore: ObservableObject {
    @Published var levels: [Float] = []
}

/// Owns what the island is showing and how big it is.
///
/// Two tiers: `live` activities persist until withdrawn (music, Focus, recording), `transient` ones
/// expire on a timer (volume, brightness, plug-in). The highest-priority of the two wins, so a
/// volume nudge preempts the music view and the music view comes back when the nudge expires —
/// without either service knowing about the other.
@MainActor
final class IslandCoordinator: ObservableObject {
    @Published private(set) var current: Activity?
    @Published private(set) var isExpanded = false
    @Published var geometry: NotchGeometry
    @Published var media: MediaState?
    @Published var battery: BatteryService.State?
    @Published var events: [CalendarEvent] = []
    @Published var device: DeviceEvent?
    @Published var download: DownloadProgress?
    @Published var effectsActive = true


    @Published var expandOnHover = true
    /// Seconds the pointer must rest on the notch before it opens. 0 opens immediately.
    var hoverDuration: TimeInterval = 0

    /// How long each class of transient activity lingers. These live here rather than on `Activity`
    /// so the activity stays a pure value type with no opinion about user preferences.
    var hudDuration: TimeInterval = 1.4
    var powerDuration: TimeInterval = 3.0
    var deviceDuration: TimeInterval = 4.0

    /// Charging sparkle and device-connect burst. Off is a real preference, not just Reduce Motion.
    @Published var particlesEnabled = true
    /// Tint device and gesture feedback with the system accent colour.
    @Published var useAccentColor = true

    /// `Activity.duration` still decides live-vs-transient; only the timing is a preference.
    private func dwell(for activity: Activity) -> TimeInterval {
        switch activity {
        case .volume, .brightness, .keyboardBacklight: return hudDuration
        case .power: return powerDuration
        case .device: return deviceDuration
        default: return hudDuration
        }
    }

    /// Audio levels live in their own observable so 30 Hz updates repaint four capsules instead of
    /// the entire island (notch path, clip shape and all). Measured: ~30% CPU versus ~1%.
    let levelStore = LevelStore()

    /// True only while the compact Now Playing view — the one thing that draws a waveform — is the
    /// visible activity. The expanded panel draws album art instead, and any higher-priority
    /// activity (a volume HUD, a download, a device connect) covers it entirely.
    var waveformIsVisible: Bool {
        !isExpanded && current == .nowPlaying
    }

    /// Fired whenever `waveformIsVisible` may have changed, so the tap can be started and stopped
    /// with what is on screen rather than with playback.
    var onPresentationChange: (() -> Void)?

    /// Wired by `AppDelegate` to whichever media backend is live.
    var mediaCommand: ((MediaCommand) -> Void)?
    var mediaSeek: ((Double) -> Void)?

    static let expandedSize = CGSize(width: 380, height: 150)
    static let panelPadding: CGFloat = 40
    static let chargingAccessorySideWidth: CGFloat = 28

    private var live: [String: Activity] = [:]
    private var transient: Activity?
    private var expiry: Task<Void, Never>?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: - Activity input

    func push(_ activity: Activity) {
        Debug.log("push \(activity)")
        if activity.isLive {
            live[activity.slot] = activity
        } else {
            transient = activity
            expiry?.cancel()
            let duration = dwell(for: activity)
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.clearTransient()
            }
        }
        recompute()
    }

    /// Copies the resident state of another island, so plugging in a monitor mid-song shows the
    /// song rather than an empty notch until the next update happens to arrive.
    func adopt(from other: IslandCoordinator) {
        media = other.media
        battery = other.battery
        events = other.events
        device = other.device
        download = other.download
        effectsActive = other.effectsActive
        live = other.live
        recompute()
    }

    func withdraw(slot: String) {
        live[slot] = nil
        if transient?.slot == slot { clearTransient() }
        recompute()
    }

    private func clearTransient() {
        expiry?.cancel()
        expiry = nil
        transient = nil
        recompute()
    }

    private func recompute() {
        let before = waveformIsVisible
        let best = live.values.max { $0.priority < $1.priority }
        if let transient {
            if let best, best.priority > transient.priority {
                current = best
            } else {
                current = transient
            }
        } else {
            current = best
        }
        if waveformIsVisible != before { onPresentationChange?() }
    }

    // MARK: - Expansion

    private var hoverTask: Task<Void, Never>?

    /// Called synchronously after expanded geometry becomes current, but before SwiftUI draws it.
    /// Growing while the resting geometry is still current briefly lays the smaller island out in
    /// the larger window, which makes hover expansion appear to shrink and reposition first.
    var onExpand: (() -> Void)?

    /// Every path into `isExpanded` goes through here, so panel growth stays in the same update.
    private func setExpanded(_ value: Bool) {
        guard value != isExpanded else { return }
        let before = waveformIsVisible
        isExpanded = value
        if value { onExpand?() }
        if waveformIsVisible != before { onPresentationChange?() }
    }

    func hover(_ inside: Bool) {
        guard expandOnHover else { return }
        hoverTask?.cancel()

        // Leaving always collapses immediately; only opening is delayed.
        guard inside else {
            hoverTask = nil
            setExpanded(false)
            return
        }
        guard hoverDuration > 0 else {
            setExpanded(true)
            return
        }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.hoverDuration ?? 0))
            guard !Task.isCancelled else { return }
            self?.setExpanded(true)
        }
    }

    func toggle() { setExpanded(!isExpanded) }

    func collapse() { setExpanded(false) }

    // MARK: - Layout

    /// Charging is an ambient accessory, including during the first plug-in frame.
    var showsChargingAccessory: Bool {
        battery?.isCharging == true
    }

    var currentSize: CGSize {
        if isExpanded { return Self.expandedSize }
        // The physical notch stays centred, so a right-side accessory needs matching clear space
        // on the left; otherwise half the icon lands behind the camera housing.
        let chargingWidth = showsChargingAccessory ? Self.chargingAccessorySideWidth * 2 : 0
        guard let current else {
            return CGSize(
                width: geometry.collapsedSize.width + chargingWidth,
                height: chargingWidth > 0 ? geometry.collapsedSize.height + 2 : geometry.collapsedSize.height
            )
        }
        let sides = current.sideWidths
        return CGSize(
            width: geometry.collapsedSize.width + sides.leading + sides.trailing + chargingWidth,
            height: geometry.collapsedSize.height + 2
        )
    }

    /// Panel is fixed at the largest the island can reach; the island animates inside it.
    var panelSize: CGSize {
        CGSize(
            width: Self.expandedSize.width + Self.panelPadding * 2,
            height: Self.expandedSize.height + Self.panelPadding
        )
    }

    /// Drives SwiftUI animation — changes whenever the island should move.
    /// A struct rather than an interpolated string: this is read on every body pass, and the string
    /// version allocated one every time to be compared and thrown away.
    struct LayoutToken: Equatable {
        var isExpanded: Bool
        var slot: String?
        var width: Int
        var height: Int
    }

    var layoutToken: LayoutToken {
        let size = currentSize
        return LayoutToken(
            isExpanded: isExpanded,
            slot: current?.slot,
            width: Int(size.width),
            height: Int(size.height)
        )
    }
}
