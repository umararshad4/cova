import EventKit
import Foundation

/// Upcoming events for the glance column. EventKit is public API and pushes change notifications,
/// so this only re-reads when the store actually changes or the day rolls over.
@MainActor
final class CalendarService {
    private(set) var events: [CalendarEvent] = []
    /// Day-of-month numbers in the current month that carry at least one event.
    private(set) var busyDays: Set<Int> = []

    var onChange: (([CalendarEvent]) -> Void)?
    var onMonthChange: ((Set<Int>) -> Void)?

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var storeObserver: NSObjectProtocol?
    /// One query in flight at a time; CalDAV sync fires change notifications in bursts.
    private var refreshing = false

    /// How far ahead to look, and how many events to keep. Settings-backed.
    var lookaheadHours = 18
    var eventLimit = 4

    func start() {
        let handler: (Bool, Error?) -> Void = { [weak self] granted, error in
            Task { @MainActor in
                guard granted else {
                    Debug.log("calendar access denied: \(error?.localizedDescription ?? "no reason")")
                    return
                }
                self?.observe()
                self?.refresh()
            }
        }
        // `requestFullAccessToEvents` is macOS 14+; on 13 the old combined request is the only one.
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }

    /// Public status, for the permissions pane. Only Calendar has a clean pre-flight query — audio
    /// capture and the Downloads folder have none, and must be inferred from a failed call.
    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
    }

    private func observe() {
        guard storeObserver == nil else { return }
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        // Events fall out of the window as time passes even when nothing edits the calendar.
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh() {
        // EventKit's own header: "It is synchronous… you should run the query someplace other than
        // the main thread, and then funnel the array back." A shared CalDAV calendar makes the month
        // query take seconds, and it re-runs on every EKEventStoreChanged burst.
        guard !refreshing else { return }
        refreshing = true
        let now = Date()
        let store = store
        let lookahead = lookaheadHours
        let limit = eventLimit

        Task.detached(priority: .utility) { [weak self] in
            let result = Self.query(store: store, now: now, lookaheadHours: lookahead, limit: limit)
            guard let self else { return }
            await MainActor.run { self.applyRefresh(result) }
        }
    }

    private func applyRefresh(_ result: (events: [CalendarEvent], busyDays: Set<Int>)) {
        refreshing = false
        if result.events != events {
            events = result.events
            onChange?(result.events)
            Debug.log("calendar: \(result.events.count) upcoming")
        }
        guard result.busyDays != busyDays else { return }
        busyDays = result.busyDays
        onMonthChange?(result.busyDays)
    }

    /// Both queries in one off-actor pass. `EKEvent.startDate` is imported as `Date!` and really is
    /// nil for detached occurrences and some CalDAV/Exchange rows, so every read goes through
    /// `startDate as Date?` — force-unwrapping it crashed the whole app on one malformed event.
    private nonisolated static func query(
        store: EKEventStore,
        now: Date,
        lookaheadHours: Int,
        limit: Int
    ) -> (events: [CalendarEvent], busyDays: Set<Int>) {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .hour, value: lookaheadHours, to: now) else {
            return ([], [])
        }

        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let upcoming: [CalendarEvent] = store.events(matching: predicate)
            .compactMap { event -> (EKEvent, Date)? in
                guard let start = event.startDate as Date? else { return nil }
                return (event, start)
            }
            .filter { !$0.0.isAllDay || calendar.isDateInToday($0.1) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { event, start in
                CalendarEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "Untitled",
                    start: start,
                    isAllDay: event.isAllDay,
                    location: event.location,
                    url: event.url,
                    notes: event.notes,
                    tint: event.calendar?.cgColor
                )
            }

        var days: Set<Int> = []
        if let interval = calendar.dateInterval(of: .month, for: now) {
            let monthPredicate = store.predicateForEvents(
                withStart: interval.start, end: interval.end, calendars: nil
            )
            for event in store.events(matching: monthPredicate) {
                guard let start = event.startDate as Date? else { continue }
                days.insert(calendar.component(.day, from: start))
            }
        }
        return (upcoming, days)
    }
}
