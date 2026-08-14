import Foundation
import Testing

@testable import MeetingsCore

/// A calendar the test can edit between syncs, which is the whole point: retiming, renaming and
/// cancelling are what a second pass has to survive, and a JSON fixture on disk cannot change its
/// mind halfway through a test.
final class StubCalendar: CalendarSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CalendarEvent]

    init(_ events: [CalendarEvent]) { stored = events }

    var events: [CalendarEvent] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func authorizationStatus() -> CalendarAuthorization { .authorized }

    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        events.filter { $0.start < to && $0.end > from }.sorted { $0.start < $1.start }
    }

    func event(withIdentifier id: String) async throws -> CalendarEvent? {
        events.first { $0.id == id }
    }
}

@Suite final class CalendarSyncTests {
    let directory: URL
    let store: MeetingStore

    /// Whole seconds, because the date columns are whole seconds. A fractional start would make the
    /// no-op check below fail for a reason that has nothing to do with what is being tested.
    static let now = Date(timeIntervalSince1970: 1_770_000_000)

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    static func event(
        _ id: String,
        title: String = "Torch0 weekly",
        inDays days: Double,
        link: URL? = URL(string: "https://torch0.zoom.us/j/91120044837"),
        attendees: [Attendee] = [Attendee(name: "Will Hastings", email: "will@torch0.dev")]
    ) -> CalendarEvent {
        let start = now.addingTimeInterval(days * 86_400)
        return CalendarEvent(
            id: id,
            title: title,
            start: start,
            end: start.addingTimeInterval(1800),
            attendees: attendees,
            calendarName: "Work",
            videoLink: link
        )
    }

    func sync(_ calendar: StubCalendar, days: Int? = nil) async throws {
        try await CalendarSync(store: store, calendar: calendar).run(now: Self.now, days: days)
    }

    // MARK: - A row from the moment the event appears

