import Foundation

struct CalendarEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var isAllDay: Bool
    var location: String?

    var subtitle: String {
        if isAllDay { return "All day" }
        return start.formatted(date: .omitted, time: .shortened)
    }

    /// Minutes until it starts; negative once it has begun.
    var minutesAway: Int {
        Int(start.timeIntervalSinceNow / 60)
    }
}

enum MediaCommand {
    case play
    case pause
    case togglePlayPause
    case next
    case previous

    /// MediaRemote's numeric command codes.
    var rawCommand: UInt32 {
        switch self {
        case .play: return 0
        case .pause: return 1
        case .togglePlayPause: return 2
        case .next: return 4
        case .previous: return 5
        }
    }
}
