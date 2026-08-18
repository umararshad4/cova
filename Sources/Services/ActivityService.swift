import AVFoundation
import AppKit
import CoreAudio

/// Ambient live activities: Focus mode, microphone use, camera use.
///
/// Focus comes from the DoNotDisturb assertions file (watched, not polled). Microphone use comes
/// from a CoreAudio property listener. Camera use is the one thing with no push notification, so it
/// is sampled on the same slow tick.
///
/// Screen recording uses the private `CGSIsScreenWatcherPresent` — there is no public equivalent,
/// so the feature disables itself if the symbol ever disappears.
@MainActor
final class ActivityService {
    var onFocus: ((String?, String) -> Void)?
    var onRecording: ((RecordingKind, Bool) -> Void)?

    private var focusWatcher: DispatchSourceFileSystemObject?
    private var focusDescriptor: CInt = -1
    private var focusRetry: Heartbeat.Token?
    /// Set once when the DoNotDisturb folder is TCC-protected — retrying that forever is pointless.
    private(set) var focusNeedsFullDiskAccess = false
    private var micListener: AudioObjectPropertyListenerBlock?
    private var micAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var micDevice = AudioDeviceID(kAudioObjectUnknown)
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var micActive = false
    private var cameraToken: Heartbeat.Token?
    private var cameraCheckInFlight = false
    private var cameraGeneration = 0
    private var pollingEnabled = true
    private var cameraInUse = false
    private var screenWatched = false
    private let queue = DispatchQueue(label: App.queue("activity"))