    @Test func aCalendarMeetingGetsARowWithNobodyHavingWrittenAnything() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2)])
        try await sync(calendar)

        let meeting = try #require(try store.meeting(calendarEventID: "EV-1"))
        #expect(meeting.state == .scheduled)
        #expect(meeting.title == "Torch0 weekly")
        #expect(meeting.scheduledStart == Self.now.addingTimeInterval(2 * 86_400))
        #expect(meeting.attendees.first?.email == "will@torch0.dev")
    }

    /// The look-ahead window runs again every time Upcoming refreshes, so "twice" is the ordinary
    /// case, not an edge one. The partial unique index is what makes the second insert lose.
    @Test func twoSyncsOverTheSameEventLeaveExactlyOneRow() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2)])
        try await sync(calendar)
        try await sync(calendar)

        let rows = try store.allMeetings().filter { $0.calendarEventID == "EV-1" }
        #expect(rows.count == 1)
    }

    /// The failure this guards is a write loop, not a wasted query. The window hears its own writes
    /// as a `StoreChange` and answers each one with another refresh, so a sync that "updates" an
    /// unchanged row — because a date came back a fraction of a second off — never settles.
    @Test func aSecondSyncOverAnUnchangedCalendarWritesNothing() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2), Self.event("EV-2", inDays: 3)])
        try await sync(calendar)

        let posts = Counter()
        let observation = StoreChange.observe(storePath: store.dbPool.path) { _ in posts.bump() }
        try await sync(calendar)
        _ = observation

        #expect(posts.value == 0)
    }

    @Test func anEventWithNoMeetingLinkNeverGetsARow() async throws {
        let calendar = StubCalendar([
            Self.event("EV-birthday", title: "Priya's birthday", inDays: 1, link: nil),
            Self.event("EV-call", inDays: 2),
        ])
        try await sync(calendar)

        #expect(try store.meeting(calendarEventID: "EV-birthday") == nil)
        #expect(try store.meeting(calendarEventID: "EV-call") != nil)
    }

    @Test func anEventBeyondTheWindowGetsNoRowUntilTheWindowReachesIt() async throws {
        let calendar = StubCalendar([Self.event("EV-far", inDays: 9)])
        try await sync(calendar, days: 7)
        #expect(try store.meeting(calendarEventID: "EV-far") == nil)

        try await sync(calendar, days: 14)
        #expect(try store.meeting(calendarEventID: "EV-far") != nil)
    }

    // MARK: - What a second pass may and may not touch

    @Test func aRetimedEventMovesItsRow() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2)])
        try await sync(calendar)

        calendar.events = [Self.event("EV-1", title: "Torch0 weekly, moved", inDays: 2.5)]
        try await sync(calendar)

        let meeting = try #require(try store.meeting(calendarEventID: "EV-1"))
        #expect(meeting.title == "Torch0 weekly, moved")
        #expect(meeting.scheduledStart == Self.now.addingTimeInterval(2.5 * 86_400))
    }

    /// The one rule that must never bend: calendar data flows onto the row, the user's own writing
    /// never flows off it. Somebody who wrote an agenda and then had the meeting moved keeps the
    /// agenda.
    @Test func theUsersPreNotesSurviveARetimeAndARename() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2)])
        try await sync(calendar)
        let id = try #require(try store.meeting(calendarEventID: "EV-1")).id
        try store.updateMeeting(id: id) { $0.preNotes = "- push back on the March timeline" }

        calendar.events = [Self.event("EV-1", title: "Torch0 weekly, moved", inDays: 4)]
        try await sync(calendar)

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.preNotes == "- push back on the March timeline")
        #expect(meeting.title == "Torch0 weekly, moved")
        #expect(meeting.scheduledStart == Self.now.addingTimeInterval(4 * 86_400))
    }

    /// Once a meeting has been recorded its times are history. A calendar series edited afterwards
    /// must not rewrite when the recording actually happened.
    @Test func aMeetingThatIsNoLongerScheduledIsNotRewrittenByTheCalendar() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2)])
        try await sync(calendar)
        let id = try #require(try store.meeting(calendarEventID: "EV-1")).id
        try store.updateMeeting(id: id) { meeting in
            meeting.state = .ready
            meeting.summary = "We agreed to ship on the 14th."
        }

        calendar.events = [Self.event("EV-1", title: "Renamed after the fact", inDays: 2)]
        try await sync(calendar)

        let meeting = try #require(try store.meeting(id: id))
        #expect(meeting.title == "Torch0 weekly")
        #expect(meeting.summary == "We agreed to ship on the 14th.")
    }

    /// A cancelled event leaves its row alone. `events(from:to:)` returns `[]` for a calendar that
    /// is merely unauthorised, which is indistinguishable from "everything was cancelled" — deleting
    /// on that reading would take the user's whole prepared week with it.
    @Test func anEventThatVanishesFromTheCalendarLeavesItsRowBehind() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2)])
        try await sync(calendar)

        calendar.events = []
        try await sync(calendar)

        #expect(try store.meeting(calendarEventID: "EV-1") != nil)
    }

    // MARK: - Deleting one keeps it deleted

    @Test func aDeletedRowIsNotMadeAgainByTheNextSync() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2)])
        try await sync(calendar)
        let id = try #require(try store.meeting(calendarEventID: "EV-1")).id
        #expect(try store.deleteMeeting(id: id, audioRoot: directory))

        try await sync(calendar)
        #expect(try store.meeting(calendarEventID: "EV-1") == nil)
    }

    /// Dismissal is per event. Deleting one meeting must not silence the rest of the week.
    @Test func deletingOneRowDoesNotStopTheOthersBeingMade() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2), Self.event("EV-2", inDays: 3)])
        try await sync(calendar)
        let id = try #require(try store.meeting(calendarEventID: "EV-1")).id
        #expect(try store.deleteMeeting(id: id, audioRoot: directory))

        try await sync(calendar)
        #expect(try store.meeting(calendarEventID: "EV-1") == nil)
        #expect(try store.meeting(calendarEventID: "EV-2") != nil)
    }

    /// The tombstone is not forever. Once the event has ended it can no longer be in anybody's
    /// look-ahead window, so the row is pruned rather than kept for the life of the store.
    @Test func aDismissalIsPrunedOnceItsEventHasEnded() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2)])
        try await sync(calendar)
        let id = try #require(try store.meeting(calendarEventID: "EV-1")).id
        #expect(try store.deleteMeeting(id: id, audioRoot: directory))
        #expect(try store.dismissedCalendarEvents(now: Self.now) == ["EV-1"])

        #expect(try store.dismissedCalendarEvents(now: Self.now.addingTimeInterval(3 * 86_400)).isEmpty)
    }

    /// Recording the meeting from the nudge is asking for the row back, and goes through the
    /// resolver rather than the sync. A dismissal must not stand in the way of that.
    @Test func anExplicitWriteAgainstTheRefStillMakesTheRow() async throws {
        let calendar = StubCalendar([Self.event("EV-1", inDays: 2)])
        try await sync(calendar)
        let id = try #require(try store.meeting(calendarEventID: "EV-1")).id
        #expect(try store.deleteMeeting(id: id, audioRoot: directory))

        let resolver = RefResolver(store: store, calendar: calendar)
        let meeting = try await resolver.resolveForWrite(.calendar("EV-1"))
        #expect(meeting.title == "Torch0 weekly")
    }

    // MARK: - The look-ahead setting

    @Test func theLookAheadDefaultsToSevenDays() throws {
        #expect(CalendarSync.lookAheadDays(in: store) == 7)
    }

    @Test func theLookAheadSettingDecidesTheWindow() async throws {
        try store.setSetting(.calendarLookAheadDays, "14")
        #expect(CalendarSync.lookAheadDays(in: store) == 14)

        let calendar = StubCalendar([Self.event("EV-near", inDays: 2), Self.event("EV-far", inDays: 9)])
        try await sync(calendar)

        #expect(try store.meeting(calendarEventID: "EV-near") != nil)
        #expect(try store.meeting(calendarEventID: "EV-far") != nil)
    }

    /// A window of nothing is an Upcoming list that is empty for a reason no surface explains, and a
    /// value that is not a number at all reads as nil. Both floor at a day rather than at zero.
    @Test func anUnusableLookAheadFallsBackRatherThanEmptyingTheList() throws {
        try store.setSetting(.calendarLookAheadDays, "0")
        #expect(CalendarSync.lookAheadDays(in: store) == 1)

        try store.setSetting(.calendarLookAheadDays, "a fortnight")
        #expect(CalendarSync.lookAheadDays(in: store) == 7)
    }
}

