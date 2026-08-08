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

    var isUrgent: Bool { leaveInMinutes <= 15 }
}

/// "Leave in N minutes" for the next calendar event that has a location.
///
/// **This is not Alcove's live navigation activity.** macOS exposes no API to read Maps
/// turn-by-turn state — no notification, no scripting dictionary, no supported private interface —
/// so mirroring an in-progress route is not possible. This uses MapKit the way Alcove links it, to
/// deliver the useful half: knowing when to leave.
@MainActor
final class RouteService {
    private(set) var estimate: RouteEstimate?

    var onChange: ((RouteEstimate?) -> Void)?

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

    /// Only bother routing for events starting within this window.
    private let lookahead: TimeInterval = 3 * 3600

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
        guard let origin = locationManager.location else {
            // No location fix means no honest ETA — say nothing rather than guess.
            clear()
            return
        }
        guard !inFlight else { return }
        inFlight = true
        lastRoutedEventID = event.id

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.transportType = .automobile

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
                    travelMinutes: Int(response.expectedTravelTime / 60),
                    eventStart: event.start
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
}
