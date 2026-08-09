import AVFoundation
import CoreAudio
import Foundation

/// Real output levels for the waveform, via a CoreAudio process tap (macOS 14.4+).
///
/// This is what Alcove's `NSAudioCaptureUsageDescription` is for — the visualiser follows actual
/// audio rather than animating on a timer. Every step can fail (unsupported OS, denied permission,
/// no output device), and every failure just leaves `levels` empty so the bars sit at rest.
@MainActor
final class AudioTapService {
    /// Per-band magnitudes, 0...1, newest first.
    private(set) var levels: [Float] = []

    var onLevels: (([Float]) -> Void)?

    /// Number of bars the island draws.
    private let bandCount = 4

    private nonisolated(unsafe) var tapID: AudioObjectID = 0
    private nonisolated(unsafe) var aggregateID: AudioObjectID = 0
    private nonisolated(unsafe) var procID: AudioDeviceIOProcID?
    private var running = false
    private var publishTimer: Timer?

    private let queue = DispatchQueue(label: "dev.local.tyland.tap")

    /// Smoothed so bars decay instead of flickering frame to frame.
    private var smoothed = [Float](repeating: 0, count: 4)

    private var starting = false
    private var desiredRunning = false

    func start() {
        desiredRunning = true
        guard !running, !starting else { return }
        guard #available(macOS 14.4, *) else {
            Debug.log("audio tap needs macOS 14.4+")
            return
        }
        starting = true

