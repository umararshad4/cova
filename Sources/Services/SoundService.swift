import AVFoundation
import AppKit

/// Every sound the island can make.
enum SoundCue: String, CaseIterable {
    case volumeTick
    case deviceConnect
    case deviceDisconnect
    case plugIn
    case fullyCharged
    case lowBattery
    case lowPower
    case event
    case chime
    case lock
    case unlock
    case sleep
    case micMute
    case micUnmute
    case downloadComplete
}

enum SoundTheme: String, CaseIterable {
    case synth
    case system
    case off
}

/// Audio feedback, either synthesised or mapped onto sounds macOS already ships.
///
/// Alcove's own `.caf` files are copyrighted assets and its bundle is gone, so nothing here is
/// copied — the synth backend generates buffers from a recipe, and the system backend plays OS
/// files by path.
@MainActor
final class SoundService {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [SoundCue: AVAudioPCMBuffer] = [:]
    private var engineRunning = false
    private var idleTimer: Task<Void, Never>?
    private var lastPlayed: [SoundCue: Date] = [:]

    /// Holding a volume key fires a change every few ms; without this it machine-guns.
    private let minimumInterval: [SoundCue: TimeInterval] = [
        .volumeTick: 0.12,
    ]

    var theme: SoundTheme = .synth
    var volume: Float = 0.6
    var isEnabled = true

    // MARK: - Playback

