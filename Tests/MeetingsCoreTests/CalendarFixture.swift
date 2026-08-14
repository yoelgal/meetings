import Foundation
import Testing

@testable import MeetingsCore

/// A believable fortnight of calendar events, written to disk as the JSON `FixtureCalendarSource`
/// reads. This is how `cal:` refs get exercised without anyone's real calendar being opened —
/// EventKit access is deliberately never requested by the tests.
///
/// Dates are anchored to `now` rather than written as literals so the suite does not quietly stop
/// covering the ±14-day match window a fortnight after it was written.
enum CalFixture {
    /// One anchor for the whole run, so two tests never disagree about what "tomorrow" is.
    static let now = Date()

    static func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: now.addingTimeInterval(TimeInterval(day) * 86_400))
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
    }

    // Attendees recur across events on purpose: the fuzzy matcher has to cope with the same three
    // people being on half the fortnight.
    static let will = Attendee(name: "Will Hastings", email: "will.hastings@torch0.dev")
    static let sofia = Attendee(name: "Sofia Nunes", email: "sofia.nunes@torch0.dev")
    static let ravi = Attendee(name: "Ravi Chandrasekaran", email: "ravi@torch0.dev")
    static let daniela = Attendee(name: "Daniela Okonkwo", email: "daniela.okonkwo@mater.ai")
    /// No display name at all — EventKit hands these out constantly, and the surname has to come
    /// from the address or not at all.
    static let lars = Attendee(email: "lars.jensen@mater.ai")
    static let klaus = Attendee(name: "Klaus Bergmann", email: "k.bergmann@airbus.com")
    /// Both tokens under four characters: nothing here is safe to seed.
    static let bo = Attendee(name: "Bo Li", email: "bo.li@airbus.com")
    static let tal = Attendee(name: "Tal Ma'agan", email: "tal.maagan@torch0.dev")
    /// A surname that is an ordinary English word. The full name is seedable, "Green" is not.
    static let daniel = Attendee(name: "Daniel Green", email: "daniel.green@torch0.dev")

    static let events: [CalendarEvent] = [
        CalendarEvent(
            id: "8F2C1A44-STANDUP-0912",
            title: "Torch0 standup",
            start: at(day: -2, hour: 9, minute: 15),
            end: at(day: -2, hour: 9, minute: 30),
            attendees: [will, sofia, ravi],
            calendarName: "Work",
            videoLink: URL(string: "https://torch0.zoom.us/j/98213347761"),
            notes: "Daily. Join Zoom Meeting https://torch0.zoom.us/j/98213347761"
        ),
        CalendarEvent(
            id: "C41D9B02-WEEKLY-1000",
            title: "Torch0 weekly",
            start: at(day: 1, hour: 10),
            end: at(day: 1, hour: 10, minute: 30),
            attendees: [will, sofia, ravi],
            calendarName: "Work",
            videoLink: URL(string: "https://torch0.zoom.us/j/91120044837"),
            notes: "Agenda in the shared doc. https://torch0.zoom.us/j/91120044837"
        ),
        CalendarEvent(
            id: "6A70E5D8-MATER-1400",
            title: "Mater-AI intro",
            start: at(day: 2, hour: 14),
            end: at(day: 2, hour: 14, minute: 45),
            attendees: [sofia, daniela, lars],
            calendarName: "Work",
            videoLink: URL(string: "https://meet.google.com/qvx-mhtd-yzr"),
            notes: "First call with the Mater-AI team. https://meet.google.com/qvx-mhtd-yzr"
        ),
        CalendarEvent(
            id: "1B93F7CE-ONEONE-1600",
            title: "1:1 Sofia",
            start: at(day: 3, hour: 16),
            end: at(day: 3, hour: 16, minute: 30),
            attendees: [sofia],
            calendarName: "Work",
            videoLink: URL(string: "https://torch0.zoom.us/j/93318820045"),
            notes: nil
        ),
        CalendarEvent(
            id: "D0E4A116-AIRBUS-0930",
            title: "Ptychography review with Airbus",
            start: at(day: 4, hour: 9, minute: 30),
            end: at(day: 4, hour: 10, minute: 30),
            attendees: [klaus, ravi, bo],
            calendarName: "Work",
            videoLink: nil,
            notes: "In person, Filton building 07. Bring the calibration plots."
        ),
        CalendarEvent(
            id: "7E58C3AB-WEEKLYSYNC-1000",
            title: "Torch0 weekly sync",
            start: at(day: 8, hour: 10),
            end: at(day: 8, hour: 11),
            attendees: [will, sofia],
            calendarName: "Work",
            videoLink: URL(string: "https://torch0.zoom.us/j/91120044837"),
            notes: "Longer session, we skip the standup that week."
        ),
        CalendarEvent(
            id: "35FA6D9C-MAAGAN-0800",
            title: "Ma'agan Michael site visit",
            start: at(day: 9, hour: 8),
            end: at(day: 9, hour: 11),
            attendees: [tal, ravi],
            calendarName: "Personal",
            videoLink: nil,
            notes: "Drive up the night before."
        ),
        CalendarEvent(
            id: "A2C7B450-BOARD-1100",
            title: "Board catch-up",
            start: at(day: 12, hour: 11),
            end: at(day: 12, hour: 12),
            attendees: [daniel, will],
            calendarName: "Work",
            videoLink: URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmU0"),
            notes: "Quarterly numbers. https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmU0"
        ),
    ]

    /// Written once per test run, to `$MEETINGS_CALENDAR_FIXTURE` when the run set one — that is how
    /// the acceptance run gets a fixture on disk to point the CLI at — and to a temp file otherwise,
    /// so `swift test` with no environment still covers every calendar path.
    static let url: URL = {
        let url = Paths.calendarFixtureURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meetings-cal-fixture-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try! encoder.encode(events).write(to: url)
        return url
    }()

    static func source() -> FixtureCalendarSource { FixtureCalendarSource(url: url) }

    static func event(_ id: String) -> CalendarEvent { events.first { $0.id == id }! }
}

/// A fixture source that runs a closure while the event is being fetched.
///
/// `resolveForWrite` checks for an existing row, then fetches the event, then inserts — so this is
/// the seam that makes "another process inserted the row while we were looking the event up" a
/// deterministic test rather than a hopeful one.
struct InterposingCalendarSource: CalendarSource {
    let inner: FixtureCalendarSource
    let interpose: @Sendable () throws -> Void

    init(inner: FixtureCalendarSource, _ interpose: @escaping @Sendable () throws -> Void) {
        self.inner = inner
        self.interpose = interpose
    }

    func authorizationStatus() -> CalendarAuthorization { inner.authorizationStatus() }

    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        try await inner.events(from: from, to: to)
    }

    func event(withIdentifier id: String) async throws -> CalendarEvent? {
        let event = try await inner.event(withIdentifier: id)
        if event != nil { try interpose() }
        return event
    }
}

/// Releases every participant at the same instant, so "concurrent" in a test means concurrent
/// rather than "the first task happened to finish before the second started".
actor Gate {
    private let count: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { self.count = count }

    func arrive() async {
        if waiting.count + 1 >= count {
            let waiting = self.waiting
            self.waiting = []
            for continuation in waiting { continuation.resume() }
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }
}
