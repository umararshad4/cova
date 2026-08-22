import AppKit
import SwiftUI

/// `Tyland --render-ui <dir>`. Renders the island's states to PNGs offscreen — no panel, no
/// hover, no menu bar. The design harness: every visual change gets verified here first.
@MainActor
func renderUIStates(to directory: String) {
    let dir = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Synthetic notch geometry, same as a non-notch Mac gets.
    let geometry = NotchGeometry(
        collapsedSize: NotchGeometry.syntheticSize,
        centerX: IslandCoordinator.expandedSize.width / 2,
        topY: 0,
        isPhysical: false
    )

    func render(_ name: String, _ size: CGSize, _ configure: (IslandCoordinator) -> Void) {
        let coordinator = IslandCoordinator(geometry: geometry)
        configure(coordinator)

        let host = NSHostingView(rootView: ZStack {
            // Mid-grey backdrop: without it the black island renders black-on-black.
            Rectangle().fill(Color(white: 0.55))
            IslandView(coordinator: coordinator)
        })
        host.frame = CGRect(origin: .zero, size: CGSize(
            width: size.width + IslandCoordinator.panelPadding * 2,
            height: size.height + IslandCoordinator.panelPadding
        ))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write("render \(name): no bitmap rep\n".data(using: .utf8)!)
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
        print("rendered \(name)")
    }

    var media = MediaState()
    media.title = "Whatchu Gonna Do - Sped Up"
    media.artist = "Mr Flintstone"
    media.duration = 236
    media.elapsed = 18
    media.rate = 1
    media.stamp = Date().timeIntervalSince1970

    let events = CalendarPanel.demoEvents

    render("1-idle-ambient", geometry.collapsedSize) {
        $0.events = events
    }

    render("2-pill-nowplaying", geometry.collapsedSize) {
        $0.media = media
        $0.push(.nowPlaying)
    }

    render("3-hud-volume", geometry.collapsedSize) {
        $0.push(.volume(level: 0.35, muted: false))
    }

    render("4-expanded-nowplaying", IslandCoordinator.expandedSize) {
        $0.media = media
        $0.push(.nowPlaying)
        $0.toggle()
    }

    render("5-expanded-calendar", IslandCoordinator.expandedSize) {
        $0.events = events
        $0.toggle()
    }
}
