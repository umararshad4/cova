import AppKit
import Foundation

// Alcove's trick, reimplemented: mediaremoted grants MediaRemote access to processes whose code
// signing identifier starts with `com.apple.`. The real app ships an XPC service identified as
// `com.apple.controlcenter.TylandHelper`; we sign this binary as `com.apple.tyland.mediahelper`
// (see build.sh) and keep it as a plain child process, which is simpler and pipe-testable.
//
// Protocol: newline-delimited JSON on stdout, one-word commands on stdin.
// Standalone check:  ./TylandHelper test   → exits 0 when MediaRemote answers.

private let mediaRemote = dlopen(
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY
)

private func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle = mediaRemote, let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: type)
}

// The blocks outlive the call — MediaRemote answers asynchronously on `queue` — so they must be
// declared escaping or the runtime traps.
private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
private typealias GetPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
private typealias GetPID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
private typealias Register = @convention(c) (DispatchQueue) -> Void
private typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
private typealias SetElapsed = @convention(c) (Double) -> Void

private let getNowPlayingInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: GetInfo.self)
private let getIsPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetPlaying.self)
private let getPID = symbol("MRMediaRemoteGetNowPlayingApplicationPID", as: GetPID.self)
private let registerForNotifications = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: Register.self)
private let sendCommand = symbol("MRMediaRemoteSendCommand", as: Send.self)
private let setElapsed = symbol("MRMediaRemoteSetElapsedTime", as: SetElapsed.self)

// Concurrent, not serial. MediaRemote delivers every reply onto this queue, and the PID/isPlaying
// queries never answer when no player is registered — on a serial queue those dead replies block
// the head of the line and the now-playing callback never runs.
private let queue = DispatchQueue(label: "tyland.helper.mediaremote", attributes: .concurrent)

/// Artwork can arrive after the rest of the metadata, especially from browsers and VLC.
private struct ArtworkTracker {
    private var trackKey = ""
    private var artwork: Data?

    mutating func encodedArtwork(trackKey: String, artwork: Data?, force: Bool = false) -> String? {
        let trackChanged = trackKey != self.trackKey
        self.trackKey = trackKey
        // mediaremoted leaves ArtworkData out of most refreshes. Measured on Spotify: the same
        // track alternates between the full JPEG and no artwork key every couple of notifications,
        // and a transport command fires three to five of them at once. Reporting every gap as "no
        // artwork" is what made the island blink its cover, its accent colour and its background
        // wash two or three times on every button press. Absent means unchanged; only a new track
        // may clear the art.
        guard artwork != nil || trackChanged else { return nil }
        let shouldEmit = force || trackChanged || artwork != self.artwork
        self.artwork = artwork
        guard shouldEmit else { return nil }
        return artwork?.base64EncodedString() ?? ""
    }
}

private var artworkTracker = ArtworkTracker()

private let debugEnabled = ProcessInfo.processInfo.environment["TYLAND_DEBUG"] == "1"

private func trace(_ message: String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write("[helper] \(message)\n".data(using: .utf8)!)
}

private func write(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object) else {
        trace("payload not JSON-serialisable: \(object.keys.sorted())")
        return
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          var line = String(data: data, encoding: .utf8) else {
        trace("JSON encode failed")
        return
    }
    line += "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    trace("emitted \(line.count) bytes")
}

// `GetNowPlayingApplicationIsPlaying` and `GetNowPlayingApplicationPID` do not invoke their blocks
// when no player is registered, so nesting them inside the info callback silently emits nothing.
// They are refreshed independently and only decorate the payload.
private nonisolated(unsafe) var cachedPlaying = false
private nonisolated(unsafe) var cachedBundle = ""
private let cacheLock = NSLock()

private func refreshAux() {
    getIsPlaying?(queue) { playing in
        cacheLock.lock(); cachedPlaying = playing; cacheLock.unlock()
    }
    getPID?(queue) { pid in
        guard pid > 0,
              let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              let bundle = app.bundleIdentifier
        else { return }
        cacheLock.lock(); cachedBundle = bundle; cacheLock.unlock()
    }
}

private func readCache() -> (playing: Bool, bundle: String) {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return (cachedPlaying, cachedBundle)
}

