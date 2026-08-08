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

    /// Ignore drift below this so ambient auto-brightness doesn't spam the island.
    private let threshold: Float = 0.005

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

        if let value = readDisplay(), abs(value - displayBrightness) > threshold {
            displayBrightness = value
            onDisplayChange?(value)
        }
        if let value = Private.keyboardBrightness(), abs(value - keyboardBrightness) > threshold {
            keyboardBrightness = value
            onKeyboardChange?(value)
        }
    }

    private func readDisplay() -> Float? {
        guard let get = Private.displayServicesGetBrightness else { return nil }
        var value: Float = 0
        guard get(display, &value) == 0 else { return nil }
        return min(max(value, 0), 1)
    }
}
