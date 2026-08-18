import CoreGraphics
import Foundation

struct CalendarEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var isAllDay: Bool
    var location: String?
    /// `EKEvent.url`, and the notes field — where every conferencing tool actually puts its link.
    var url: URL?
    var notes: String?
    /// The calendar's own colour, so the agenda looks like the user's calendar.
    var tint: CGColor?

    var subtitle: String {
        if isAllDay { return "All day" }
        return start.formatted(date: .omitted, time: .shortened)
    }

    /// Minutes until it starts; negative once it has begun.
    var minutesAway: Int {
        Int(start.timeIntervalSinceNow / 60)
    }

    /// A joinable video call, if this event has one.
    ///
    /// EventKit exposes no "conference URL" field — Apple's own Calendar app scrapes for this too —
    /// so the honest implementation is to look where the tools put their links: the URL field first,
    /// then the location, then the notes.
    var meetingURL: URL? {
        if let url, Self.isMeetingLink(url) { return url }
        for text in [location, notes].compactMap({ $0 }) {
            if let found = Self.firstMeetingLink(in: text) { return found }
        }
        return nil
    }

    static func isMeetingLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            // Native schemes like zoommtg:// and msteams:// have no host.
            return ["zoommtg", "msteams", "webex", "facetime"].contains(url.scheme?.lowercased() ?? "")
        }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let meetingHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "around.co", "gather.town",
    ]

    static func firstMeetingLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url else { continue }
            if isMeetingLink(url) { return url }
        }
        return nil
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