    private var assertionsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
    }

    func start() {
        startFocus()
        startMicrophone()
        startCamera()
    }

    func stop() {
        cancelFocusRetry()
        focusWatcher?.cancel()
        focusWatcher = nil
        if focusDescriptor >= 0 { close(focusDescriptor) }
        focusDescriptor = -1
        if let inputListener {
            var address = Self.defaultInputAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, inputListener
            )
        }
        inputListener = nil

        if let micListener, micDevice != AudioDeviceID(kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(micDevice, &micAddress, queue, micListener)
        }
        micListener = nil

        setPollingEnabled(false)
    }

    // MARK: - Focus

    /// Watching this file is harder than it looks, in two ways that both end with the Focus
    /// indicator frozen for the rest of the session:
    ///
    /// 1. macOS creates `Assertions.json` on demand when a Focus turns on and *unlinks* it when the
    ///    last one turns off. So it is usually absent at launch, and the original code gave up
    ///    permanently on that with a debug log.
    /// 2. Changes arrive as write-temp-then-rename, so an `O_EVTONLY` descriptor stays bound to the
    ///    old inode. The first toggle delivers `.rename`/`.delete` and every later one is invisible.
    ///
    /// So: re-open on every teardown event, and keep a slow retry running whenever we have no
    /// descriptor at all.
    private func startFocus() {
        readFocus()
        armFocusWatcher()
    }

    private func armFocusWatcher() {
        focusWatcher?.cancel()
        focusWatcher = nil
        if focusDescriptor >= 0 { close(focusDescriptor) }

        focusDescriptor = open(assertionsURL.path, O_EVTONLY)
        guard focusDescriptor >= 0 else {
            // ENOENT is the normal "no Focus is active" state. EPERM means the DoNotDisturb folder
            // is Full-Disk-Access protected and no amount of retrying will help, so say which.
            if errno == EPERM || errno == EACCES {
                focusNeedsFullDiskAccess = true
                Debug.log("focus: needs Full Disk Access — indicator disabled")
                return
            }
            focusDescriptor = -1
            scheduleFocusRetry()
            return
        }

        cancelFocusRetry()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: focusDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            let flags = source.data
            Task { @MainActor in
                guard let self else { return }
                self.readFocus()
                // The inode we hold is gone; the path may already point at a new one.
                if flags.contains(.delete) || flags.contains(.rename) { self.armFocusWatcher() }
            }
        }
        source.resume()
        focusWatcher = source
    }

    private func scheduleFocusRetry() {
        guard focusRetry == nil, !focusNeedsFullDiskAccess else { return }
        focusRetry = Heartbeat.shared.subscribe(.slow) { [weak self] in
            guard let self, self.focusDescriptor < 0 else { return }
            // Cheap: one stat-equivalent open() on the slow tick, only while unwatched.
            if FileManager.default.fileExists(atPath: self.assertionsURL.path) {
                self.readFocus()
                self.armFocusWatcher()
            }
        }
    }

    private func cancelFocusRetry() {
        if let focusRetry { Heartbeat.shared.cancel(focusRetry) }
        focusRetry = nil
    }

    private func readFocus() {
        guard let data = try? Data(contentsOf: assertionsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["data"] as? [[String: Any]]
        else {
            onFocus?(nil, "moon.fill")
            return
        }

        // An empty assertions list means no Focus is active.
        let assertions = records.compactMap { $0["storeAssertionRecords"] as? [[String: Any]] }.flatMap { $0 }
        guard let first = assertions.first,
              let details = first["assertionDetails"] as? [String: Any],
              let identifier = details["assertionDetailsModeIdentifier"] as? String
        else {
            onFocus?(nil, "moon.fill")
            return
        }

        let name = identifier.components(separatedBy: ".").last?.capitalized ?? "Focus"
        onFocus?(name, Self.focusSymbol(for: identifier))
    }

    private static func focusSymbol(for identifier: String) -> String {
        let lower = identifier.lowercased()
        if lower.contains("sleep") { return "bed.double.fill" }
        if lower.contains("work") { return "briefcase.fill" }
        if lower.contains("personal") { return "person.fill" }
        if lower.contains("fitness") { return "figure.run" }
        if lower.contains("driving") { return "car.fill" }
        if lower.contains("gaming") { return "gamecontroller.fill" }
        if lower.contains("reading") { return "book.fill" }
        if lower.contains("mindfulness") { return "brain.head.profile" }
        return "moon.fill"
    }

    // MARK: - Microphone

    /// A fresh value per call: `AudioObject*PropertyListenerBlock` takes the address `inout`, and a
    /// mutable static cannot be `nonisolated`. Matching is by value, so a local copy is equivalent.
    private static func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func startMicrophone() {
        attachMicrophoneListener()

        // The listener is bound to one device id. Plug in a USB mic, switch inputs, or unplug a
        // headset and the old id stops reporting — the indicator would then be stuck on whatever it
        // last saw. Follow the system's default-input property and re-attach.
        let onDefaultChange: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.attachMicrophoneListener() }
        }
        var address = Self.defaultInputAddress()
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, onDefaultChange
        ) == noErr {
            inputListener = onDefaultChange
        }
    }

    private func attachMicrophoneListener() {
        let next = Self.defaultInputDevice()
        if let micListener, micDevice != AudioDeviceID(kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(micDevice, &micAddress, queue, micListener)
        }
        micListener = nil
        micDevice = next
        guard micDevice != AudioDeviceID(kAudioObjectUnknown) else {
            // No input device at all means nothing can be listening.
            if micActive { micActive = false; onRecording?(.microphone, false) }
            return
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.applyMicrophone(Self.isRunningSomewhere(self.micDevice))
            }
        }
        if AudioObjectAddPropertyListenerBlock(micDevice, &micAddress, queue, listener) == noErr {
            micListener = listener
            applyMicrophone(Self.isRunningSomewhere(micDevice))
        }
    }

    /// Deduped like the camera path, so re-attaching after a device change cannot double-fire the
    /// mute/unmute cue.
    private func applyMicrophone(_ active: Bool) {
        guard active != micActive else { return }
        micActive = active
        onRecording?(.microphone, active)
    }

    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func defaultInputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return device
    }

    // MARK: - Camera

    func setPollingEnabled(_ enabled: Bool) {
        guard enabled != pollingEnabled || (enabled && cameraToken == nil) else { return }
        pollingEnabled = enabled
        cameraGeneration &+= 1
        if enabled {
            startCamera()
        } else {
            if let cameraToken { Heartbeat.shared.cancel(cameraToken) }
            cameraToken = nil
        }
    }

    private func startCamera() {
        guard pollingEnabled, cameraToken == nil else { return }
        // No notification exists for another app opening the camera, so this samples slowly.
        cameraToken = Heartbeat.shared.subscribe(.slow) { [weak self] in
            self?.checkCamera()
            self?.checkScreenRecording()
        }
        checkCamera()
        checkScreenRecording()
    }

    private func checkScreenRecording() {
        guard pollingEnabled else { return }
        guard Private.cgsIsScreenWatcherPresent != nil else { return }
        let watched = Private.screenIsBeingWatched
        guard watched != screenWatched else { return }
        screenWatched = watched
        onRecording?(.screen, watched)
    }

    private func checkCamera() {
        guard pollingEnabled, !cameraCheckInFlight else { return }
        cameraCheckInFlight = true
        let generation = cameraGeneration
        // `DiscoverySession` blocks on the Camera consent prompt. On the main thread that stalls the
        // main actor, which starves *every* Swift Task in the app — weather fetches, deferred
        // service starts, the lot. Keep it on a utility queue and hop back with the answer.
        Task.detached(priority: .utility) { [weak self] in
            // `.external` replaced `.externalUnknown` in macOS 14; the deployment floor is 13.
            var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
            if #available(macOS 14.0, *) {
                deviceTypes.append(.external)
            } else {
                deviceTypes.append(.externalUnknown)
            }
            let inUse = AVCaptureDevice.DiscoverySession(
                deviceTypes: deviceTypes,
                mediaType: .video,
                position: .unspecified
            ).devices.contains { $0.isInUseByAnotherApplication }
            await self?.finishCamera(inUse, generation: generation)
        }
    }

    private func finishCamera(_ inUse: Bool, generation: Int) {
        cameraCheckInFlight = false
        guard pollingEnabled, generation == cameraGeneration else {
            if pollingEnabled { checkCamera() }
            return
        }
        applyCamera(inUse)
    }

    private func applyCamera(_ inUse: Bool) {
        guard inUse != cameraInUse else { return }
        cameraInUse = inUse
        onRecording?(.camera, inUse)
    }
}
