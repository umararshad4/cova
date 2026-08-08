import AppKit
import ImageIO
import SwiftUI

struct MediaState: Equatable {
    var bundleIdentifier: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var isPlaying: Bool = false
    var duration: Double = 0
    /// Elapsed time as of `stamp`, not as of now — use `liveElapsed` for display.
    var elapsed: Double = 0
    var rate: Double = 0
    /// Unix time the helper sampled `elapsed`.
    var stamp: Double = 0
    /// Raw bytes so the struct stays `Equatable`; the image is derived on demand.
    var artworkData: Data?

    /// Browsers often report a playing item with no metadata at all. Duration is the honest
    /// signal that something is loaded; falling back to the app name beats showing nothing.
    var hasTrack: Bool { !title.isEmpty || duration > 0 }

    /// What to show when the player supplies no title.
    var displayTitle: String {
        if !title.isEmpty { return title }
        guard !bundleIdentifier.isEmpty else { return "Playing" }
        return ArtworkCache.shared.appName(for: bundleIdentifier)
    }

    var artwork: NSImage? {
        guard let artworkData else { return nil }
        return ArtworkCache.shared.entry(for: artworkData).image
    }

    /// Where playback alone would have carried `elapsed` by `time` (unix seconds).
    func projectedElapsed(at time: Double) -> Double {
        guard rate > 0, stamp > 0 else { return elapsed }
        let drift = (time - stamp) * rate
        guard drift.isFinite, drift >= 0 else { return elapsed }
        return elapsed + drift
    }

    /// Extrapolated from the last sample so the scrubber moves smoothly without polling the helper.
    var liveElapsed: Double {
        let projected = projectedElapsed(at: Date().timeIntervalSince1970)
        return duration > 0 ? min(projected, duration) : projected
    }

    /// True when `other` reports a position playback alone could not have reached — someone
    /// scrubbed. Elapsed advances on its own, so only a jump is worth repainting for.
    ///
    /// ponytail: 1.5s covers the sampling jitter browsers report; widen it if a player turns out
    /// to be noisier than that.
    func seeked(to other: MediaState) -> Bool {
        abs(other.elapsed - projectedElapsed(at: other.stamp)) > 1.5
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(liveElapsed / duration, 0), 1)
    }

    /// Dominant colour of the album art, used for the island's gradient wash.
    var accent: Color {
        guard let artworkData else { return .white }
        return ArtworkCache.shared.entry(for: artworkData).accent
    }
}

/// One-entry memo for everything derived from `artworkData`.
///
/// `artwork` and `accent` are read from six view bodies, and SwiftUI re-evaluates those on every
/// coordinator publish. Decoding the raw JPEG and averaging it per pass cost a full-size bitmap
/// plus a fresh `CIContext` each time — tens of milliseconds and megabytes, at render rate.
///
/// ponytail: one entry, because one track plays at a time. Make it an LRU if a playlist view
/// ever needs several at once.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    /// Enough for the 54pt artwork at 2x with room to spare; the source is often 3000px square.
    private static let maxPixelSize = 256

    private let lock = NSLock()
    private var key: Data?
    private var cached: (image: NSImage?, accent: Color) = (nil, .white)
    private var appNames: [String: String] = [:]

    func entry(for data: Data) -> (image: NSImage?, accent: Color) {
        lock.lock()
        defer { lock.unlock() }
        // Data's `==` compares length first, so a mismatch is near-free and a hit is a memcmp —
        // still orders of magnitude cheaper than decoding.
        if key == data { return cached }
        let cgImage = Self.decode(data)
        let image = cgImage.map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
        cached = (image, Self.accent(from: cgImage))
        key = data
        return cached
    }

    /// Bundle lookups hit the disk, and `displayTitle` runs in a view body.
    func appName(for bundleIdentifier: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let name = appNames[bundleIdentifier] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String } ?? "Playing"
        appNames[bundleIdentifier] = name
        return name
    }

    /// Decodes straight to a thumbnail. `NSImage(data:)` keeps the full-resolution bitmap alive for
    /// something drawn at 54pt, which is where most of the memory went.
    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    /// Average colour, nudged toward something legible on black.
    ///
    /// Drawing into a 1×1 context is the same box average CIAreaAverage computes, without building
    /// a Core Image pipeline and a Metal-backed `CIContext` to get four bytes out.
    private static func accent(from image: CGImage?) -> Color {
        guard let image else { return .white }
        // Explicitly allocated: `CGContext` keeps the pointer past the call, which `&array` does
        // not promise — under -O that is a real miscompile, not a theoretical one.
        let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        pixel.initialize(repeating: 0, count: 4)
        defer { pixel.deallocate() }

        guard let context = CGContext(
            data: pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .white }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let color = NSColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
        // Album art averages toward mud; push saturation and brightness up so it reads on black.
        guard let hsb = color.usingColorSpace(.deviceRGB) else { return Color(nsColor: color) }
        return Color(nsColor: NSColor(
            hue: hsb.hueComponent,
            saturation: min(hsb.saturationComponent * 1.6, 1),
            brightness: max(hsb.brightnessComponent, 0.65),
            alpha: 1
        ))
    }
}
