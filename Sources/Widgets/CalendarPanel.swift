import SwiftUI

/// Alcove's expanded calendar: big date on the left, month grid on the right.
///
/// Left column answers "what is today"; the grid answers "what's around it". The coral accent is
/// Alcove's own date colour rather than the system tint — dates read as calendar, not as buttons.
struct CalendarPanel: View {
    let events: [CalendarEvent]

    /// Alcove's coral date accent, sampled off the shipping app's screenshots.
    static let accent = Color(red: 1.0, green: 0.35, blue: 0.43)

    private var today: Date { Date() }

    private var weekdayName: String {
        today.formatted(.dateTime.weekday(.wide)).uppercased()
    }

    /// Next thing happening, phrased like Alcove's empty state.
    private var eventLine: (primary: String, secondary: String) {
        let upcoming = events.filter { $0.minutesAway >= 0 }.min { $0.start < $1.start }
        guard let next = upcoming else {
            return ("No events today", "Your day is clear")
        }
        return (next.title, countdown(next))
    }

    /// Sample data for the `debugDemoEvents` affordance in `AppDelegate.rebuildIslands`.
    static var demoEvents: [CalendarEvent] {
        let now = Date()
        return [
            CalendarEvent(id: "demo-1", title: "Design review", start: now.addingTimeInterval(42 * 60),
                          isAllDay: false, location: nil, url: nil, notes: nil),
            CalendarEvent(id: "demo-2", title: "1:1 with Umar", start: now.addingTimeInterval(3 * 3600),
                          isAllDay: false, location: nil, url: nil, notes: nil),
        ]
    }

    private func countdown(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let minutes = event.minutesAway
        if minutes < 1 { return "Now" }
        if minutes < 60 { return "in \(minutes) min" }
        return "in \(minutes / 60) h"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(weekdayName)
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(Self.accent)
                Text(today, format: .dateTime.day())
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 0) {
                    Text(eventLine.primary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Text(eventLine.secondary)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .padding(.top, 6)
            }

            Spacer(minLength: 0)

            MonthGrid(date: today, accent: Self.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact month view, weeks starting Monday like Alcove's grid.
struct MonthGrid: View {
    let date: Date
    let accent: Color

    private static let weekdays = ["M", "T", "W", "T", "F", "S", "S"]
    /// Sized so a six-week month fits the expanded card below the physical notch: the grid has
    /// ~96pt of room and six 10.5pt rows plus label and header spend all of it.
    private static let cellSize = CGSize(width: 17, height: 10.5)

    /// Day numbers laid out in rows of 7, `nil` padding the leading and trailing blanks.
    private var rows: [[Int?]] {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .month, for: date)!
        let daysInMonth = calendar.range(of: .day, in: .month, for: date)!.count
        // Monday-first offset: Swift's weekday 1 is Sunday.
        let leading = (calendar.component(.weekday, from: interval.start) + 5) % 7

        var flat: [Int?] = Array(repeating: nil, count: leading)
        flat.append(contentsOf: (1...daysInMonth).map { Optional($0) })
        while flat.count % 7 != 0 { flat.append(nil) }

        return stride(from: 0, to: flat.count, by: 7).map { Array(flat[$0..<min($0 + 7, flat.count)]) }
    }

    private func isToday(_ day: Int) -> Bool {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .day)
            && Calendar.current.component(.day, from: date) == day
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(date.formatted(.dateTime.month(.wide)).uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { index in
                    Text(Self.weekdays[index])
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: Self.cellSize.width, height: Self.cellSize.height)
                }
            }

            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 0) {
                    ForEach(rows[rowIndex].indices, id: \.self) { column in
                        cell(rows[rowIndex][column])
                    }
                }
            }
        }
    }

    private func cell(_ day: Int?) -> some View {
        ZStack {
            if let day {
                if isToday(day) {
                    Circle()
                        .fill(accent)
                        .frame(width: 13, height: 13)
                    Text(String(day))
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(.black)
                } else {
                    Text(String(day))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .frame(width: Self.cellSize.width, height: Self.cellSize.height)
    }
}
