import CoreLocation
import Foundation
import MapKit

struct RouteEstimate: Equatable {
    var destination: String
    var travelMinutes: Int
    var eventStart: Date

    /// Minutes until you need to leave. Negative means you are already late.
    var leaveInMinutes: Int {
        Int(eventStart.timeIntervalSinceNow / 60) - travelMinutes
    }

    /// Minutes-remaining below which the island turns urgent. Carried on the estimate so the view
    /// stays a pure function of it.
    var urgentBelowMinutes: Int = 15

    var isUrgent: Bool { leaveInMinutes <= urgentBelowMinutes }
}

/// "Leave in N minutes" for the next calendar event that has a location.
///
/// **This is not Alcove's live navigation activity.** macOS exposes no API to read Maps
/// turn-by-turn state — no notification, no scripting dictionary, no supported private interface —
/// so mirroring an in-progress route is not possible. This uses MapKit the way Alcove links it, to
/// deliver the useful half: knowing when to leave.
@MainActor
final class RouteService: NSObject, CLLocationManagerDelegate {
    private(set) var estimate: RouteEstimate?

    var onChange: ((RouteEstimate?) -> Void)?
    /// Surfaced in Settings: the ETA cannot work without a location fix, and macOS never re-prompts
    /// once a user has said no.
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    /// Set by `AppDelegate` from the calendar service.
    var upcomingEvents: [CalendarEvent] = [] {
        didSet {
            guard upcomingEvents.map(\.id) != oldValue.map(\.id) else { return }
            recompute()
        }
    }

    private let locationManager = CLLocationManager()
    private var token: Heartbeat.Token?
    private var inFlight = false
    private var lastRoutedEventID: String?
    private var awaitingFix = false

    /// Only bother routing for events starting within this window.
    var lookahead: TimeInterval = 3 * 3600
    /// Padding added to the travel time, so "leave now" arrives before it is actually now.
    var bufferMinutes = 0
    /// How you get there.
    var transportType: MKDirectionsTransportType = .automobile
    /// Minutes remaining below which the estimate reads as urgent.
    var urgentMinutes = 15

    var authorizationStatus: CLAuthorizationStatus { locationManager.authorizationStatus }

    override init() {
        super.init()
        locationManager.delegate = self
        // A driving ETA does not need a GPS-grade fix, and coarse accuracy is far cheaper.
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        // Recompute every 5 minutes: traffic changes, and the countdown drifts.
        token = Heartbeat.shared.schedule(every: 300, fireImmediately: false) { [weak self] in
            self?.recompute()
        }
    }

    func stop() {
        if let token { Heartbeat.shared.cancel(token) }
        token = nil
    }

    private func recompute() {
        guard let event = nextRoutableEvent() else {
            clear()
            return
        }

        // Authorisation is requested *here*, not at launch: the prompt then arrives with a reason
        // the user can see — there is an actual event with an address on it. Nothing in this file
        // used to ask at all, so `locationManager.location` was nil on every machine and the
        // "leave in N minutes" activity had never once fired.
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            clear()
            return
        case .denied, .restricted:
            clear()
            return
        default:
            break
        }

        guard let origin = locationManager.location else {
            // Authorised, but no fix cached yet — ask for one. `location` is only ever populated by
            // an explicit request; authorisation alone never fills it in.
            if !awaitingFix {
                awaitingFix = true
                locationManager.requestLocation()
            }
            clear()
            return
        }
        awaitingFix = false
        guard !inFlight else { return }
        inFlight = true
        lastRoutedEventID = event.id

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = transportType

        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight = false } }

            // Geocode the event's free-text location to a map item.
            guard let location = event.location,
                  let placemarks = try? await CLGeocoder().geocodeAddressString(location),
                  let destination = placemarks.first?.location
            else {
                await MainActor.run { self?.clear() }
                return
            }

            request.destination = MKMapItem(
                placemark: MKPlacemark(coordinate: destination.coordinate)
            )

            guard let response = try? await MKDirections(request: request).calculateETA() else {
                await MainActor.run { self?.clear() }
                return
            }

            await MainActor.run {
                guard let self else { return }
                let next = RouteEstimate(
                    destination: location,
                    travelMinutes: Int(response.expectedTravelTime / 60) + self.bufferMinutes,
                    eventStart: event.start,
                    urgentBelowMinutes: self.urgentMinutes
                )
                guard next != self.estimate else { return }
                self.estimate = next
                self.onChange?(next)
                Debug.log("route: \(next.travelMinutes) min to \(location), leave in \(next.leaveInMinutes)")
            }
        }
    }

    private func nextRoutableEvent() -> CalendarEvent? {
        upcomingEvents.first {
            !$0.isAllDay
                && ($0.location?.isEmpty == false)
                && $0.start.timeIntervalSinceNow > 0
                && $0.start.timeIntervalSinceNow < lookahead
        }
    }

    private func clear() {
        guard estimate != nil else { return }
        estimate = nil
        onChange?(nil)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.onAuthorizationChange?(status)
            self?.recompute()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            self?.awaitingFix = false
            self?.recompute()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.awaitingFix = false
            Debug.log("route: location failed — \(error.localizedDescription)")
        }
    }
}
