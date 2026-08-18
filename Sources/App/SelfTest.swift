import AppKit
import Combine
import CryptoKit
import SwiftUI

/// Exercises `@Stored` without touching the user's real preferences.
@MainActor
final class StoredProbe: ObservableObject {
    @Stored("probe.flag") var flag = true
    @Stored("probe.count") var count = 7
    @Stored("probe.label") var label = "hello"
}

/// `Tyland --self-test`. The smallest thing that fails if the core maths breaks.
///
/// ponytail: precondition-based, no test framework. Add XCTest when there's enough logic to warrant
/// it. It must be `precondition` and not `assert`: Swift compiles `assert` out whenever the assert
/// configuration is Debug-off, which `-O` turns off — so the *release* binary, the only one anyone
/// ever ships, evaluated none of these and printed "self-test passed" unconditionally.
@MainActor
func runSelfTests() {
    // --- NotchShape: outline must extend past the box by the top radius on both sides ---
    let box = CGRect(x: 0, y: 0, width: 200, height: 32)
    let bounds = NotchShape(topRadius: 8, bottomRadius: 10).path(in: box).boundingRect
    precondition(abs(bounds.minX - (box.minX - 8)) < 0.01, "left fillet missing: \(bounds)")
    precondition(abs(bounds.maxX - (box.maxX + 8)) < 0.01, "right fillet missing: \(bounds)")
    precondition(abs(bounds.minY - box.minY) < 0.01, "shape must start flush with the screen edge")
    precondition(abs(bounds.maxY - box.maxY) < 0.01, "shape must not exceed its height")

    // --- Radii larger than the box must clamp, not invert the path ---
    let squished = NotchShape(topRadius: 500, bottomRadius: 500).path(in: box).boundingRect
    precondition(squished.height <= box.height + 0.01, "bottom radius did not clamp: \(squished)")
    precondition(squished.width.isFinite && squished.width > 0, "path inverted under large radii")

    // --- Geometry: synthetic fallback and calibration ---
    //
    // A CI runner has no logged-in GUI session, so there may be no screen at all. Skipping the
    // display-dependent half is right; crashing on it would mean the release job could never run
    // any of these checks, which is how the harness ended up untrusted in the first place.
    guard let screen = NSScreen.main else {
        print("self-test: no display attached — display-dependent checks skipped")
        runHeadlessSelfTests()
        exit(0)
    }
    let g = NotchGeometry.detect(screen: screen)
    precondition(g.collapsedSize.width > 0 && g.collapsedSize.height > 0, "collapsed size must be positive")
    precondition(g.topY == screen.frame.maxY, "island must anchor to the top of the screen")
    precondition(screen.frame.minX...screen.frame.maxX ~= g.centerX, "centre must sit on the screen")
    if !g.isPhysical {
        precondition(g.collapsedSize == NotchGeometry.syntheticSize, "synthetic notch should use the default size")
    }

    let calibrated = NotchGeometry.detect(
        screen: screen,
        calibration: .init(width: 240, height: 38)
    )
    if !calibrated.isPhysical {
        precondition(calibrated.collapsedSize == CGSize(width: 240, height: 38), "calibration ignored")
    }

    // --- Brightness: automatic sensor changes must never look like key presses ---
    let brightness = BrightnessService()
    var displayHUDs = 0
    var keyboardHUDs = 0
    brightness.onDisplayChange = { _ in displayHUDs += 1 }
    brightness.onKeyboardChange = { _ in keyboardHUDs += 1 }
    brightness.accept(display: 0.8, keyboard: 0.2, requestedHUD: nil)
    precondition(displayHUDs == 0 && keyboardHUDs == 0,
           "sensor-only brightness changes must stay silent")
    let displayKeyDown = (2 << 16) | (10 << 8)
    precondition(BrightnessService.hudTarget(subtype: 8, data1: displayKeyDown) == .display,
           "display-brightness key-down must request the display HUD")
    let keyboardKeyDown = (21 << 16) | (10 << 8)
    precondition(BrightnessService.hudTarget(subtype: 8, data1: keyboardKeyDown) == .keyboard,
           "keyboard-brightness key-down must request the keyboard HUD")
    let displayKeyUp = (2 << 16) | (11 << 8)
    precondition(BrightnessService.hudTarget(subtype: 8, data1: displayKeyUp) == nil,
           "brightness key-up must not duplicate the HUD")
    brightness.accept(display: 0.9, keyboard: 0.3, requestedHUD: .display)
    brightness.accept(display: 0.9, keyboard: 0.3, requestedHUD: .keyboard)
    precondition(displayHUDs == 1 && keyboardHUDs == 1,
           "each explicit brightness key must show only its matching HUD")

    // --- Lifecycle: lock spaces must never survive sleep or a successful login ---
    var lockLifecycle = LockLifecycleState()
    lockLifecycle.apply(.locked)
    precondition(lockLifecycle.shouldPresent, "locking must present the lock-screen card")
    lockLifecycle.apply(.willSleep)
    precondition(!lockLifecycle.shouldPresent, "sleep must tear down the private lock-screen space")
    lockLifecycle.apply(.didWake(isLocked: true))
    precondition(lockLifecycle.shouldPresent, "wake may restore the card only when still locked")
    lockLifecycle.apply(.sessionBecameActive(isLocked: false))
    precondition(!lockLifecycle.shouldPresent, "login must tear down the lock-screen card")

    var runtime = RuntimePresentationState()
    precondition(!runtime.isHidden, "Tyland must be visible during a normal session")
    runtime.isFullScreen = true
    precondition(runtime.isHidden && !runtime.effectsActive,
           "fullscreen must hide Tyland and pause continuous effects")
    runtime.isFullScreen = false
    runtime.lifecycleSuppressed = true
    precondition(runtime.isHidden && !runtime.effectsActive,
           "lock and sleep must hide Tyland and pause continuous effects")
    precondition(Private.hasActiveFullScreenSpace([
        ["Current Space": ["type": 4]],
    ]), "native fullscreen Spaces must be detected even when the menu bar stays visible")
    precondition(!Private.hasActiveFullScreenSpace([
        ["Current Space": ["type": 0]],
    ]), "a normal desktop Space must not hide Tyland")

    runHeadlessSelfTests()

    // --- Coordinator: panel must always contain the largest island ---
    let c = IslandCoordinator(geometry: g)
    precondition(c.currentSize == g.collapsedSize, "must start collapsed")
    var sizeAtExpansion: CGSize?
    c.onExpand = { sizeAtExpansion = c.currentSize }
    c.toggle()
    precondition(sizeAtExpansion == IslandCoordinator.expandedSize,
           "expansion must start from expanded geometry, not briefly lay out the resting size")
    c.onExpand = nil
    precondition(c.currentSize == IslandCoordinator.expandedSize, "expanding did not change size")
    precondition(c.panelSize.width >= c.currentSize.width, "panel narrower than expanded island")
    precondition(c.panelSize.height >= c.currentSize.height, "panel shorter than expanded island")
    c.collapse()
    precondition(!c.isExpanded, "collapse() failed")

    // --- Hover hot zone must track the island, not the window it grows ---
    // The window is always wider than the island and grows ahead of expansion; if the hot zone ever
    // follows the window, hovering feeds itself and the island chatters open and shut.
    let collapsedZone = NotchPanel.hotZone(island: c.currentSize, geometry: g)
    precondition(collapsedZone.width < c.panelSize.width, "collapsed hot zone must be smaller than the panel")
    precondition(collapsedZone.contains(CGPoint(x: g.centerX, y: g.topY - 1)), "notch centre must be hot")
    precondition(!collapsedZone.contains(CGPoint(x: g.centerX, y: g.topY - IslandCoordinator.expandedSize.height)),
           "collapsed hot zone must not reach where only the expanded island goes")
    c.toggle()
    precondition(NotchPanel.hotZone(island: c.currentSize, geometry: g).width > collapsedZone.width,
           "expanded hot zone should cover the expanded island")
    c.collapse()

    // --- Activity priority: a HUD must preempt music, and music must come back ---
    c.push(.nowPlaying)
    precondition(c.current == .nowPlaying, "live activity should show when nothing outranks it")

    c.push(.volume(level: 0.5, muted: false))
    precondition(c.current == .volume(level: 0.5, muted: false), "volume must preempt music")

    // Same slot replaces rather than stacking.
    c.push(.volume(level: 0.7, muted: false))
    precondition(c.current == .volume(level: 0.7, muted: false), "same-slot activity should replace")

    c.withdraw(slot: "volume")
    precondition(c.current == .nowPlaying, "music must return once the HUD is withdrawn")

    // A lower-priority live activity must not displace a higher-priority one.
    c.push(.focus(name: "Work", symbol: "moon.fill"))
    precondition(c.current == .nowPlaying, "focus outranks nothing here; music has higher priority")

    c.withdraw(slot: "nowPlaying")
    precondition(c.current == .focus(name: "Work", symbol: "moon.fill"), "focus should surface once music is gone")

    c.withdraw(slot: "focus")
    precondition(c.current == nil, "withdrawing everything must return to bare notch")
    precondition(c.currentSize == g.collapsedSize, "bare notch must be exactly the notch size")

    // Charging remains visible after the one-shot plug-in HUD has expired.
    c.battery = .init(percent: 50, isCharging: true, isPluggedIn: true, isCharged: false)
    precondition(c.currentSize.width > g.collapsedSize.width,
           "active charging must reserve room for its persistent indicator")
    c.push(.power(.pluggedIn(percent: 50)))
    precondition(c.showsChargingAccessory,
           "persistent charging icon must appear on the first plug-in frame")
    c.withdraw(slot: "power")

    // --- MediaState: progress must extrapolate, and never divide by a bad duration ---
    var m = MediaState()
    m.title = "Track"
    m.duration = 100
    m.elapsed = 10
    m.rate = 1
    m.stamp = Date().timeIntervalSince1970 - 5
    precondition(abs(m.liveElapsed - 15) < 0.5, "elapsed should advance with the clock: \(m.liveElapsed)")
    precondition(m.progress > 0.14 && m.progress < 0.16, "progress should track elapsed: \(m.progress)")

    m.rate = 0
    precondition(m.liveElapsed == 10, "paused playback must not advance")

    // A track that reports no duration must not produce NaN/infinite progress.
    var noDuration = MediaState()
    noDuration.title = "Live stream"
    noDuration.duration = 0
    noDuration.elapsed = 42
    precondition(noDuration.progress == 0, "zero duration must yield zero progress, not NaN")
    precondition(noDuration.progress.isFinite, "progress must always be finite")

    // Elapsed beyond the end must clamp rather than overshoot the scrubber.
    var overrun = MediaState()
    overrun.duration = 10
    overrun.elapsed = 9
    overrun.rate = 1
    overrun.stamp = Date().timeIntervalSince1970 - 60
    precondition(overrun.liveElapsed <= 10.001, "elapsed must clamp to duration: \(overrun.liveElapsed)")
    precondition(overrun.progress <= 1.0, "progress must clamp to 1")

    // --- Seek detection: a scrub in the player must survive MediaService's repaint filter ---
    var playing = MediaState()
    playing.duration = 300
    playing.elapsed = 30
    playing.rate = 1
    playing.stamp = 1_000
    // Ten seconds later, having simply played on: no jump, so no repaint.
    var advanced = playing
    advanced.elapsed = 40
    advanced.stamp = 1_010
    precondition(!playing.seeked(to: advanced), "normal playback must not read as a seek")
    // Same instant, but the user dragged to 3:00.
    var scrubbed = advanced
    scrubbed.elapsed = 180
    precondition(playing.seeked(to: scrubbed), "a scrub forward must be detected")
    scrubbed.elapsed = 5
    precondition(playing.seeked(to: scrubbed), "a scrub backward must be detected")
    // Scrubbing while paused still moves the anchor, and rate 0 predicts no movement.
    var paused = playing
    paused.rate = 0
    var pausedScrub = paused
    pausedScrub.elapsed = 120
    precondition(paused.seeked(to: pausedScrub), "a scrub while paused must be detected")
    precondition(!paused.seeked(to: paused), "a paused track sitting still is not a seek")

    // --- Artwork cache: decode once, downsample, and never hand back a stale image ---
    var noArt = MediaState()
    precondition(noArt.artwork == nil && noArt.accent == .white, "no artwork means no image and no tint")

    func cover(_ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 1200, height: 1200))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 1200).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { fatalError("could not build test artwork") }
        return png
    }

    noArt.artworkData = cover(NSColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    guard let decoded = noArt.artwork else { fatalError("artwork failed to decode") }
    precondition(max(decoded.size.width, decoded.size.height) <= 256,
           "artwork must be downsampled, got \(decoded.size)")
    precondition(noArt.artwork === decoded, "a repeat read must hit the cache, not decode again")
    let blue = noArt.accent
    precondition(blue != .white, "a blue cover should produce a tint")

    // A different track must invalidate the entry rather than reuse it.
    var other = MediaState()
    other.artworkData = cover(NSColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
    precondition(other.artwork !== decoded, "changed artwork must not return the cached image")
    precondition(other.accent != blue, "changed artwork must not return the cached tint")

    // --- Activity: HUDs outrank music, ambient indicators never do ---
    precondition(Activity.volume(level: 0, muted: false).priority > Activity.nowPlaying.priority,
           "volume must outrank music")
    precondition(Activity.nowPlaying.priority > Activity.focus(name: "", symbol: "").priority,
           "music must outrank focus")
    precondition(Activity.nowPlaying.isLive, "music must persist until withdrawn")
    precondition(!Activity.volume(level: 0, muted: false).isLive, "volume must expire")

    // --- Downloads: only browser placeholders count as in-flight ---
    precondition(DownloadsService.partialExtensions.contains("crdownload"), "chrome partials")
    precondition(!DownloadsService.partialExtensions.contains("zip"), "a finished zip is not a download")

    let downloadFixture = FileManager.default.temporaryDirectory
        .appendingPathComponent("tyland-download-self-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: downloadFixture, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: downloadFixture) }
    FileManager.default.createFile(
        atPath: downloadFixture.appendingPathComponent("sample.crdownload").path,
        contents: Data(repeating: 0, count: 2_048)
    )
    let knownDownload = DownloadsService.snapshot(in: downloadFixture, totalBytes: 4_096)
    precondition(knownDownload.count == 1 && knownDownload.receivedBytes == 2_048,
           "download snapshot must report the live placeholder size")
    precondition(knownDownload.fraction == 0.5, "known download total must produce real progress")
    let unknownDownload = DownloadsService.snapshot(in: downloadFixture)
    precondition(unknownDownload.fraction == nil,
           "missing browser total must remain indeterminate, never invent a percentage")

    let downloads = DownloadsService(directoryURL: downloadFixture)
    var observedDownloadBytes: [Int64] = []
    downloads.onProgress = { observedDownloadBytes.append($0.receivedBytes) }
    downloads.start()
    func waitForDownload(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        return condition()
    }
    precondition(waitForDownload { observedDownloadBytes.last == 2_048 },
           "download service must publish its initial snapshot")
    let partialHandle = try! FileHandle(
        forWritingTo: downloadFixture.appendingPathComponent("sample.crdownload")
    )
    try! partialHandle.seekToEnd()
    try! partialHandle.write(contentsOf: Data(repeating: 0, count: 2_048))
    try! partialHandle.close()
    precondition(waitForDownload { observedDownloadBytes.last == 4_096 },
           "download progress must refresh while an existing partial file grows")
    downloads.stop()

    // --- Battery ring thresholds ---
    precondition(BatteryRing.tint(for: 90) == .green, "high battery green")
    precondition(BatteryRing.tint(for: 35) == .yellow, "middling battery yellow")
    precondition(BatteryRing.tint(for: 5) == .red, "low battery red")

    // --- Device battery: combined wins, else the lower bud ---
    let buds = DeviceEvent(name: "AirPods", symbol: "airpods", connected: true,
                           batteryPercent: nil, batteryLeft: 80, batteryRight: 55, batteryCase: 100)
    precondition(buds.ringPercent == 55, "ring should show the weaker bud: \(String(describing: buds.ringPercent))")
    precondition(buds.hasDetailedBattery, "per-bud levels should enable the detailed card")
    let plain = DeviceEvent(name: "Speaker", symbol: "hifispeaker", connected: true,
                            batteryPercent: nil, batteryLeft: nil, batteryRight: nil, batteryCase: nil)
    precondition(plain.ringPercent == nil && !plain.hasDetailedBattery, "no battery means no ring")


    // --- AppleScript parsing: unit-separated, and Spotify's ms durations normalised ---
    let sep = "\u{1F}"
    let spotify = AppleScriptMediaBackend.parse(
        ["playing", "Song, With Commas", "Artist", "Album", "215000", "12.5"].joined(separator: sep),
        bundleIdentifier: "com.spotify.client"
    )
    precondition(spotify.title == "Song, With Commas", "commas in titles must survive")
    precondition(spotify.isPlaying && spotify.duration == 215, "ms duration should normalise to seconds")
    let music = AppleScriptMediaBackend.parse(
        ["paused", "T", "A", "Al", "215", "1"].joined(separator: sep),
        bundleIdentifier: "com.apple.Music"
    )
    precondition(!music.isPlaying && music.duration == 215, "seconds duration should pass through")
    precondition(AppleScriptMediaBackend.parse("", bundleIdentifier: "x").title.isEmpty, "empty is safe")

    // --- Route: "leave in" is start minus travel ---
    let route = RouteEstimate(destination: "Office", travelMinutes: 20,
                              eventStart: Date().addingTimeInterval(50 * 60))
    precondition(abs(route.leaveInMinutes - 30) <= 1, "leave-in should be 30: \(route.leaveInMinutes)")
    precondition(!route.isUrgent, "30 minutes out is not urgent")
    let late = RouteEstimate(destination: "Office", travelMinutes: 40,
                             eventStart: Date().addingTimeInterval(10 * 60))
    precondition(late.leaveInMinutes < 0 && late.isUrgent, "already-late routes are urgent")

    // --- Scrubber: hovering thickens the bar but must not move anything below it ---
    func barHeight(active: Bool) -> CGFloat {
        NSHostingView(rootView: ScrubberBar(width: 150, fraction: 0.25, tint: .white, active: active))
            .fittingSize.height
    }
    precondition(barHeight(active: false) == ScrubberBar.restHeight,
           "resting bar must be \(ScrubberBar.restHeight)pt, got \(barHeight(active: false))")
    precondition(barHeight(active: true) == barHeight(active: false),
           "hover thickening must overflow, not reflow: \(barHeight(active: true)) vs \(barHeight(active: false))")

    // --- Scrubber wave: zero amplitude is straight; motion stays inside its drawing slot ---
    let waveRect = CGRect(x: 0, y: 0, width: 150, height: ScrubberBar.waveHeight)
    let flatWave = SquigglyProgressShape(amplitude: 0, wavelength: ScrubberBar.wavelength, phase: 0)
        .path(in: waveRect).boundingRect
    precondition(flatWave.height < 0.01, "zero-amplitude progress must be straight: \(flatWave)")
    let wave = SquigglyProgressShape(
        amplitude: ScrubberBar.waveAmplitude,
        wavelength: ScrubberBar.wavelength,
        phase: 0
    )
        .path(in: waveRect).boundingRect
    precondition(wave.height > ScrubberBar.waveAmplitude * 1.9,
           "playing progress must visibly wave: \(wave)")
    precondition(wave.minY >= waveRect.minY && wave.maxY <= waveRect.maxY,
           "progress wave must stay inside its drawing slot: \(wave)")

    // --- Sounds: every cue must render, or the app crashes on a keypress ---
    precondition(SoundService.allCuesResolve(), "every SoundCue must produce a buffer")

    print("self-test passed — notch: \(g.isPhysical ? "physical" : "synthetic") \(g.collapsedSize)")
}


/// Everything that needs no display. Also the whole suite a headless CI runner can execute.
@MainActor
func runHeadlessSelfTests() {
    // --- Kill switch: signed, version-aware, and fails open on anything suspect ---
    let flagKey = Curve25519.Signing.PrivateKey()
    let flagPublicHex = flagKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()

    func flagBlob(disabled: [String], versions: [String]? = nil, signedBy key: Curve25519.Signing.PrivateKey) -> String {
        var object: [String: Any] = ["issued": Date().timeIntervalSince1970, "disabled": disabled]
        if let versions { object["versions"] = versions }
        let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let signature = try! key.signature(for: json)
        return "\(json.base64URLEncoded).\(signature.base64URLEncoded)"
    }

    precondition(
        FeatureFlags.verify(flagBlob(disabled: ["lockScreen"], signedBy: flagKey),
                            publicKeyHex: flagPublicHex, version: "1.0.0") == ["lockScreen"],
        "a correctly signed flag list must be applied"
    )
    precondition(
        FeatureFlags.verify(flagBlob(disabled: ["lockScreen"], signedBy: Curve25519.Signing.PrivateKey()),
                            publicKeyHex: flagPublicHex, version: "1.0.0") == nil,
        "a flag list signed by anyone else must be ignored — otherwise whoever owns the URL owns the app"
    )
    precondition(
        FeatureFlags.verify("garbage", publicKeyHex: flagPublicHex, version: "1.0.0") == nil,
        "an unparseable payload must fail open, not crash"
    )
    precondition(
        FeatureFlags.verify(flagBlob(disabled: ["audioTap"], versions: ["9.9.9"], signedBy: flagKey),
                            publicKeyHex: flagPublicHex, version: "1.0.0") == [],
        "a flag aimed at another version must not disable anything here"
    )
    precondition(
        FeatureFlags.verify(flagBlob(disabled: ["audioTap"], versions: ["1.0.0"], signedBy: flagKey),
                            publicKeyHex: flagPublicHex, version: "1.0.0") == ["audioTap"],
        "a flag aimed at this version must apply"
    )
    precondition(
        FeatureFlags.verify(flagBlob(disabled: [], signedBy: flagKey),
                            publicKeyHex: flagPublicHex, version: "1.0.0") == [],
        "an empty list is the normal, everything-is-fine answer"
    )

    // --- The paywall must arm itself, and must never arm without a usable key ---
    precondition(License.bypassGate == (License.publicKeyHex == License.placeholderKeyHex),
                 "a build with the placeholder key must not enforce a gate no licence can open")

    // --- Meeting links: found where the tools actually put them, and nowhere else ---
    func event(url: URL? = nil, location: String? = nil, notes: String? = nil) -> CalendarEvent {
        CalendarEvent(id: "e", title: "Standup", start: Date(), isAllDay: false,
                      location: location, url: url, notes: notes)
    }

    precondition(event(url: URL(string: "https://zoom.us/j/123")).meetingURL != nil,
                 "a Zoom link in the URL field must be found")
    precondition(event(location: "https://meet.google.com/abc-defg-hij").meetingURL != nil,
                 "Google Meet puts its link in the location field")
    precondition(event(notes: "Dial in: https://teams.microsoft.com/l/meetup-join/x").meetingURL != nil,
                 "Teams puts its link in the notes")
    precondition(event(url: URL(string: "zoommtg://zoom.us/join?confno=1")).meetingURL != nil,
                 "the native scheme has no host and must still be recognised")
    precondition(event(url: URL(string: "https://example.com/agenda")).meetingURL == nil,
                 "an ordinary link is not a meeting — a Join button that opens a wiki is worse than none")
    precondition(event(location: "Room 4, Second Floor").meetingURL == nil,
                 "a physical location is not a meeting link")
    precondition(event().meetingURL == nil, "no link anywhere means no Join button")
    // Subdomain matching must not be fooled by a lookalike host.
    precondition(event(url: URL(string: "https://evil-zoom.us.attacker.com/x")).meetingURL == nil,
                 "a host that merely contains a known domain must not match")

    // --- Licence verification, against a keypair generated right here ---
    //
    // Signing with a real key rather than a canned vector means this exercises the actual CryptoKit
    // path, and cannot pass because someone stubbed the verifier out.
    let signingKey = Curve25519.Signing.PrivateKey()
    let publicHex = signingKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    let machine = "TEST-MACHINE-UUID"
    let now = Date()

    func blob(machine boundTo: String, expiresIn days: Double, tier: String = "pro") -> String {
        let payload = License.Payload(
            tier: tier,
            email: "buyer@example.com",
            machine: boundTo,
            issued: now.timeIntervalSince1970,
            expires: now.addingTimeInterval(days * 86_400).timeIntervalSince1970,
            seats: 3
        )
        let json = try! JSONEncoder().encode(payload)
        let signature = try! signingKey.signature(for: json)
        return "\(json.base64URLEncoded).\(signature.base64URLEncoded)"
    }

    let goodKey = blob(machine: machine, expiresIn: 45)
    precondition(License.verify(goodKey, publicKeyHex: publicHex, machine: machine, now: now) == .success,
                 "a correctly signed licence must verify")

    // Flip one byte of the payload; the signature must stop matching.
    var tampered = Array(goodKey)
    let dotIndex = tampered.firstIndex(of: ".")!
    tampered[dotIndex - 1] = tampered[dotIndex - 1] == "A" ? "B" : "A"
    precondition(License.verify(String(tampered), publicKeyHex: publicHex, machine: machine, now: now) != .success,
                 "a modified payload must not verify — this is the whole point")

    precondition(License.verify(blob(machine: machine, expiresIn: -1),
                                publicKeyHex: publicHex, machine: machine, now: now) != .success,
                 "a blob past its refresh deadline must be rejected")

    precondition(License.verify(blob(machine: "SOMEONE-ELSES-MAC", expiresIn: 45),
                                publicKeyHex: publicHex, machine: machine, now: now) != .success,
                 "a licence bound to another Mac must not work here")

    precondition(License.verify(blob(machine: "", expiresIn: 45),
                                publicKeyHex: publicHex, machine: machine, now: now) == .success,
                 "an unbound licence must work on any Mac")

    let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        .map { String(format: "%02x", $0) }.joined()
    precondition(License.verify(goodKey, publicKeyHex: otherKey, machine: machine, now: now) != .success,
                 "a licence signed by a different key must not verify")

    precondition(License.verify("not-a-licence", publicKeyHex: publicHex, machine: machine, now: now) != .success,
                 "garbage input must be rejected, not crash")

    // Tier resolution: trial, licensed, expired, free.
    precondition(License.resolve(blob: nil, publicKeyHex: publicHex, machine: machine,
                                 trialStart: now, now: now).isPro,
                 "a fresh trial is Pro")
    precondition(!License.resolve(blob: nil, publicKeyHex: publicHex, machine: machine,
                                  trialStart: now.addingTimeInterval(-30 * 86_400), now: now).isPro,
                 "an elapsed trial is not Pro")
    precondition(License.resolve(blob: nil, publicKeyHex: publicHex, machine: machine,
                                 trialStart: nil, now: now) == .free,
                 "no trial record and no licence is the free tier")
    precondition(License.resolve(blob: goodKey, publicKeyHex: publicHex, machine: machine,
                                 trialStart: nil, now: now).isPro,
                 "a valid licence is Pro even with no trial record")
    precondition(License.resolve(blob: blob(machine: machine, expiresIn: -1), publicKeyHex: publicHex,
                                 machine: machine, trialStart: nil, now: now) == .expired,
                 "a lapsed blob reports expired, not free — the user did pay")

    // The free tier must never lose a free feature. Encoded here so the rule cannot drift.
    precondition(License.Tier.free.isPro == false && License.Tier.expired.isPro == false,
                 "non-Pro tiers must not report Pro")

    // --- Preference storage: defaults, round-trip, and change notification ---
    let scratchSuite = "tyland.selftest.\(ProcessInfo.processInfo.processIdentifier)"
    if let scratch = UserDefaults(suiteName: scratchSuite) {
        let realStore = PreferenceStore.defaults
        PreferenceStore.defaults = scratch
        defer {
            PreferenceStore.defaults = realStore
            scratch.removePersistentDomain(forName: scratchSuite)
        }

        let probe = StoredProbe()
        var notifications = 0
        let subscription = probe.objectWillChange.sink { _ in notifications += 1 }

        precondition(probe.flag, "an unset preference must report its declared default")
        precondition(probe.count == 7, "numeric defaults must survive too")
        precondition(probe.label == "hello", "string defaults must survive too")

        probe.flag = false
        probe.count = 12
        probe.label = "changed"
        precondition(!probe.flag && probe.count == 12 && probe.label == "changed",
                     "a written preference must read back")
        precondition(scratch.bool(forKey: "probe.flag") == false,
                     "a written preference must reach UserDefaults, not just the cache")
        precondition(notifications == 3,
                     "every write must notify, or the settings window and the app drift apart")

        // Zero and false are legitimate values, not "unset" — the old `defaults.bool(forKey:)`
        // read could not tell the difference, which is how a false default became unwritable.
        precondition(scratch.object(forKey: "probe.flag") != nil,
                     "false must be stored rather than treated as absent")
        subscription.cancel()
    }

    // --- Fullscreen must be scoped to the island's own display ---
    let twoDisplays: [[String: Any]] = [
        ["Display Identifier": "AAAA-1111", "Current Space": ["type": 0]],
        ["Display Identifier": "BBBB-2222", "Current Space": ["type": 4]],
    ]
    precondition(!Private.hasActiveFullScreenSpace(twoDisplays, matching: "AAAA-1111"),
                 "a fullscreen app on another monitor must not hide the island on this one")
    precondition(Private.hasActiveFullScreenSpace(twoDisplays, matching: "BBBB-2222"),
                 "a fullscreen app on this monitor must hide the island on it")
    precondition(Private.hasActiveFullScreenSpace(twoDisplays),
                 "an unscoped query keeps the any-display meaning")
    precondition(Private.hasActiveFullScreenSpace(twoDisplays, matching: "no-such-display"),
                 "an unrecognised layout falls back to any-display rather than reporting nothing")
    precondition(Private.hasActiveFullScreenSpace(
        [["Display Identifier": "Main", "Current Space": ["type": 4]]], matching: "AAAA-1111"
    ), "some macOS versions label the main display \"Main\" rather than by UUID")

    // --- Each recording kind owns its own slot ---
    let recordingSlots = Set(RecordingKind.allCases.map { Activity.recording($0).slot })
    precondition(recordingSlots.count == RecordingKind.allCases.count,
                 "sharing one slot let a closing mic stream withdraw the camera indicator")

    // --- Downloads: abandoned placeholders must age out, and must not ring the chime ---
    let t0 = Date()
    let growing = DownloadsService.activePartials(
        sizes: ["/d/a.crdownload": 100], known: [:], now: t0
    )
    precondition(growing.active == ["/d/a.crdownload"], "a newly seen partial is active")
    precondition(growing.finished == 0, "nothing finished yet")

    let stalled = DownloadsService.activePartials(
        sizes: ["/d/a.crdownload": 100],
        known: growing.states,
        now: t0.addingTimeInterval(DownloadsService.staleAfter + 1)
    )
    precondition(stalled.active.isEmpty,
                 "a placeholder that stopped growing must drop out, or the 2 Hz poll never stops")
    precondition(stalled.finished == 0, "ageing one out is not a completion and must stay silent")

    let stillGrowing = DownloadsService.activePartials(
        sizes: ["/d/a.crdownload": 250],
        known: growing.states,
        now: t0.addingTimeInterval(DownloadsService.staleAfter + 1)
    )
    precondition(stillGrowing.active == ["/d/a.crdownload"], "growth restarts the clock")

    let completed = DownloadsService.activePartials(
        sizes: [:], known: growing.states, now: t0.addingTimeInterval(1)
    )
    precondition(completed.active.isEmpty && completed.finished == 1,
                 "a live placeholder disappearing is a real completion")

    let abandoned = DownloadsService.activePartials(
        sizes: [:],
        known: stalled.states,
        now: t0.addingTimeInterval(DownloadsService.staleAfter + 2)
    )
    precondition(abandoned.finished == 0,
                 "deleting an already-stale placeholder must not ring the completion chime")
}
