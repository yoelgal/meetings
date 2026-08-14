import Foundation

/// A calendar event as the rest of the app sees it. Deliberately not an `EKEvent` — the CLI resolves
/// `cal:` refs against this, the app renders Upcoming from it, and tests need to hand-write one.
public struct CalendarEvent: Codable, Hashable, Sendable, Identifiable {
    /// EventKit's `eventIdentifier`. This is what a `cal:` ref carries.
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var attendees: [Attendee]
    public var calendarName: String
    /// A meeting link found on the event — ``VideoLink/find(in:)`` knows the providers. Its presence
    /// is what makes the menu bar nudge fire and what puts the event in Upcoming at all
    /// (``isMeeting``), so it is resolved once here rather than re-sniffed at every call site.
    public var videoLink: URL?
    public var notes: String?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        attendees: [Attendee] = [],
        calendarName: String = "",
        videoLink: URL? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.calendarName = calendarName
        self.videoLink = videoLink
        self.notes = notes
    }
}

extension CalendarEvent {
    /// Whether this event belongs in a list of *meetings*. A calendar holds birthdays, all-day
    /// markers, focus blocks and travel, and a list that shows all of them is a second copy of
    /// Calendar rather than a list of things to record.
    ///
    /// The whole test is: does it have a meeting link. Attendee counts, all-day flags and title
    /// keywords were all considered and rejected — each of them guesses, and a guess here hides a
    /// real meeting. Both front ends read this one property so the app's Upcoming and
    /// `meetings upcoming` can never disagree about what a meeting is.
    ///
    /// This filters *lists* only. `event(withIdentifier:)` never applies it: an agent may attach
    /// pre-notes to any event by `cal:` ref, including one that has no link at all.
    public var isMeeting: Bool { videoLink != nil }
}

public enum CalendarAuthorization: String, Sendable {
    case notDetermined, denied, restricted, authorized
}

public protocol CalendarSource: Sendable {
    func authorizationStatus() -> CalendarAuthorization
    /// Never prompts. Returns `[]` when access has not been granted — an unavailable calendar is a
    /// degraded app, not a failed one.
    func events(from: Date, to: Date) async throws -> [CalendarEvent]
    func event(withIdentifier id: String) async throws -> CalendarEvent?
}

public enum CalendarSources {
    /// The source this process should use: EventKit normally, a JSON fixture when
    /// `$MEETINGS_CALENDAR_FIXTURE` points at one. The fixture exists so acceptance runs can
    /// exercise `cal:` refs without reading anybody's real calendar.
    public static func resolved() -> any CalendarSource {
        if let url = Paths.calendarFixtureURL {
            return FixtureCalendarSource(url: url)
        }
        return EventKitCalendarSource()
    }
}

/// Reads events from a JSON array on disk. The file is the same shape `CalendarEvent` encodes to,
/// with ISO-8601 dates, so a fixture is hand-writable.
public struct FixtureCalendarSource: CalendarSource {
    private let url: URL

    public init(url: URL) { self.url = url }

    public func authorizationStatus() -> CalendarAuthorization { .authorized }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        try load().filter { $0.start < to && $0.end > from }.sorted { $0.start < $1.start }
    }

    public func event(withIdentifier id: String) async throws -> CalendarEvent? {
        try load().first { $0.id == id }
    }

    private func load() throws -> [CalendarEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CalendarEvent].self, from: Data(contentsOf: url))
    }
}
