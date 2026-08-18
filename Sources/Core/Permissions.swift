import AVFoundation
import AppKit
import CoreBluetooth
import CoreLocation
import EventKit

/// What Tyland needs from the system, and whether it has it.
///
/// Honest about the gaps: macOS gives a clean pre-flight status for Calendar, Location and Camera,
/// and **none at all** for the CoreAudio process tap or Downloads-folder access. Those two can only
/// be inferred from a call that failed, so they report `.unknown` rather than pretending.
enum Permission: String, CaseIterable, Identifiable {
    case calendar
    case location
    case bluetooth
    case camera
    case audioCapture
    case downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .location: return "Location"
        case .bluetooth: return "Bluetooth"
        case .camera: return "Camera"
        case .audioCapture: return "System audio"
        case .downloads: return "Downloads folder"
        }
    }

    /// Why, in the user's terms, not the system's.
    var reason: String {
        switch self {
        case .calendar:
            return "Shows what's next in the notch, and how long until it starts."
        case .location:
            return "Works out when to leave for an event that has an address. "
                + "Only used when such an event exists, and never leaves this Mac."
        case .bluetooth:
            return "Shows AirPods and other device battery when they connect."
        case .camera:
            return "Lights an indicator when another app is using your camera. "
                + "Tyland never captures video."
        case .audioCapture:
            return "Draws the live waveform next to what's playing. Audio is reduced to four "
                + "loudness numbers and never recorded, stored or sent anywhere."
        case .downloads:
            return "Shows download progress. Reads file sizes only, never file contents."
        }
    }

    /// The widget that needs it, so nothing is requested before it is used.
    var neededBy: String {
        switch self {
        case .calendar, .location: return "Calendar and leave-in time"
        case .bluetooth: return "Bluetooth device battery"
        case .camera: return "Camera in-use indicator"
        case .audioCapture: return "Live waveform"
        case .downloads: return "Download progress"
        }
    }

    enum Status: Equatable {
        case notDetermined
        case granted
        case denied
        /// macOS exposes no way to ask. Inferred at use, or simply not knowable in advance.
        case unknown
    }

    @MainActor
    var status: Status {
        switch self {
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            default: return .granted   // .authorized on 13, .fullAccess on 14+
            }
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            default: return .granted
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            default: return .granted
            }
        case .bluetooth:
            // A proxy only: BluetoothService uses IOBluetooth, not CoreBluetooth, so this reports
            // the system's disposition rather than this app's actual access.
            switch CBManager.authorization {
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            default: return .granted
            }
        case .audioCapture, .downloads:
            return .unknown
        }
    }

    /// The System Settings pane that governs it.
    var settingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .calendar: return URL(string: base + "Privacy_Calendars")
        case .location: return URL(string: base + "Privacy_LocationServices")
        case .bluetooth: return URL(string: base + "Privacy_Bluetooth")
        case .camera: return URL(string: base + "Privacy_Camera")
        case .audioCapture: return URL(string: base + "Privacy_Microphone")
        case .downloads: return URL(string: base + "Privacy_FilesAndFolders")
        }
    }

    @MainActor
    func openSettingsPane() {
        guard let settingsURL else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    /// Asks the system, where asking is possible. `audioCapture` and `downloads` have no request
    /// API — the prompt appears when the feature first runs, which is why both are deferred until
    /// their widget is switched on.
    @MainActor
    func request(_ completion: @escaping (Bool) -> Void) {
        switch self {
        case .calendar:
            let store = EKEventStore()
            let handler: (Bool, Error?) -> Void = { granted, _ in
                Task { @MainActor in completion(granted) }
            }
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents(completion: handler)
            } else {
                store.requestAccess(to: .event, completion: handler)
            }
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in completion(granted) }
            }
        case .location, .bluetooth, .audioCapture, .downloads:
            // These are granted by using the feature, not by asking up front.
            completion(false)
        }
    }
}
