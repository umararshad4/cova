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
    private var buffer = Data()
    private var restartDelay: TimeInterval = 0.5
    private var stopping = false

    /// Artwork only arrives when the track changes, so it is carried forward between updates.
    private var lastArtwork: Data?

    private var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/TylandHelper")
    }

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }

    /// Forces a backend. `system` prefers the MediaRemote helper.
    var preferredApp = "system"

    private var fallback: AppleScriptMediaBackend?

    func start() {
        stopping = false

        // An explicit app choice skips the helper entirely.
        if let player = AppleScriptMediaBackend.Player(rawValue: preferredApp.capitalized) {
            useFallback(preferring: player)
            return
        }

        // Start the helper optimistically — blocking launch on a subprocess would stall the app
        // for up to three seconds. The self-test runs alongside and demotes us only if it fails.
        spawn()
        Task { [weak self] in
            let ok = await Self.helperPassesSelfTest(at: self?.helperURL)
            guard let self, !self.stopping, !ok else { return }
            Debug.log("media helper self-test failed — falling back to AppleScript")
            self.stopping = true
            self.input?.fileHandleForWriting.closeFile()
            self.process?.terminate()
            self.process = nil
            self.stopping = false
            self.useFallback(preferring: nil)
        }
    }

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

    /// Runs `TylandHelper test`, which exits 0 only when mediaremoted actually answered.
    /// Off the main actor so a slow or wedged helper cannot stall launch.
    private nonisolated static func helperPassesSelfTest(at url: URL?) async -> Bool {
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else { return false }
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
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func stop() {
        stopping = true
        fallback?.stop()
        fallback = nil
        input?.fileHandleForWriting.closeFile()
        process?.terminate()
        process = nil
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

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.helperDied() }
        }

        do {
            try process.run()
            self.process = process
            self.input = input
            restartDelay = 0.5
            Debug.log("media helper started")
        } catch {
            Debug.log("media helper failed to start: \(error)")
        }
    }

    private func helperDied() {
        guard !stopping else { return }
        process = nil
        input = nil
        Debug.log("media helper died, restarting in \(restartDelay)s")
        let delay = restartDelay
        // Back off so a helper that cannot run doesn't spin.
        restartDelay = min(restartDelay * 2, 30)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopping else { return }
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
