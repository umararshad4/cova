import ServiceManagement
import SwiftUI

/// User preferences, keyed to match Alcove's own defaults so the vocabulary stays familiar.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var expandOnHover: Bool { didSet { write(expandOnHover, "expandNotchOnHover") } }
    @Published var hoverDuration: Double { didSet { write(hoverDuration, "hoverDuration") } }
    @Published var hideMenuBarIcon: Bool { didSet { write(hideMenuBarIcon, "hideMenuBarIcon") } }
    @Published var hideFromScreenCapture: Bool { didSet { write(hideFromScreenCapture, "hideFromScreenCapture") } }
    @Published var hideWhileInFullscreen: Bool { didSet { write(hideWhileInFullscreen, "hideWhileInFullscreen") } }
    @Published var warnOnLowConnectBattery: Bool { didSet { write(warnOnLowConnectBattery, "warnOnLowConnectBattery") } }
    @Published var showWaveform: Bool { didSet { write(showWaveform, "showWaveform") } }

    /// Point adjustments applied on top of the detected or synthetic notch size.
    @Published var notchAdjustedWidth: Double { didSet { write(notchAdjustedWidth, "notchAdjustedWidth") } }
    @Published var notchAdjustedHeight: Double { didSet { write(notchAdjustedHeight, "notchAdjustedHeight") } }

    @Published var soundsEnabled: Bool { didSet { write(soundsEnabled, "soundsEnabled") } }
    @Published var soundTheme: String { didSet { write(soundTheme, "soundTheme") } }
    @Published var soundVolume: Double { didSet { write(soundVolume, "soundVolume") } }

    /// `system` uses the MediaRemote helper; the rest force an AppleScript backend.
    @Published var musicApp: String { didSet { write(musicApp, "musicApp") } }
    /// Which display the island lives on.
    @Published var showOnDisplay: String { didSet { write(showOnDisplay, "showOnDisplay") } }
    /// Swipe direction follows the trackpad's natural-scroll setting.
    @Published var naturalMovement: Bool { didSet { write(naturalMovement, "naturalMovement") } }
    /// Tint gesture feedback with the system accent colour.
    @Published var useAccentColorOnGestures: Bool { didSet { write(useAccentColorOnGestures, "useAccentColorOnGestures") } }
    /// Stop reacting to anything at all while a full-screen app is frontmost.
    @Published var disableWhileInFullscreen: Bool { didSet { write(disableWhileInFullscreen, "disableWhileInFullscreen") } }

    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin() } }

    private init() {
        defaults.register(defaults: [
            "expandNotchOnHover": true,
            "hoverDuration": 0.0,
            "hideMenuBarIcon": false,
            "hideFromScreenCapture": false,
            "hideWhileInFullscreen": true,
            "warnOnLowConnectBattery": true,
            "showWaveform": true,
            "notchAdjustedWidth": 0.0,
            "notchAdjustedHeight": 0.0,
            "soundsEnabled": true,
            "soundTheme": SoundTheme.synth.rawValue,
            "soundVolume": 0.6,
            "musicApp": "system",
            "showOnDisplay": "builtInDisplay",
            "naturalMovement": true,
            "useAccentColorOnGestures": true,
            "disableWhileInFullscreen": false,
        ])

        expandOnHover = defaults.bool(forKey: "expandNotchOnHover")
        hoverDuration = defaults.double(forKey: "hoverDuration")
        hideMenuBarIcon = defaults.bool(forKey: "hideMenuBarIcon")
        hideFromScreenCapture = defaults.bool(forKey: "hideFromScreenCapture")
        hideWhileInFullscreen = defaults.bool(forKey: "hideWhileInFullscreen")
        warnOnLowConnectBattery = defaults.bool(forKey: "warnOnLowConnectBattery")
        showWaveform = defaults.bool(forKey: "showWaveform")
        notchAdjustedWidth = defaults.double(forKey: "notchAdjustedWidth")
        notchAdjustedHeight = defaults.double(forKey: "notchAdjustedHeight")
        soundsEnabled = defaults.bool(forKey: "soundsEnabled")
        soundTheme = defaults.string(forKey: "soundTheme") ?? SoundTheme.synth.rawValue
        soundVolume = defaults.double(forKey: "soundVolume")
        musicApp = defaults.string(forKey: "musicApp") ?? "system"
        showOnDisplay = defaults.string(forKey: "showOnDisplay") ?? "builtInDisplay"
        naturalMovement = defaults.bool(forKey: "naturalMovement")
        useAccentColorOnGestures = defaults.bool(forKey: "useAccentColorOnGestures")
        disableWhileInFullscreen = defaults.bool(forKey: "disableWhileInFullscreen")
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

    private func write(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Ad-hoc signed builds cannot register a login item; surface it rather than lying.
            Debug.log("launch at login failed: \(error.localizedDescription)")
        }
    }
}
