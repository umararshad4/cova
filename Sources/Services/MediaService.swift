import AppKit
import Foundation

/// Spawns and supervises `Contents/Helpers/TylandHelper`, which is signed with a `com.apple.*`
/// identifier so `mediaremoted` will talk to it (see Helper/main.swift and build.sh).
///
/// The helper exits when its stdin closes, so it can never outlive the app.
@MainActor
final class MediaService {
    private(set) var state = MediaState()

    var onUpdate: ((MediaState) -> Void)?

    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 0.5
    private var stopping = false
    /// Bumped on every intentional teardown. `terminate()` is asynchronous, so its termination
    /// handler lands *after* the code that asked for it has moved on — without this the handler
    /// respawned the helper we had just demoted, leaving it duelling the AppleScript fallback.
    private var generation = 0

    /// Artwork only arrives when the track changes, so it is carried forward between updates.
    private var lastArtwork: Data?

    private var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/TylandHelper")
    }

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    /// Forces a backend. `system` prefers the MediaRemote helper.
    var preferredApp = "system"

    /// Skip the MediaRemote helper entirely and use AppleScript.
    ///
    /// This is what the remote kill switch turns on: the day Apple closes the signing-identifier
    /// hole, every customer can be moved to the degraded-but-working path within hours, instead of
    /// staring at a blank island until a Sparkle update reaches them.
    var forceFallback = false

    private var fallback: AppleScriptMediaBackend?

    func start() {
        stopping = false

        // An explicit app choice skips the helper entirely.
        if let player = AppleScriptMediaBackend.Player(rawValue: preferredApp.capitalized) {
            useFallback(preferring: player)
            return
        }
        if forceFallback {
            Debug.log("media: helper disabled remotely — using AppleScript")
            useFallback(preferring: nil)
            return
        }

        // Start the helper optimistically — blocking launch on a subprocess would stall the app
        // for up to three seconds. The probe runs alongside and demotes us only on a real refusal.
        spawn()
        probeHelper(attempt: 0)
    }

    /// `inconclusive` means "mediaremoted answered but nothing is playing", which is
    /// indistinguishable from a refusal in a single sample. Keep the helper — it costs nothing while
    /// idle — and re-ask on a slow cadence until something plays and the answer becomes real.
    private func probeHelper(attempt: Int) {
        Task { [weak self] in
            let verdict = await Self.probe(at: self?.helperURL)
            guard let self, !self.stopping, self.fallback == nil else { return }
            switch verdict {
            case .granted:
                Debug.log("media helper: mediaremoted access confirmed")
            case .refused:
                Debug.log("media helper refused by mediaremoted — falling back to AppleScript")
                self.teardownHelper()
                self.useFallback(preferring: nil)
            case .inconclusive:
                guard attempt < Self.maxProbeAttempts else {
                    Debug.log("media helper: still inconclusive after \(attempt) probes, leaving it running")
                    return
                }
                try? await Task.sleep(for: .seconds(Self.probeRetryDelay))
                guard !self.stopping, self.fallback == nil else { return }
                self.probeHelper(attempt: attempt + 1)
            }
        }
    }

    private static let maxProbeAttempts = 10
    private static let probeRetryDelay: TimeInterval = 60

    private func useFallback(preferring player: AppleScriptMediaBackend.Player?) {
        let backend = AppleScriptMediaBackend()
        backend.preferred = player
        backend.onUpdate = { [weak self] state in
            self?.state = state
            self?.onUpdate?(state)
        }
        backend.start()
        fallback = backend
    }

    /// What `TylandHelper test` reports. Exit 3 is the honest "cannot tell yet".
    enum Verdict {
        case granted
        case refused
        case inconclusive
    }

    /// Runs `TylandHelper test` off the main actor, so a slow or wedged helper cannot stall launch.
    private nonisolated static func probe(at url: URL?) async -> Verdict {
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else { return .refused }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = url
                process.arguments = ["test"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    switch process.terminationStatus {
                    case 0: continuation.resume(returning: .granted)
                    case 3: continuation.resume(returning: .inconclusive)
                    default: continuation.resume(returning: .refused)
                    }
                } catch {
                    continuation.resume(returning: .refused)
                }
            }
        }
    }

    func stop() {
        stopping = true
        fallback?.stop()
        fallback = nil
        teardownHelper()
    }

    /// Changing the music source has to tear the backend down and pick again — `preferredApp` is
    /// only consulted inside `start()`.
    func restart() {
        stop()
        state = MediaState()
        start()
    }

    /// Releases the pipes as well as the process. A readability handler left installed keeps the
    /// pipe (and this service) alive and can still deliver a chunk from a dead helper.
    private func teardownHelper() {
        generation &+= 1
        output?.fileHandleForReading.readabilityHandler = nil
        input?.fileHandleForWriting.closeFile()
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
    }

    func send(_ command: MediaCommand) {
        if let fallback {
            fallback.send(command)
            return
        }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "toggle"
        case .next: verb = "next"
        case .previous: verb = "previous"
        }
        write(verb)
    }

    func seek(to seconds: Double) { write("seek \(seconds)") }

    private func write(_ line: String) {
        guard let handle = input?.fileHandleForWriting else { return }
        // A dead helper means a broken pipe; swallow it and let the supervisor restart.
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: - Supervision

    private func spawn() {
        guard isAvailable else {
            Debug.log("media helper missing at \(helperURL.path)")
            return
        }

        let process = Process()
        process.executableURL = helperURL
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        let spawnGeneration = generation

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.generation == spawnGeneration else { return }
                self.ingest(chunk)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.helperDied(generation: spawnGeneration) }
        }

        do {
            try process.run()
            self.process = process
            self.input = input
            self.output = output
            restartDelay = 0.5
            Debug.log("media helper started")
        } catch {
            Debug.log("media helper failed to start: \(error)")
        }
    }

    private func helperDied(generation spawnGeneration: Int) {
        // A stale handler from a helper we deliberately replaced must not resurrect it.
        guard !stopping, spawnGeneration == generation else { return }
        output?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        Debug.log("media helper died, restarting in \(restartDelay)s")
        let delay = restartDelay
        // Back off so a helper that cannot run doesn't spin.
        restartDelay = min(restartDelay * 2, 30)
        let restartGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopping, restartGeneration == self.generation else { return }
            self.spawn()
        }
    }

    // MARK: - Parsing

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            decode(Data(line))
        }
        // Guard against a runaway producer wedging memory if a newline never arrives.
        if buffer.count > 4_000_000 { buffer.removeAll() }
    }

    private func decode(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let error = json["error"] as? String {
            Debug.log("helper error: \(error)")
            return
        }

        var next = MediaState()
        next.title = json["title"] as? String ?? ""
        next.artist = json["artist"] as? String ?? ""
        next.album = json["album"] as? String ?? ""
        next.bundleIdentifier = json["bundleIdentifier"] as? String ?? ""
        next.isPlaying = json["playing"] as? Bool ?? false
        next.duration = (json["duration"] as? Double).sanitised
        next.rate = (json["rate"] as? Double).sanitised
        next.stamp = (json["stamp"] as? Double).sanitised
        next.elapsed = (json["elapsed"] as? Double).sanitised

        if let encoded = json["artwork"] as? String {
            // An explicit empty string means "this track has no art", not "unchanged".
            lastArtwork = encoded.isEmpty ? nil : Data(base64Encoded: encoded)
        }
        next.artworkData = lastArtwork

        // Elapsed and stamp change on every notification, and the scrubber extrapolates from
        // `liveElapsed`, so a position that merely advanced needs no repaint. A seek does: the
        // anchor moved somewhere playback could not reach, and without a publish the view keeps
        // extrapolating from the pre-seek position forever. Rate matters for the same reason —
        // it is the slope of that extrapolation.
        let previous = state
        state = next
        let unchanged = previous.title == next.title
            && previous.artist == next.artist
            && previous.album == next.album
            && previous.bundleIdentifier == next.bundleIdentifier
            && previous.isPlaying == next.isPlaying
            && previous.duration == next.duration
            && previous.artworkData == next.artworkData
            && previous.rate == next.rate
            && !previous.seeked(to: next)
        guard !unchanged else { return }
        onUpdate?(next)
    }
}

private extension Optional where Wrapped == Double {
    /// MediaRemote occasionally reports NaN/infinite durations, which then poison layout maths.
    var sanitised: Double {
        guard let self, self.isFinite else { return 0 }
        return self
    }
}
