import Foundation
import IOBluetooth
import IOKit

/// Connect/disconnect events for Bluetooth audio devices, with battery where the device reports it.
/// IOBluetooth pushes connection notifications, so nothing polls.
@MainActor
final class BluetoothService {
    var onEvent: ((DeviceEvent) -> Void)?

    private nonisolated(unsafe) var connectObserver: IOBluetoothUserNotification?
    private nonisolated(unsafe) var disconnectObservers: [IOBluetoothUserNotification] = []
    private var thread: Thread?

    /// IOBluetooth registration blocks in `mach_msg` until the Bluetooth consent prompt is answered,
    /// and it needs a live run loop to deliver callbacks. Both rule out the main actor: blocking
    /// there freezes every MainActor Task in the app. It gets its own thread instead.
    func start() {
        guard thread == nil else { return }
        let worker = Thread { [weak self] in
            guard let self else { return }
            self.connectObserver = IOBluetoothDevice.register(
                forConnectNotifications: self,
                selector: #selector(self.deviceConnected(_:device:))
            )
            Debug.log("bluetooth watching")

            // IOBluetooth delivers on the registering thread's run loop, so it has to stay alive.
            // A run loop with no input source returns from `run(mode:before:)` *immediately*, which
            // turns this loop into a 100% CPU spin — the port is what makes it actually block.
            let keepAlive = NSMachPort()
            RunLoop.current.add(keepAlive, forMode: .default)

            while !Thread.current.isCancelled {
                let handled = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(2))
                // Belt and braces: if the loop ever drains its sources, don't spin.
                if !handled { Thread.sleep(forTimeInterval: 0.2) }
            }
        }
        worker.name = "tyland.bluetooth"
        worker.stackSize = 512 * 1024
        worker.start()
        thread = worker
    }

    func stop() {
        thread?.cancel()
        thread = nil
        connectObserver?.unregister()
        disconnectObservers.forEach { $0.unregister() }
        disconnectObservers.removeAll()
        connectObserver = nil
    }

    /// IOBluetooth replays connect notifications for already-connected devices, and can deliver the
    /// same one more than once — without this the island announces every device twice on launch.
    private var connected: Set<String> = []

    @objc private nonisolated func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Registered on the worker thread, so the disconnect hook is set up here too.
        let observer = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        )
        let levels = Self.battery(for: device.addressString)
        let name = device.name ?? "Device"
        let key = device.addressString ?? name

        Task { @MainActor in
            guard self.connected.insert(key).inserted else {
                observer?.unregister()
                return
            }
            if let observer { self.disconnectObservers.append(observer) }
            self.emit(name: name, levels: levels, connected: true)
        }
    }

    @objc private nonisolated func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        let name = device.name ?? "Device"
        let key = device.addressString ?? name
        Task { @MainActor in
            self.disconnectObservers.removeAll { $0 === notification }
            guard self.connected.remove(key) != nil else { return }
            self.emit(name: name, levels: .none, connected: false)
        }
    }

    private func emit(name: String, levels: BatteryLevels, connected: Bool) {
        let event = DeviceEvent(
            name: name,
            symbol: Self.symbol(for: name),
            connected: connected,
            batteryPercent: levels.combined,
            batteryLeft: levels.left,
            batteryRight: levels.right,
            batteryCase: levels.caseLevel
        )
        Debug.log("bluetooth \(connected ? "connected" : "disconnected"): \(name) battery=\(levels)")
        onEvent?(event)
    }

    struct BatteryLevels: Equatable, CustomStringConvertible {
        var combined: Int?
        var left: Int?
        var right: Int?
        var caseLevel: Int?

        static let none = BatteryLevels()

        var description: String {
            let parts = [
                combined.map { "combined \($0)" },
                left.map { "L \($0)" },
                right.map { "R \($0)" },
                caseLevel.map { "case \($0)" },
            ].compactMap { $0 }
            return parts.isEmpty ? "none" : parts.joined(separator: " / ")
        }
    }

    // MARK: - Battery

    /// AirPods and Beats publish battery into the IORegistry rather than over any public API.
    nonisolated static func battery(for address: String?) -> BatteryLevels {
        guard let address else { return .none }
        let target = address.replacingOccurrences(of: ":", with: "-").lowercased()

        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator
        ) == KERN_SUCCESS else { return .none }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let properties = copyProperties(entry) else { continue }
            let entryAddress = (properties["DeviceAddress"] as? String)?
                .replacingOccurrences(of: ":", with: "-").lowercased()
            guard entryAddress == target else { continue }

            // A reported 0 means "not present", not "empty" — treat it as absent.
            func level(_ key: String) -> Int? {
                guard let value = properties[key] as? Int, value > 0 else { return nil }
                return value
            }
            return BatteryLevels(
                combined: level("BatteryPercentCombined"),
                left: level("BatteryPercentLeft"),
                right: level("BatteryPercentRight"),
                caseLevel: level("BatteryPercentCase")
            )
        }
        return .none
    }

    nonisolated private static func copyProperties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dictionary
    }

    // MARK: - Presentation

    private static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if lower.contains("keyboard") { return "keyboard" }
        if lower.contains("mouse") || lower.contains("magic trackpad") { return "magicmouse" }
        return "headphones"
    }
}