/// Counts notifications across whatever thread posts them.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// EventKit gives each occurrence of a recurring series its own identifier when it lists them, and
/// then hands back an event carrying the *series* identifier when you look one of those ids up.
/// `resolveForWrite` used the looked-up event's id when writing the row while reading by the id it
/// was asked for, so the second occurrence found nothing under its own id, inserted under the
/// series id the first occurrence already owned, and the unique index refused it. The recovery read
/// back under the occurrence id, found nothing again, and rethrew: the whole calendar read died
/// with "UNIQUE constraint failed: meetings.calendar_event_id", every poll, in front of the user.
final class SeriesEchoingCalendar: CalendarSource, @unchecked Sendable {
    let occurrences: [CalendarEvent]
    let seriesID: String

    init(occurrences: [CalendarEvent], seriesID: String) {
        self.occurrences = occurrences
        self.seriesID = seriesID
    }

    func authorizationStatus() -> CalendarAuthorization { .authorized }

    func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        occurrences.filter { $0.start < to && $0.end > from }
    }

    /// The lookup answers with the series, whatever occurrence you asked about. This is the
    /// behaviour that broke it, reproduced exactly.
    func event(withIdentifier id: String) async throws -> CalendarEvent? {
        guard let match = occurrences.first(where: { $0.id == id }) else { return nil }
        return CalendarEvent(
            id: seriesID,
            title: match.title,
            start: match.start,
            end: match.end,
            attendees: match.attendees,
            calendarName: match.calendarName,
            videoLink: match.videoLink
        )
    }
}

@Suite struct RecurringSeriesSyncTests {
    @Test("each occurrence of a series gets its own row, and syncing twice throws nothing")
    func occurrencesDoNotCollideOnTheSeriesIdentifier() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let store = try TestStore.open(directory)

        let series = "9F0A1B2C-SERIES"
        let calendar = SeriesEchoingCalendar(
            occurrences: [
                CalendarSyncTests.event("\(series)/RID=1", inDays: 1),
                CalendarSyncTests.event("\(series)/RID=2", inDays: 2),
            ],
            seriesID: series
        )
        let sync = CalendarSync(store: store, calendar: calendar)

        try await sync.run(now: CalendarSyncTests.now, days: 7)
        try await sync.run(now: CalendarSyncTests.now, days: 7)

        let rows = try store.meetings(state: .scheduled)
        #expect(rows.count == 2, "one row per occurrence, and no duplicates from the second sync")
        #expect(Set(rows.compactMap(\.calendarEventID))
            == ["\(series)/RID=1", "\(series)/RID=2"],
            "each row is filed under the id it will be looked up by, so `cal:` refs resolve")
    }
}
