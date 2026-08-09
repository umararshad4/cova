import CoreAudio
import Foundation

/// Watches system output volume and mute.
///
/// Purely event-driven via CoreAudio property listeners — no polling, and no Input Monitoring
/// permission, which is the constraint Alcove sets for itself.
@MainActor
final class AudioService {
    private(set) var volume: Float = 0
    private(set) var isMuted = false

    /// Fires only on real user-visible changes, never on the initial read.
    var onChange: ((Float, Bool) -> Void)?

    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private let queue = DispatchQueue(label: "dev.local.tyland.audio")
    private var primed = false

    private static let virtualMainVolume = fourCC("vmvc")

    func start() {
        attachDefaultDeviceListener()
        bindCurrentDevice()
        // Read once so the first real change has something to compare against.
        refresh(notify: false)
        primed = true
    }

    func stop() {
        for (object, address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
        }
        listeners.removeAll()
    }

    // MARK: - Wiring

    private func attachDefaultDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                // Switching output (speakers → AirPods) means re-subscribing to the new device.
                self?.bindCurrentDevice()
                self?.refresh(notify: false)
            }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        ) == noErr {
            listeners.append((AudioObjectID(kAudioObjectSystemObject), address, block))
        }
    }

    private func bindCurrentDevice() {
        let newDevice = Self.defaultOutputDevice()
        guard newDevice != device else { return }
        removeDeviceListeners()
        device = newDevice
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return }

        for selector in [Self.virtualMainVolume, kAudioDevicePropertyMute] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refresh(notify: true) }
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
                listeners.append((device, address, block))
            }
        }
    }

    private func removeDeviceListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (object, address, block) in listeners where object != system {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
        }
        listeners.removeAll { $0.0 != system }
    }

    private func refresh(notify: Bool) {
        let newVolume = Self.readVolume(device)
        let newMuted = Self.readMuted(device)
        let changed = newVolume != volume || newMuted != isMuted
        volume = newVolume
        isMuted = newMuted
        if notify, changed, primed { onChange?(newVolume, newMuted) }
    }

    // MARK: - CoreAudio reads

    private static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return id
    }

    private static func readVolume(_ device: AudioDeviceID) -> Float {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: virtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func readMuted(_ device: AudioDeviceID) -> Bool {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }
}

/// CoreAudio selectors are four-character codes.
func fourCC(_ string: String) -> UInt32 {
    string.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
}
