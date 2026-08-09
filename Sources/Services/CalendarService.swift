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

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard granted else {
                    Debug.log("calendar access denied: \(error?.localizedDescription ?? "no reason")")
                    return
                }
                self?.observe()
                self?.refresh()
            }
        }
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
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .hour, value: 18, to: now) else { return }

        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { !$0.isAllDay || Calendar.current.isDateInToday($0.startDate) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(4)
            .map {
                CalendarEvent(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: $0.title ?? "Untitled",
                    start: $0.startDate,
                    isAllDay: $0.isAllDay,
                    location: $0.location
                )
            }

        let next = Array(found)
        if next != events {
            events = next
            onChange?(next)
            Debug.log("calendar: \(next.count) upcoming")
        }
        refreshMonth(around: now)
    }

    /// Which days of the visible month have something on them, for the mini month grid.
    private func refreshMonth(around date: Date) {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return }

        let predicate = store.predicateForEvents(
            withStart: interval.start, end: interval.end, calendars: nil
        )
        var days: Set<Int> = []
        for event in store.events(matching: predicate) {
            days.insert(calendar.component(.day, from: event.startDate))
        }
        guard days != busyDays else { return }
        busyDays = days
        onMonthChange?(days)
    }
}
