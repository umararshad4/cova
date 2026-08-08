import AppKit
import SwiftUI

/// `Alcove --self-test`. The smallest thing that fails if the geometry or shape math breaks.
/// ponytail: assert-based, no test framework. Add XCTest when there's enough logic to warrant it.
@MainActor
func runSelfTests() {
    // --- NotchShape: outline must extend past the box by the top radius on both sides ---
    let box = CGRect(x: 0, y: 0, width: 200, height: 32)
    let bounds = NotchShape(topRadius: 8, bottomRadius: 10).path(in: box).boundingRect
    assert(abs(bounds.minX - (box.minX - 8)) < 0.01, "left fillet missing: \(bounds)")
    assert(abs(bounds.maxX - (box.maxX + 8)) < 0.01, "right fillet missing: \(bounds)")
    assert(abs(bounds.minY - box.minY) < 0.01, "shape must start flush with the screen edge")
    assert(abs(bounds.maxY - box.maxY) < 0.01, "shape must not exceed its height")

    // --- Radii larger than the box must clamp, not invert the path ---
    let squished = NotchShape(topRadius: 500, bottomRadius: 500).path(in: box).boundingRect
    assert(squished.height <= box.height + 0.01, "bottom radius did not clamp: \(squished)")
    assert(squished.width.isFinite && squished.width > 0, "path inverted under large radii")

    // --- Geometry: synthetic fallback and calibration ---
    guard let screen = NSScreen.main else { fatalError("no screen") }
    let g = NotchGeometry.detect(screen: screen)
    assert(g.collapsedSize.width > 0 && g.collapsedSize.height > 0, "collapsed size must be positive")
    assert(g.topY == screen.frame.maxY, "island must anchor to the top of the screen")
    assert(screen.frame.minX...screen.frame.maxX ~= g.centerX, "centre must sit on the screen")
    if !g.isPhysical {
        assert(g.collapsedSize == NotchGeometry.syntheticSize, "synthetic notch should use the default size")
    }

    let calibrated = NotchGeometry.detect(
        screen: screen,
        calibration: .init(width: 240, height: 38)
    )
    if !calibrated.isPhysical {
        assert(calibrated.collapsedSize == CGSize(width: 240, height: 38), "calibration ignored")
    }

    // --- Coordinator: panel must always contain the largest island ---
    let c = IslandCoordinator(geometry: g)
    assert(c.currentSize == g.collapsedSize, "must start collapsed")
    c.toggle()
    assert(c.currentSize == IslandCoordinator.expandedSize, "expanding did not change size")
    assert(c.panelSize.width >= c.currentSize.width, "panel narrower than expanded island")
    assert(c.panelSize.height >= c.currentSize.height, "panel shorter than expanded island")
    c.collapse()
    assert(!c.isExpanded, "collapse() failed")

    // --- Hover hot zone must track the island, not the window it grows ---
    // The window is always wider than the island and grows ahead of expansion; if the hot zone ever
    // follows the window, hovering feeds itself and the island chatters open and shut.
    let collapsedZone = NotchPanel.hotZone(island: c.currentSize, geometry: g)
    assert(collapsedZone.width < c.panelSize.width, "collapsed hot zone must be smaller than the panel")
    assert(collapsedZone.contains(CGPoint(x: g.centerX, y: g.topY - 1)), "notch centre must be hot")
    assert(!collapsedZone.contains(CGPoint(x: g.centerX, y: g.topY - IslandCoordinator.expandedSize.height)),
           "collapsed hot zone must not reach where only the expanded island goes")
    c.toggle()
    assert(NotchPanel.hotZone(island: c.currentSize, geometry: g).width > collapsedZone.width,
           "expanded hot zone should cover the expanded island")
    c.collapse()

    // --- Activity priority: a HUD must preempt music, and music must come back ---
    c.push(.nowPlaying)
    assert(c.current == .nowPlaying, "live activity should show when nothing outranks it")

    c.push(.volume(level: 0.5, muted: false))
    assert(c.current == .volume(level: 0.5, muted: false), "volume must preempt music")

    // Same slot replaces rather than stacking.
    c.push(.volume(level: 0.7, muted: false))
    assert(c.current == .volume(level: 0.7, muted: false), "same-slot activity should replace")

    c.withdraw(slot: "volume")
    assert(c.current == .nowPlaying, "music must return once the HUD is withdrawn")

    // A lower-priority live activity must not displace a higher-priority one.
    c.push(.focus(name: "Work", symbol: "moon.fill"))
    assert(c.current == .nowPlaying, "focus outranks nothing here; music has higher priority")

    c.withdraw(slot: "nowPlaying")
    assert(c.current == .focus(name: "Work", symbol: "moon.fill"), "focus should surface once music is gone")

    c.withdraw(slot: "focus")
    assert(c.current == nil, "withdrawing everything must return to bare notch")
    assert(c.currentSize == g.collapsedSize, "bare notch must be exactly the notch size")

    // --- MediaState: progress must extrapolate, and never divide by a bad duration ---
    var m = MediaState()
    m.title = "Track"
    m.duration = 100
    m.elapsed = 10
    m.rate = 1
    m.stamp = Date().timeIntervalSince1970 - 5
    assert(abs(m.liveElapsed - 15) < 0.5, "elapsed should advance with the clock: \(m.liveElapsed)")
    assert(m.progress > 0.14 && m.progress < 0.16, "progress should track elapsed: \(m.progress)")

    m.rate = 0
    assert(m.liveElapsed == 10, "paused playback must not advance")

    // A track that reports no duration must not produce NaN/infinite progress.
    var noDuration = MediaState()
    noDuration.title = "Live stream"
    noDuration.duration = 0
    noDuration.elapsed = 42
    assert(noDuration.progress == 0, "zero duration must yield zero progress, not NaN")
    assert(noDuration.progress.isFinite, "progress must always be finite")

    // Elapsed beyond the end must clamp rather than overshoot the scrubber.
    var overrun = MediaState()
    overrun.duration = 10
    overrun.elapsed = 9
    overrun.rate = 1
    overrun.stamp = Date().timeIntervalSince1970 - 60
    assert(overrun.liveElapsed <= 10.001, "elapsed must clamp to duration: \(overrun.liveElapsed)")
    assert(overrun.progress <= 1.0, "progress must clamp to 1")

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
    assert(!playing.seeked(to: advanced), "normal playback must not read as a seek")
    // Same instant, but the user dragged to 3:00.
    var scrubbed = advanced
    scrubbed.elapsed = 180
    assert(playing.seeked(to: scrubbed), "a scrub forward must be detected")
    scrubbed.elapsed = 5
    assert(playing.seeked(to: scrubbed), "a scrub backward must be detected")
    // Scrubbing while paused still moves the anchor, and rate 0 predicts no movement.
    var paused = playing
    paused.rate = 0
    var pausedScrub = paused
    pausedScrub.elapsed = 120
    assert(paused.seeked(to: pausedScrub), "a scrub while paused must be detected")
    assert(!paused.seeked(to: paused), "a paused track sitting still is not a seek")

    // --- Artwork cache: decode once, downsample, and never hand back a stale image ---
    var noArt = MediaState()
    assert(noArt.artwork == nil && noArt.accent == .white, "no artwork means no image and no tint")

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
    assert(max(decoded.size.width, decoded.size.height) <= 256,
           "artwork must be downsampled, got \(decoded.size)")
    assert(noArt.artwork === decoded, "a repeat read must hit the cache, not decode again")
    let blue = noArt.accent
    assert(blue != .white, "a blue cover should produce a tint")

    // A different track must invalidate the entry rather than reuse it.
    var other = MediaState()
    other.artworkData = cover(NSColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
    assert(other.artwork !== decoded, "changed artwork must not return the cached image")
    assert(other.accent != blue, "changed artwork must not return the cached tint")

    // --- Activity: HUDs outrank music, ambient indicators never do ---
    assert(Activity.volume(level: 0, muted: false).priority > Activity.nowPlaying.priority,
           "volume must outrank music")
    assert(Activity.nowPlaying.priority > Activity.focus(name: "", symbol: "").priority,
           "music must outrank focus")
    assert(Activity.nowPlaying.isLive, "music must persist until withdrawn")
    assert(!Activity.volume(level: 0, muted: false).isLive, "volume must expire")

    // --- Downloads: only browser placeholders count as in-flight ---
    assert(DownloadsService.partialExtensions.contains("crdownload"), "chrome partials")
    assert(!DownloadsService.partialExtensions.contains("zip"), "a finished zip is not a download")

    // --- Battery ring thresholds ---
    assert(BatteryRing.tint(for: 90) == .green, "high battery green")
    assert(BatteryRing.tint(for: 35) == .yellow, "middling battery yellow")
    assert(BatteryRing.tint(for: 5) == .red, "low battery red")

    // --- Device battery: combined wins, else the lower bud ---
    let buds = DeviceEvent(name: "AirPods", symbol: "airpods", connected: true,
                           batteryPercent: nil, batteryLeft: 80, batteryRight: 55, batteryCase: 100)
    assert(buds.ringPercent == 55, "ring should show the weaker bud: \(String(describing: buds.ringPercent))")
    assert(buds.hasDetailedBattery, "per-bud levels should enable the detailed card")
    let plain = DeviceEvent(name: "Speaker", symbol: "hifispeaker", connected: true,
                            batteryPercent: nil, batteryLeft: nil, batteryRight: nil, batteryCase: nil)
    assert(plain.ringPercent == nil && !plain.hasDetailedBattery, "no battery means no ring")


    // --- AppleScript parsing: unit-separated, and Spotify's ms durations normalised ---
    let sep = "\u{1F}"
    let spotify = AppleScriptMediaBackend.parse(
        ["playing", "Song, With Commas", "Artist", "Album", "215000", "12.5"].joined(separator: sep),
        bundleIdentifier: "com.spotify.client"
    )
    assert(spotify.title == "Song, With Commas", "commas in titles must survive")
    assert(spotify.isPlaying && spotify.duration == 215, "ms duration should normalise to seconds")
    let music = AppleScriptMediaBackend.parse(
        ["paused", "T", "A", "Al", "215", "1"].joined(separator: sep),
        bundleIdentifier: "com.apple.Music"
    )
    assert(!music.isPlaying && music.duration == 215, "seconds duration should pass through")
    assert(AppleScriptMediaBackend.parse("", bundleIdentifier: "x").title.isEmpty, "empty is safe")

    // --- Route: "leave in" is start minus travel ---
    let route = RouteEstimate(destination: "Office", travelMinutes: 20,
                              eventStart: Date().addingTimeInterval(50 * 60))
    assert(abs(route.leaveInMinutes - 30) <= 1, "leave-in should be 30: \(route.leaveInMinutes)")
    assert(!route.isUrgent, "30 minutes out is not urgent")
    let late = RouteEstimate(destination: "Office", travelMinutes: 40,
                             eventStart: Date().addingTimeInterval(10 * 60))
    assert(late.leaveInMinutes < 0 && late.isUrgent, "already-late routes are urgent")

    // --- Scrubber: hovering thickens the bar but must not move anything below it ---
    func barHeight(active: Bool) -> CGFloat {
        NSHostingView(rootView: ScrubberBar(width: 150, fraction: 0.25, tint: .white, active: active))
            .fittingSize.height
    }
    assert(barHeight(active: false) == ScrubberBar.restHeight,
           "resting bar must be \(ScrubberBar.restHeight)pt, got \(barHeight(active: false))")
    assert(barHeight(active: true) == barHeight(active: false),
           "hover thickening must overflow, not reflow: \(barHeight(active: true)) vs \(barHeight(active: false))")

    // --- Sounds: every cue must render, or the app crashes on a keypress ---
    assert(SoundService.allCuesResolve(), "every SoundCue must produce a buffer")

    print("self-test passed — notch: \(g.isPhysical ? "physical" : "synthetic") \(g.collapsedSize)")
}
