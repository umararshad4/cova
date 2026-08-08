import SwiftUI

/// Something worth showing in the island. Transient ones (a volume nudge) expire; live ones
/// (music playing, a Focus mode) stay until their service withdraws them.
enum Activity: Equatable {
    case volume(level: Float, muted: Bool)
    case brightness(level: Float)
    case keyboardBacklight(level: Float)
    case power(PowerEvent)
    case device(DeviceEvent)
    case nowPlaying
    case focus(name: String, symbol: String)
    case recording(RecordingKind)
    case download(count: Int)
    case route(RouteEstimate)

    /// Higher wins. A volume nudge interrupts music; music resumes when the nudge expires.
    var priority: Int {
        switch self {
        case .volume, .brightness, .keyboardBacklight: return 40
        case .device: return 35
        case .power: return 30
        // Music is the resident view: HUDs and connect events interrupt it, but the ambient
        // indicators below must never hide it.
        case .route: return 28
        case .nowPlaying: return 25
        case .download: return 22
        case .recording: return 20
        case .focus: return 15
        }
    }

    /// How long it lingers. `nil` means it stays until withdrawn.
    var duration: TimeInterval? {
        switch self {
        case .volume, .brightness, .keyboardBacklight: return 1.4
        case .power: return 3.0
        case .device: return 4.0
        case .nowPlaying, .focus, .recording, .download, .route: return nil
        }
    }

    /// Width added to the left and right of the notch when this activity is showing.
    var sideWidths: (leading: CGFloat, trailing: CGFloat) {
        switch self {
        case .volume, .brightness, .keyboardBacklight: return (34, 96)
        case .power: return (34, 62)
        // Wide enough that "AirPods Pro Max" lands whole; longer names truncate.
        case .device: return (44, 92)
        case .nowPlaying: return (34, 46)
        case .focus: return (34, 42)
        case .recording: return (30, 34)
        case .download: return (32, 56)
        case .route: return (32, 78)
        }
    }

    /// Activities in the same slot replace each other rather than stacking.
    var slot: String {
        switch self {
        case .volume: return "volume"
        case .brightness: return "brightness"
        case .keyboardBacklight: return "keyboardBacklight"
        case .power: return "power"
        case .device: return "device"
        case .nowPlaying: return "nowPlaying"
        case .focus: return "focus"
        case .recording: return "recording"
        case .download: return "download"
        case .route: return "route"
        }
    }

    /// Live activities persist until their service withdraws them; the rest expire on a timer.
    var isLive: Bool { duration == nil }
}

enum PowerEvent: Equatable {
    case pluggedIn(percent: Int)
    case unplugged(percent: Int)
    case lowBattery(percent: Int)
    case fullyCharged
}

struct DeviceEvent: Equatable {
    var name: String
    var symbol: String
    var connected: Bool
    /// Combined level, as the system reports it. Nil for devices that publish no battery.
    var batteryPercent: Int?
    /// Per-bud and case levels, when the device publishes them (AirPods, Beats).
    var batteryLeft: Int?
    var batteryRight: Int?
    var batteryCase: Int?

    /// True when there is enough detail to show the expanded L/R/Case card.
    var hasDetailedBattery: Bool {
        batteryLeft != nil || batteryRight != nil || batteryCase != nil
    }

    /// What the compact ring displays: combined if given, else the lowest bud.
    var ringPercent: Int? {
        batteryPercent ?? [batteryLeft, batteryRight].compactMap { $0 }.min()
    }
}

enum RecordingKind: Equatable {
    case screen
    case camera
    case microphone

    var symbol: String {
        switch self {
        case .screen: return "record.circle"
        case .camera: return "video.fill"
        case .microphone: return "mic.fill"
        }
    }

    var tint: Color {
        switch self {
        case .screen: return .red
        case .camera: return .green
        case .microphone: return .orange
        }
    }
}
