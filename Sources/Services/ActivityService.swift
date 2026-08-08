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
    private var micListener: AudioObjectPropertyListenerBlock?
    private var micAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var micDevice = AudioDeviceID(kAudioObjectUnknown)
    private var cameraToken: Heartbeat.Token?
    private var cameraInUse = false
    private var screenWatched = false
    private let queue = DispatchQueue(label: "dev.local.tyland.activity")

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
        focusWatcher?.cancel()
        focusWatcher = nil
        if focusDescriptor >= 0 { close(focusDescriptor) }
        focusDescriptor = -1

        if let micListener, micDevice != AudioDeviceID(kAudioObjectUnknown) {
            AudioObjectRemovePropertyListenerBlock(micDevice, &micAddress, queue, micListener)
        }
        micListener = nil

        if let cameraToken { Heartbeat.shared.cancel(cameraToken) }
        cameraToken = nil
    }

    // MARK: - Focus

    private func startFocus() {
        readFocus()
        // The file is rewritten whenever a Focus turns on or off.
        focusDescriptor = open(assertionsURL.path, O_EVTONLY)
        guard focusDescriptor >= 0 else {
            Debug.log("focus: assertions file unavailable")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: focusDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.readFocus() }
        }
        source.resume()
        focusWatcher = source
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

    private func startMicrophone() {
        micDevice = Self.defaultInputDevice()
        guard micDevice != AudioDeviceID(kAudioObjectUnknown) else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.onRecording?(.microphone, Self.isRunningSomewhere(self.micDevice))
            }
        }
        if AudioObjectAddPropertyListenerBlock(micDevice, &micAddress, queue, listener) == noErr {
            micListener = listener
            onRecording?(.microphone, Self.isRunningSomewhere(micDevice))
        }
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

    private func startCamera() {
        // No notification exists for another app opening the camera, so this samples slowly.
        cameraToken = Heartbeat.shared.subscribe(.slow) { [weak self] in
            self?.checkCamera()
            self?.checkScreenRecording()
        }
        checkCamera()
        checkScreenRecording()
    }

    private func checkScreenRecording() {
        guard Private.cgsIsScreenWatcherPresent != nil else { return }
        let watched = Private.screenIsBeingWatched
        guard watched != screenWatched else { return }
        screenWatched = watched
        onRecording?(.screen, watched)
    }

    private func checkCamera() {
        // `DiscoverySession` blocks on the Camera consent prompt. On the main thread that stalls the
        // main actor, which starves *every* Swift Task in the app — weather fetches, deferred
        // service starts, the lot. Keep it on a utility queue and hop back with the answer.
        Task.detached(priority: .utility) {
            let inUse = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video,
                position: .unspecified
            ).devices.contains { $0.isInUseByAnotherApplication }
            await MainActor.run { self.applyCamera(inUse) }
        }
    }

    private func applyCamera(_ inUse: Bool) {
        guard inUse != cameraInUse else { return }
        cameraInUse = inUse
        onRecording?(.camera, inUse)
    }
}
