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


    /// Settings-backed, mirroring Alcove's own keys.
    @Published var expandOnHover = true
    /// Seconds the pointer must rest on the notch before it opens. 0 opens immediately.
    var hoverDuration: TimeInterval = 0

    /// Audio levels live in their own observable so 30 Hz updates repaint four capsules instead of
    /// the entire island (notch path, clip shape and all). Measured: ~30% CPU versus ~1%.
    let levelStore = LevelStore()

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
            let duration = activity.duration ?? 1.4
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.clearTransient()
            }
        }
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
        let best = live.values.max { $0.priority < $1.priority }
        guard let transient else { current = best; return }
        guard let best, best.priority > transient.priority else { current = transient; return }
        current = best
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
        isExpanded = value
        if value { onExpand?() }
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
