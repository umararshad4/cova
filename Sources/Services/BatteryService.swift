import Foundation
import IOKit.ps

/// Battery percentage and charging state, driven by IOKit's power-source run loop source.
/// Fully event-driven: IOKit wakes us only when something actually changes.
@MainActor
final class BatteryService {
    struct State: Equatable {
        var percent: Int
        var isCharging: Bool
        var isPluggedIn: Bool
        var isCharged: Bool
    }

    private(set) var state: State?

    /// Emitted for meaningful transitions only — plug, unplug, full, and crossing the low threshold.
    var onEvent: ((PowerEvent) -> Void)?
    /// Emitted on every change, for the expanded view's live readout.
    var onChange: ((State) -> Void)?

    private var source: CFRunLoopSource?
    private var lowBatteryAnnounced = false

    private let lowThreshold = 20

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in service.refresh() }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
        refresh(silent: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func refresh(silent: Bool = false) {
        guard let next = Self.read() else { return }
        let previous = state
        state = next
        // IOKit re-notifies for things we don't surface. Publishing anyway rebuilds the whole
        // island view and resizes the panel for an identical reading.
        guard previous != next else { return }
        onChange?(next)
        guard !silent, let previous else { return }

        if next.isPluggedIn != previous.isPluggedIn {
            onEvent?(next.isPluggedIn ? .pluggedIn(percent: next.percent) : .unplugged(percent: next.percent))
        } else if next.isCharged && !previous.isCharged {
            onEvent?(.fullyCharged)
        }

        // Announce the low-battery crossing once, and re-arm only after it recovers.
        if next.percent <= lowThreshold && !next.isPluggedIn && !lowBatteryAnnounced {
            lowBatteryAnnounced = true
            onEvent?(.lowBattery(percent: next.percent))
        } else if next.percent > lowThreshold || next.isPluggedIn {
            lowBatteryAnnounced = false
        }
    }

    private static func read() -> State? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let capacity = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            let state = info[kIOPSPowerSourceStateKey] as? String
            return State(
                percent: Int((Double(capacity) / Double(max) * 100).rounded()),
                isCharging: charging,
                isPluggedIn: state == kIOPSACPowerValue,
                isCharged: info[kIOPSIsChargedKey] as? Bool ?? false
            )
        }
        return nil
    }
}