/// Emits one payload from the now-playing dictionary alone, so it always fires.
private func emit(force: Bool = false) {
    guard let getNowPlayingInfo else {
        write(["error": "MediaRemote symbols unavailable"])
        return
    }
    trace("emit requested (force: \(force))")
    refreshAux()

    getNowPlayingInfo(queue) { raw in
        trace("info callback fired, keys: \((raw as? [String: Any])?.count ?? -1)")
        let info = raw as? [String: Any] ?? [:]
        var payload: [String: Any] = [:]

        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0

        payload["title"] = title
        payload["artist"] = artist
        payload["album"] = album
        // Rate is authoritative and arrives with the dictionary; the cached flag is a backstop for
        // players that report a rate of 0 while still playing.
        let cache = readCache()
        payload["playing"] = rate > 0 || (title.isEmpty ? false : cache.playing)
        payload["duration"] = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
        payload["elapsed"] = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
        payload["rate"] = rate
        // Lets the app extrapolate progress without asking again every second. The anchor is when
        // the *player* sampled ElapsedTime, not when we happened to emit — browsers refresh the
        // metadata without re-sampling position, so our own clock would report the track further
        // along than it is. Trust the reported date only if it is sane; a stale one would otherwise
        // pin the scrubber at the end of the track.
        let now = Date()
        let sampled = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
        let age = sampled.map { now.timeIntervalSince($0) } ?? -1
        payload["stamp"] = (age >= 0 && age < 3600 ? sampled! : now).timeIntervalSince1970
        payload["bundleIdentifier"] = cache.bundle

        let trackKey = "\(title)|\(artist)|\(album)"
        let artwork = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
        cacheLock.lock()
        let encodedArtwork = artworkTracker.encodedArtwork(
            trackKey: trackKey, artwork: artwork, force: force
        )
        cacheLock.unlock()
        if let encodedArtwork { payload["artwork"] = encodedArtwork }

        write(payload)
    }
}

private func handle(command: String) {
    let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
    guard let verb = parts.first else { return }

    let codes: [String: UInt32] = [
        "play": 0, "pause": 1, "toggle": 2, "next": 4, "previous": 5,
    ]

    if let code = codes[verb] {
        _ = sendCommand?(code, nil)
        // The change notification can lag the command; nudge an update out.
        queue.asyncAfter(deadline: .now() + 0.25) { emit() }
    } else if verb == "seek", parts.count > 1, let seconds = Double(parts[1]) {
        setElapsed?(seconds)
        queue.asyncAfter(deadline: .now() + 0.25) { emit() }
    } else if verb == "refresh" {
        emit(force: true)
    }
}

// MARK: - Entry

if CommandLine.arguments.contains("artwork-test") {
    var tracker = ArtworkTracker()
    let cover = Data("delayed-cover".utf8)
    _ = tracker.encodedArtwork(trackKey: "video", artwork: nil, force: true)
    assert(tracker.encodedArtwork(trackKey: "video", artwork: cover) == cover.base64EncodedString(),
           "artwork arriving after metadata must be emitted")
    // The flicker: mediaremoted omits the artwork from most refreshes of the same track.
    assert(tracker.encodedArtwork(trackKey: "video", artwork: nil) == nil,
           "a refresh without artwork must not clear the cover mid-track")
    assert(tracker.encodedArtwork(trackKey: "video", artwork: cover) == nil,
           "the cover coming back must not repaint either — it never went away")
    assert(tracker.encodedArtwork(trackKey: "other", artwork: nil) == "",
           "a new track with no artwork must clear the previous cover")
    print("artwork test passed")
    exit(0)
}

if CommandLine.arguments.contains("test") {
    // Exit 0 only if MediaRemote answers — this is what proves the signing-identifier trick worked.
    guard let getNowPlayingInfo else {
        FileHandle.standardError.write("MediaRemote not loadable\n".data(using: .utf8)!)
        exit(2)
    }
    // The question is "will mediaremoted talk to us", NOT "is something playing right now".
    // A nil/empty dictionary still proves access was granted; only silence means refusal.
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var callbackFired = false
    getNowPlayingInfo(queue) { _ in
        callbackFired = true
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 3)
    if callbackFired {
        print("ok")
        exit(0)
    }
    FileHandle.standardError.write("mediaremoted did not answer (entitlement refused)\n".data(using: .utf8)!)
    exit(1)
}

registerForNotifications?(queue)

for name in [
    "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
    "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
    "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
] {
    NotificationCenter.default.addObserver(
        forName: Notification.Name(name), object: nil, queue: .main
    ) { _ in emit() }
}

// Commands arrive on stdin; a closed pipe means the app is gone, so exit with it.
DispatchQueue.global(qos: .utility).async {
    while let line = readLine(strippingNewline: true) {
        handle(command: line)
    }
    exit(0)
}

emit(force: true)
RunLoop.main.run()
