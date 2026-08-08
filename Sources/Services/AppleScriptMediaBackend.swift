import AppKit
import Foundation

/// Now Playing via Apple Events, for when the MediaRemote helper is unavailable.
///
/// This is the insurance policy: if Apple ever closes the `com.apple.*` bundle-id hole in
/// `mediaremoted`, music keeps working instead of vanishing. It is strictly worse than the helper —
/// it polls, it only knows about apps that expose a scripting dictionary, and there is no artwork —
/// so it is only used when the helper fails its self-test or the user forces a specific app.
///
/// ponytail: 2 s poll on the shared heartbeat. Apple Events have no change notification, and this
/// path should be rare. If it becomes the default, revisit.
@MainActor
final class AppleScriptMediaBackend {
    enum Player: String, CaseIterable {
        case music = "Music"
        case spotify = "Spotify"

        var bundleIdentifier: String {
            switch self {
            case .music: return "com.apple.Music"
            case .spotify: return "com.spotify.client"
            }
        }
    }

    var onUpdate: ((MediaState) -> Void)?

    /// Restricts polling to one app. Nil checks every known player.
    var preferred: Player?

    private var token: Heartbeat.Token?
    private var scripts: [Player: NSAppleScript] = [:]
    private var last: MediaState?

    func start() {
        token = Heartbeat.shared.subscribe(.slow) { [weak self] in self?.poll() }
        poll()
        Debug.log("applescript media backend active")
    }

    func stop() {
        if let token { Heartbeat.shared.cancel(token) }
        token = nil
    }

    func send(_ command: MediaCommand) {
        guard let player = activePlayer() else { return }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        }
        run("tell application \"\(player.rawValue)\" to \(verb)")
    }

    // MARK: - Polling

    private func activePlayer() -> Player? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = preferred.map { [$0] } ?? Player.allCases
        return candidates.first { running.contains($0.bundleIdentifier) }
    }

    private func poll() {
        guard let player = activePlayer() else {
            emitIfChanged(MediaState())
            return
        }
        guard let raw = query(player), !raw.isEmpty else {
            emitIfChanged(MediaState())
            return
        }
        emitIfChanged(Self.parse(raw, bundleIdentifier: player.bundleIdentifier))
    }

    /// One script per player, compiled once and reused — recompiling per poll is the expensive part.
    private func query(_ player: Player) -> String? {
        let source = """
        if application "\(player.rawValue)" is running then
            tell application "\(player.rawValue)"
                if player state is stopped then return ""
                set output to (player state as text) & "\u{1F}" & ¬
                    (name of current track) & "\u{1F}" & ¬
                    (artist of current track) & "\u{1F}" & ¬
                    (album of current track) & "\u{1F}" & ¬
                    ((duration of current track) as text) & "\u{1F}" & ¬
                    ((player position) as text)
                return output
            end tell
        end if
        return ""
        """
        let script = scripts[player] ?? NSAppleScript(source: source)
        scripts[player] = script

        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error {
            // -1743 is "not authorised" — the user declined the automation prompt.
            Debug.log("applescript \(player.rawValue) failed: \(error[NSAppleScript.errorNumber] ?? "?")")
            return nil
        }
        return result?.stringValue
    }

    @discardableResult
    private func run(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    private func emitIfChanged(_ state: MediaState) {
        guard state != last else { return }
        last = state
        onUpdate?(state)
    }

    // MARK: - Parsing

    /// Fields are unit-separator delimited so titles containing commas or pipes survive.
    nonisolated static func parse(_ raw: String, bundleIdentifier: String) -> MediaState {
        let fields = raw.components(separatedBy: "\u{1F}")
        guard fields.count >= 6 else { return MediaState() }

        var state = MediaState()
        state.bundleIdentifier = bundleIdentifier
        state.isPlaying = fields[0].lowercased().contains("playing")
        state.title = fields[1]
        state.artist = fields[2]
        state.album = fields[3]
        // Music reports seconds; Spotify reports milliseconds.
        let duration = Double(fields[4]) ?? 0
        state.duration = duration > 10_000 ? duration / 1000 : duration
        state.elapsed = Double(fields[5]) ?? 0
        state.rate = state.isPlaying ? 1 : 0
        state.stamp = Date().timeIntervalSince1970
        // No artwork over Apple Events — better an honest gap than shelling out for it.
        state.artworkData = nil
        return state
    }
}
