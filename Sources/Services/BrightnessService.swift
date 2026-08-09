import AppKit
import CoreGraphics

/// Watches display and keyboard-backlight brightness.
///
/// There is no public change notification for either. Alcove links
/// `DisplayServicesRegisterForBrightnessChangeNotifications`, but that callback's exact signature
/// is undocumented and has drifted between releases, so getting it wrong crashes rather than
/// degrades. We read through `DisplayServicesGetBrightness` — which is stable and cheap — on a
/// coalescing timer instead.
///
/// ponytail: 250 ms poll of two C calls, ~nothing on the CPU budget, and it rides the shared
/// `Heartbeat` rather than owning a timer. If Apple ever ships a real notification, or the callback
/// signature gets pinned down, swap `tick()` for a subscription and drop the heartbeat use.
@MainActor
final class BrightnessService {
    private(set) var displayBrightness: Float = 0
    private(set) var keyboardBrightness: Float = 0

    var onDisplayChange: ((Float) -> Void)?
    var onKeyboardChange: ((Float) -> Void)?

    private var token: Heartbeat.Token?
    private var primed = false
    private var display: CGDirectDisplayID = CGMainDisplayID()

    /// Brightness keys move in visible steps; ambient sensors drift in much smaller increments.
    private static let hudStepThreshold: Float = 0.02

    static func shouldShowHUD(from previous: Float, to current: Float) -> Bool {
        abs(current - previous) >= hudStepThreshold
    }

    var isAvailable: Bool { Private.displayServicesGetBrightness != nil }

    func start() {
        display = CGMainDisplayID()
        displayBrightness = readDisplay() ?? 0
        keyboardBrightness = Private.keyboardBrightness() ?? 0
        primed = true

        token = Heartbeat.shared.subscribe(.fast) { [weak self] in self?.tick() }
    }

    func stop() {
        if let token { Heartbeat.shared.cancel(token) }
        token = nil
    }

    func setDisplayBrightness(_ value: Float) {
        guard let set = Private.displayServicesSetBrightness else { return }
        _ = set(display, min(max(value, 0), 1))
    }

    private func tick() {
        guard primed else { return }

        if let value = readDisplay() {
            let shouldNotify = Self.shouldShowHUD(from: displayBrightness, to: value)
            displayBrightness = value
            if shouldNotify { onDisplayChange?(value) }
        }
        if let value = Private.keyboardBrightness() {
            let shouldNotify = Self.shouldShowHUD(from: keyboardBrightness, to: value)
            keyboardBrightness = value
            if shouldNotify { onKeyboardChange?(value) }
        }
    }

    private func readDisplay() -> Float? {
        guard let get = Private.displayServicesGetBrightness else { return nil }
        var value: Float = 0
        guard get(display, &value) == 0 else { return nil }
        return min(max(value, 0), 1)
    }
}
