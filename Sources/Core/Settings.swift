import ServiceManagement
import SwiftUI

/// User preferences.
///
/// Every entry is a single `@Stored` declaration: key, default and storage in one line. The previous
/// shape needed the same setting written in three places, and five toggles had drifted into writing
/// a value that nothing read — a third of the shipped preference pane did nothing.
///
/// Key names are historic and must not be renamed: they are what is already on users' disks.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    // MARK: - General

    @Stored("expandNotchOnHover") var expandOnHover = true
    @Stored("hoverDuration") var hoverDuration = 0.0
    @Stored("hideMenuBarIcon") var hideMenuBarIcon = false
    @Stored("hideFromScreenCapture") var hideFromScreenCapture = false
    @Stored("hideWhileInFullscreen") var hideWhileInFullscreen = true
    /// Which display the island lives on: `builtInDisplay` or `activeDisplay`.
    @Stored("showOnDisplay") var showOnDisplay = "builtInDisplay"

    // MARK: - Widgets
    //
    // These replace `debugSkipServices`, which was a documented Terminal incantation and the only
    // way to turn any feature off.

    @Stored("showNowPlaying") var showNowPlaying = true
    @Stored("showWaveform") var showWaveform = true
    @Stored("showCalendar") var showCalendar = true
    @Stored("showRoute") var showRoute = true
    @Stored("showDownloads") var showDownloads = true
    @Stored("showFocus") var showFocus = true
    @Stored("showRecording") var showRecording = true
    @Stored("showBluetooth") var showBluetooth = true
    @Stored("showBattery") var showBattery = true
    @Stored("showParticles") var showParticles = true

    // MARK: - Timing

    /// How long a volume/brightness nudge lingers, and the two slower classes that scale off it.
    @Stored("hudDismissDelay") var hudDismissDelay = 1.4
    @Stored("powerDismissDelay") var powerDismissDelay = 3.0
    @Stored("deviceDismissDelay") var deviceDismissDelay = 4.0

    // MARK: - Gestures

    /// Swipe direction follows the trackpad's natural-scroll setting.
    @Stored("naturalMovement") var naturalMovement = true
    /// Tint gesture and device feedback with the system accent colour.
    @Stored("useAccentColorOnGestures") var useAccentColorOnGestures = true
    /// Scroll distance before a swipe counts, and how long before another can fire.
    @Stored("gestureThreshold") var gestureThreshold = 18.0
    @Stored("gestureCooldown") var gestureCooldown = 0.45

    // MARK: - Battery

    @Stored("lowBatteryThreshold") var lowBatteryThreshold = 20
    @Stored("warnOnLowConnectBattery") var warnOnLowConnectBattery = true
    @Stored("deviceLowBatteryThreshold") var deviceLowBatteryThreshold = 20

    // MARK: - Calendar and route

    @Stored("calendarLookaheadHours") var calendarLookaheadHours = 18
    @Stored("calendarEventLimit") var calendarEventLimit = 4
    /// Padding added to travel time, so "leave now" lands before it actually is now.
    @Stored("routeBufferMinutes") var routeBufferMinutes = 0
    @Stored("routeTransportType") var routeTransportType = "automobile"
    @Stored("routeUrgentMinutes") var routeUrgentMinutes = 15

    // MARK: - Downloads

    /// Extra folders to watch. Empty means ~/Downloads alone.
    @Stored("downloadFolders") var downloadFolders: [String] = []
    /// Chromium persists a download's total size in its History database, which is the only way to
    /// show a determinate progress bar for those browsers. Only `target_path`, `total_bytes` and
    /// `start_time` are ever read — never URLs or history — but it is still the user's browsing
    /// database, so it is a switch they own.
    @Stored("readBrowserDownloadTotals") var readBrowserDownloadTotals = true

    // MARK: - Sounds

    @Stored("soundsEnabled") var soundsEnabled = true
    @Stored("soundTheme") var soundTheme = SoundTheme.synth.rawValue
    @Stored("soundVolume") var soundVolume = 0.6

    // MARK: - Media

    /// `system` uses the MediaRemote helper; the rest force an AppleScript backend.
    @Stored("musicApp") var musicApp = "system"

    // MARK: - Notch

    /// Point adjustments applied on top of the detected or synthetic notch size.
    @Stored("notchAdjustedWidth") var notchAdjustedWidth = 0.0
    @Stored("notchAdjustedHeight") var notchAdjustedHeight = 0.0

    // MARK: - Lock screen
    //
    // Previously reachable only through undocumented `defaults write` keys. Same keys, so anyone
    // who already enabled it keeps their setting.

    @Stored("lockScreenEnabled") var lockScreenEnabled = false
    @Stored("lockScreenPosition") var lockScreenPosition = 0.72

    // MARK: - First run

    /// Set once the onboarding window has been dismissed. Nothing that can prompt starts before it.
    @Stored("hasCompletedOnboarding") var hasCompletedOnboarding = false

    // MARK: - Login item

    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }

    private init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var resolvedSoundTheme: SoundTheme { SoundTheme(rawValue: soundTheme) ?? .synth }

    /// Calibration the geometry layer applies to the synthetic notch.
    var calibration: NotchGeometry.Calibration {
        NotchGeometry.Calibration(
            width: notchAdjustedWidth == 0 ? nil : NotchGeometry.syntheticSize.width + notchAdjustedWidth,
            height: notchAdjustedHeight == 0 ? nil : NotchGeometry.syntheticSize.height + notchAdjustedHeight
        )
    }

    /// Folders the downloads watcher should observe. Always includes ~/Downloads.
    var watchedDownloadFolders: [URL] {
        let home = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        var seen = Set<String>()
        return ([home] + downloadFolders.map { URL(fileURLWithPath: $0) })
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Debug.log("launch at login failed: \(error.localizedDescription)")
        }
    }
}
