import AppKit
import CoreGraphics

/// Shows brightness HUDs only for physical brightness-key presses. Automatic display and keyboard
/// illumination changes are intentionally silent.
@MainActor
final class BrightnessService {
    enum HUDTarget: Equatable {
        case display
        case keyboard
    }

    private(set) var displayBrightness: Float = 0
    private(set) var keyboardBrightness: Float = 0

    var onDisplayChange: ((Float) -> Void)?
    var onKeyboardChange: ((Float) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var display: CGDirectDisplayID = CGMainDisplayID()

    var isAvailable: Bool { Private.displayServicesGetBrightness != nil }

    func start() {
        display = CGMainDisplayID()
        displayBrightness = readDisplay() ?? 0
        keyboardBrightness = Private.keyboardBrightness() ?? 0
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func setDisplayBrightness(_ value: Float) {
        guard let set = Private.displayServicesSetBrightness else { return }
        _ = set(display, min(max(value, 0), 1))
    }

    static func hudTarget(subtype: Int16, data1: Int) -> HUDTarget? {
        // NX_SUBTYPE_AUX_CONTROL_BUTTONS and NX_KEYDOWN from IOKit/hidsystem/IOLLEvent.h.
        guard subtype == 8, (data1 >> 8) & 0xFF == 10 else { return nil }
        switch (data1 >> 16) & 0xFFFF {
        case 2, 3: return .display
        case 21, 22, 23: return .keyboard
        default: return nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard let target = Self.hudTarget(subtype: event.subtype.rawValue, data1: event.data1) else {
            return
        }
        // Read one main-loop turn after the key event so macOS has applied the new level first.
        Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            self.accept(
                display: self.readDisplay(),
                keyboard: Private.keyboardBrightness(),
                requestedHUD: target
            )
        }
    }

    func accept(display: Float?, keyboard: Float?, requestedHUD: HUDTarget?) {
        if let value = display {
            displayBrightness = value
            if requestedHUD == .display { onDisplayChange?(value) }
        }
        if let value = keyboard {
            keyboardBrightness = value
            if requestedHUD == .keyboard { onKeyboardChange?(value) }
        }
    }

    private func readDisplay() -> Float? {
        guard let get = Private.displayServicesGetBrightness else { return nil }
        var value: Float = 0
        guard get(display, &value) == 0 else { return nil }
        return min(max(value, 0), 1)
    }
}