    func play(_ cue: SoundCue) {
        guard isEnabled, theme != .off else { return }

        if let gap = minimumInterval[cue], let last = lastPlayed[cue],
           Date().timeIntervalSince(last) < gap {
            return
        }
        lastPlayed[cue] = Date()

        switch theme {
        case .synth: playSynth(cue)
        case .system: playSystem(cue)
        case .off: break
        }
    }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        if engineRunning {
            player.stop()
            engine.stop()
            engineRunning = false
        }
    }

    // MARK: - Synth backend

    private func playSynth(_ cue: SoundCue) {
        guard let buffer = buffer(for: cue) else { return }
        startEngineIfNeeded()
        guard engineRunning else { return }
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts])
        if !player.isPlaying { player.play() }
        scheduleIdleShutdown()
    }

    private func buffer(for cue: SoundCue) -> AVAudioPCMBuffer? {
        if let cached = buffers[cue] { return cached }
        guard let built = Self.render(Recipe.for(cue)) else { return nil }
        buffers[cue] = built
        return built
    }

    private func startEngineIfNeeded() {
        guard !engineRunning else { return }
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        }
        do {
            try engine.start()
            engineRunning = true
        } catch {
            Debug.log("sound engine failed to start: \(error.localizedDescription)")
        }
    }

    /// Holding the audio route open costs power, so drop it once the island goes quiet.
    private func scheduleIdleShutdown() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    // MARK: - Synth recipes

    // nonisolated: `render` runs off the main actor so buffers can be built without blocking it.
    nonisolated static let sampleRate: Double = 44_100
    nonisolated static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    /// A cue is one or two short notes with a percussive envelope.
    struct Recipe {
        var notes: [Double]          // frequencies, played in sequence
        var noteDuration: Double     // seconds per note
        var attack: Double           // seconds
        var harmonic: Double         // second-partial amplitude, 0...1
        var gain: Double

        static func `for`(_ cue: SoundCue) -> Recipe {
            switch cue {
            case .volumeTick:
                return Recipe(notes: [1_320], noteDuration: 0.045, attack: 0.002, harmonic: 0.15, gain: 0.35)
            case .deviceConnect:
                // Rising major third, the "connected" gesture.
                return Recipe(notes: [880, 1_108.7], noteDuration: 0.085, attack: 0.005, harmonic: 0.3, gain: 0.5)
            case .deviceDisconnect:
                return Recipe(notes: [1_108.7, 880], noteDuration: 0.085, attack: 0.005, harmonic: 0.25, gain: 0.45)
            case .plugIn:
                return Recipe(notes: [740, 1_174.7], noteDuration: 0.07, attack: 0.003, harmonic: 0.35, gain: 0.5)
            case .fullyCharged:
                return Recipe(notes: [880, 1_174.7, 1_318.5], noteDuration: 0.075, attack: 0.004, harmonic: 0.3, gain: 0.5)
            case .lowBattery, .lowPower:
                return Recipe(notes: [440, 349.2], noteDuration: 0.13, attack: 0.006, harmonic: 0.2, gain: 0.5)
            case .event, .chime:
                return Recipe(notes: [1_046.5, 1_567.9], noteDuration: 0.1, attack: 0.004, harmonic: 0.4, gain: 0.45)
            case .lock:
                return Recipe(notes: [660, 440], noteDuration: 0.07, attack: 0.002, harmonic: 0.1, gain: 0.4)
            case .unlock:
                return Recipe(notes: [440, 660], noteDuration: 0.07, attack: 0.002, harmonic: 0.1, gain: 0.4)
            case .sleep:
                return Recipe(notes: [523.3, 392], noteDuration: 0.16, attack: 0.01, harmonic: 0.15, gain: 0.4)
            case .micMute:
                return Recipe(notes: [587.3, 440], noteDuration: 0.06, attack: 0.002, harmonic: 0.12, gain: 0.4)
            case .micUnmute:
                return Recipe(notes: [440, 587.3], noteDuration: 0.06, attack: 0.002, harmonic: 0.12, gain: 0.4)
            case .downloadComplete:
                return Recipe(notes: [784, 1_046.5], noteDuration: 0.08, attack: 0.003, harmonic: 0.3, gain: 0.45)
            }
        }
    }

    /// Builds the whole cue into one stereo buffer. Done once per cue, then cached.
    nonisolated static func render(_ recipe: Recipe) -> AVAudioPCMBuffer? {
        let total = recipe.noteDuration * Double(recipe.notes.count)
        let frames = AVAudioFrameCount(total * sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frames

        let noteFrames = Int(recipe.noteDuration * sampleRate)
        let attackFrames = max(1, Int(recipe.attack * sampleRate))

        for frame in 0..<Int(frames) {
            let noteIndex = min(frame / max(noteFrames, 1), recipe.notes.count - 1)
            let frameInNote = frame - noteIndex * noteFrames
            let frequency = recipe.notes[noteIndex]

            // Linear attack, exponential decay — reads as a soft percussive blip.
            let envelope: Double
            if frameInNote < attackFrames {
                envelope = Double(frameInNote) / Double(attackFrames)
            } else {
                let decayProgress = Double(frameInNote - attackFrames)
                    / Double(max(noteFrames - attackFrames, 1))
                envelope = exp(-4.5 * decayProgress)
            }

            let phase = 2 * Double.pi * frequency * Double(frameInNote) / sampleRate
            var sample = sin(phase)
            if recipe.harmonic > 0 { sample += recipe.harmonic * sin(phase * 2) }
            sample *= envelope * recipe.gain / (1 + recipe.harmonic)

            let value = Float(max(-1, min(1, sample)))
            channels[0][frame] = value
            channels[1][frame] = value
        }
        return buffer
    }

    // MARK: - System backend

    private static let systemSoundRoot =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"

    /// Maps each cue onto a sound macOS already ships. Missing files degrade to silence, never crash.
    private func playSystem(_ cue: SoundCue) {
        let candidates: [String]
        switch cue {
        case .volumeTick: candidates = ["/System/Library/Sounds/Tink.aiff"]
        case .deviceConnect: candidates = [Self.systemSoundRoot + "media_handoff.caf", "/System/Library/Sounds/Hero.aiff"]
        case .deviceDisconnect: candidates = [Self.systemSoundRoot + "media_paused.caf", "/System/Library/Sounds/Bottle.aiff"]
        case .plugIn: candidates = ["/System/Library/Sounds/Blow.aiff"]
        case .fullyCharged: candidates = ["/System/Library/Sounds/Glass.aiff"]
        case .lowBattery, .lowPower: candidates = ["/System/Library/Sounds/Basso.aiff"]
        case .event, .chime: candidates = ["/System/Library/Sounds/Glass.aiff"]
        case .lock: candidates = [Self.systemSoundRoot + "Volume Unmount.aif", "/System/Library/Sounds/Pop.aiff"]
        case .unlock: candidates = [Self.systemSoundRoot + "Volume Mount.aif", "/System/Library/Sounds/Pop.aiff"]
        case .sleep: candidates = ["/System/Library/Sounds/Submarine.aiff"]
        case .micMute: candidates = [Self.systemSoundRoot + "mic_mute.caf", "/System/Library/Sounds/Morse.aiff"]
        case .micUnmute: candidates = [Self.systemSoundRoot + "mic_unmute.caf", "/System/Library/Sounds/Morse.aiff"]
        case .downloadComplete: candidates = ["/System/Library/Sounds/Ping.aiff"]
        }

        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let sound = NSSound(contentsOfFile: path, byReference: true)
        else {
            Debug.log("no system sound available for \(cue.rawValue)")
            return
        }
        sound.volume = volume
        sound.play()
    }

    /// Used by `--self-test`: every cue must resolve to something playable.
    nonisolated static func allCuesResolve() -> Bool {
        SoundCue.allCases.allSatisfy { render(Recipe.for($0)) != nil }
    }
}