        // Building the tap blocks in `mach_msg` until the Audio Capture consent prompt is answered.
        // On the main actor that freezes the entire app — no MainActor Task can run, so weather,
        // deferred service startup and lock-screen teardown all silently stop. Hop off, come back
        // with the result.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ok = self.buildPipeline()
            await MainActor.run { self.finishStart(ok: ok) }
        }
    }

    /// The blocking half — runs off the main actor.
    /// ponytail: the CoreAudio handles are `nonisolated(unsafe)` because only this method and
    /// `teardown()` touch them, and `starting` serialises them. Promote to an actor if anything
    /// else ever needs them.
    @available(macOS 14.4, *)
    private nonisolated func buildPipeline() -> Bool {
        guard createTap(), createAggregate(), createIOProc() else {
            teardown()
            return false
        }
        return true
    }

    private func finishStart(ok: Bool) {
        starting = false
        guard ok else { return }
        guard desiredRunning else {
            teardown()
            return
        }
        AudioDeviceStart(aggregateID, procID)
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
        }
        RunLoop.main.add(timer, forMode: .common)
        publishTimer = timer
        running = true
        Debug.log("audio tap running")
    }

    func stop() {
        desiredRunning = false
        guard !starting else { return }
        guard running else { return }
        AudioDeviceStop(aggregateID, procID)
        publishTimer?.invalidate()
        publishTimer = nil
        pendingLock.lock(); pending.update(repeating: 0); hasPending = false; pendingLock.unlock()
        teardown()
        running = false
    }

    // MARK: - Setup

    @available(macOS 14.4, *)
    private nonisolated func createTap() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        // Listening must not change what the user hears.
        description.muteBehavior = .unmuted
        description.isPrivate = true

        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != 0 else {
            Debug.log("AudioHardwareCreateProcessTap failed: \(status)")
            return false
        }
        tapUID = description.uuid.uuidString
        return true
    }

    private nonisolated(unsafe) var tapUID = ""

    private nonisolated func createAggregate() -> Bool {
        guard let outputUID = Self.defaultOutputUID() else { return false }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tyland Visualiser",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Private keeps it out of Sound preferences and other apps' device lists.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            // Empty sub-device list: the tap alone supplies the audio. Listing the output device
            // here builds a real aggregate that duplicates the entire output path — it measured
            // ~34% CPU versus ~1% for a tap-only aggregate.
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                // We only need magnitudes, never sample-accurate sync, so skip the resampler.
                kAudioSubTapDriftCompensationKey: false,
            ]],
        ]

        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != 0 else {
            Debug.log("AudioHardwareCreateAggregateDevice failed: \(status)")
            return false
        }
        return true
    }

    private nonisolated func createIOProc() -> Bool {
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inputData, _, _, _ in
            self?.consume(inputData)
        }
        guard status == noErr, procID != nil else {
            Debug.log("AudioDeviceCreateIOProcIDWithBlock failed: \(status)")
            return false
        }
        return true
    }

    private nonisolated func teardown() {
        if let procID, aggregateID != 0 { AudioDeviceDestroyIOProcID(aggregateID, procID) }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = 0
        tapID = 0
    }

    // MARK: - Level extraction

    /// Runs on the audio thread ~90×/s. It must not allocate, hop actors, or touch SwiftUI —
    /// doing so cost ~9% CPU. It writes into `pending` and the 30 Hz publisher picks it up.
    private nonisolated func consume(_ bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first,
              let raw = first.mData,
              first.mDataByteSize > 0
        else { return }

        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        if Debug.enabled {
            callbackCount += 1
            let now = Date().timeIntervalSince1970
            if now - lastReport > 5 {
                Debug.log("tap: \(callbackCount) callbacks in \(Int(now - lastReport))s, buffers=\(buffers.count), floats/cb=\(count)")
                callbackCount = 0
                lastReport = now
            }
        }
        let samples = raw.bindMemory(to: Float.self, capacity: count)

        // Split the block into as many bands as there are bars and take RMS of each.
        // Written straight into the preallocated slot: `[Float](repeating:count:)` here would be a
        // heap allocation on the real-time audio thread, ~90 times a second.
        let stride = max(count / bandCount, 1)
        pendingLock.lock()
        for band in 0..<bandCount {
            let start = band * stride
            let end = min(start + stride, count)
            guard start < end else { pending[band] = 0; continue }
            var sum: Float = 0
            for index in start..<end {
                let value = samples[index]
                guard value.isFinite else { continue }
                sum += value * value
            }
            let rms = (sum / Float(end - start)).squareRoot()
            // Perceptual curve — raw RMS barely moves the bars at normal listening levels.
            pending[band] = min(rms.squareRoot() * 2.2, 1)
        }
        hasPending = true
        pendingLock.unlock()
    }

    private nonisolated(unsafe) var callbackCount = 0
    private nonisolated(unsafe) var lastReport = Date().timeIntervalSince1970
    /// Preallocated once; the audio thread only ever writes into it.
    private nonisolated(unsafe) let pending: UnsafeMutableBufferPointer<Float> = {
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: 4)
        buffer.initialize(repeating: 0)
        return buffer
    }()
    private nonisolated(unsafe) var hasPending = false
    private let pendingLock = NSLock()

    deinit { pending.deallocate() }

    /// Drains whatever the audio thread last measured. 30 Hz is smooth for four bars and an order
    /// of magnitude less main-thread work than publishing per buffer.
    private func drain() {
        pendingLock.lock()
        guard hasPending else { pendingLock.unlock(); return }
        // Copy under the lock into a reused buffer, then release it before doing any work.
        for index in 0..<min(pending.count, incoming.count) { incoming[index] = pending[index] }
        pendingLock.unlock()
        publish()
    }

    /// Reused so the 30 Hz drain never allocates.
    private var incoming = [Float](repeating: 0, count: 4)

    private func publish() {
        var moved = levels.count != smoothed.count
        for index in 0..<min(incoming.count, smoothed.count) {
            let target = incoming[index]
            // Fast attack, slow release, so beats punch and tails fall away.
            let next = target > smoothed[index]
                ? target
                : smoothed[index] * 0.72 + target * 0.28
            // Sub-pixel changes cost a full SwiftUI pass for nothing.
            if !moved, index < levels.count, abs(levels[index] - next) > 0.02 { moved = true }
            smoothed[index] = next
        }
        guard moved else { return }
        levels = smoothed
        onLevels?(smoothed)
    }

    private nonisolated static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &uidSize, &uid) == noErr else { return nil }
        return uid as String
    }
}
