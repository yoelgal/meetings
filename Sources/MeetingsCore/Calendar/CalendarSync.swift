import Foundation

/// Gives every calendar meeting in the look-ahead window a store row, from the moment it appears.
///
/// Before this, a calendar event had no row until something wrote one, so preparing for a meeting
/// meant a "materialise" step the user had to know about — and the window's Upcoming list showed a
/// second kind of row that could not be filed, renamed, or noted against. Now the row is the only
/// kind of thing in the list.
///
/// Three rules hold it together, and each one exists because the alternative is a real failure:
///
/// 1. **Only ``CalendarEvent/isMeeting`` events.** The same filter Upcoming lists by. Without it the
///    store fills with rows for birthdays, travel and blocked-out time.
/// 2. **Calendar data flows one way.** The sync writes the fields the calendar owns — title, times,
///    attendees — and never touches pre-notes, the summary, actions, or the folder. A meeting the
///    user prepared for and then had retimed keeps everything they wrote.
/// 3. **A deleted row stays deleted.** ``MeetingStore/deleteMeeting(id:audioRoot:)`` leaves a
///    tombstone, and this skips those events. Otherwise deleting a synced meeting would put it back
///    on the next pass, seconds later.
///
/// It never deletes a row of its own accord, including for an event that has vanished from the
/// calendar. ``CalendarSource/events(from:to:)`` returns `[]` for a calendar that is merely
/// unauthorised or unreadable, which is indistinguishable from "every meeting was cancelled" — and
/// on that reading the sync would delete the user's whole week. A cancelled meeting simply stays a
/// `scheduled` row and ages out of the window on its own.
public struct CalendarSync: Sendable {
    let store: MeetingStore
    let calendar: any CalendarSource

    public init(store: MeetingStore, calendar: any CalendarSource) {
        self.store = store
        self.calendar = calendar
    }

    /// How far ahead to look, from `calendar.lookAheadDays`. Both front ends come through
    /// here so the window and `meetings upcoming` cannot land on different horizons.
    ///
    /// Floored at one day. A stored `0` — or a value that is not a number at all — would otherwise
    /// mean an Upcoming list that is empty for a reason nothing on screen explains.
    public static func lookAheadDays(in store: MeetingStore) -> Int {
        let stored = (try? store.settingInt(.calendarLookAheadDays)) ?? nil
        return max(1, stored ?? 7)
    }

    /// Returns the events the window covers, which is what a caller needs to show a Join link beside
    /// a row: the meeting row carries no video link, and re-reading the calendar for one would be a
    /// second trip for something this pass already has in hand.
    @discardableResult
    public func run(now: Date = Date(), days: Int? = nil) async throws -> [CalendarEvent] {
        let days = days ?? Self.lookAheadDays(in: store)
        let horizon = now.addingTimeInterval(Double(days) * 86_400)
        let events = try await calendar.events(from: now, to: horizon).filter(\.isMeeting)
        let dismissed = try store.dismissedCalendarEvents(now: now)

        for event in events where !dismissed.contains(event.id) {
            do {
                // The resolver's own path, not a second one beside it. Two syncs, or a sync racing a
                // `cal:` write from an agent, both land on one row: `resolveForWrite` inserts and
                // lets the partial unique index on `calendar_event_id` decide the winner, then reads
                // the winner back. A check-then-insert here would race it and split the user's notes
                // across two rows for the same meeting.
                let meeting = try await RefResolver(store: store, calendar: calendar)
                    .resolveForWrite(.calendar(event.id))
                try apply(event, to: meeting)
            } catch is RefError {
                // The event went away between listing it and looking it up. Nothing to make a row
                // from, and the rest of the window is still worth syncing.
                continue
            }
        }
        return events
    }

    /// The calendar's own fields onto a row that is still waiting to happen.
    ///
    /// Only `scheduled`: once a meeting has been recorded its times are history, and a calendar
    /// series edited afterwards must not rewrite when the recording actually happened. Imported rows
    /// are somebody else's copy and are never rewritten either.
    ///
    /// The title is calendar-owned here because the window only offers rename once a meeting is
    /// written up — there is no way to rename a `scheduled` row, so there is no rename to lose.
    private func apply(_ event: CalendarEvent, to meeting: Meeting) throws {
        guard meeting.state == .scheduled, meeting.importedFrom == nil else { return }

        // Compared against what the *store* would hold, not against the raw event: the write surface
        // strips NULs and the date columns are whole seconds, so a fractional event start compares
        // unequal to its own stored copy forever. Every "difference" is a write, the window hears
        // its own write as a store change, and it syncs again — a loop that never settles.
        let title = event.title.withoutNULs
        let attendees = event.attendees.map {
            Attendee(name: $0.name?.withoutNULs, email: $0.email?.withoutNULs)
        }
        guard meeting.title != title
            || !Self.sameSecond(meeting.scheduledStart, event.start)
            || !Self.sameSecond(meeting.scheduledEnd, event.end)
            || meeting.attendees != attendees
        else { return }

        try store.updateMeeting(id: meeting.id) { row in
            row.title = title
            row.scheduledStart = event.start
            row.scheduledEnd = event.end
            row.attendees = attendees
        }
    }

    private static func sameSecond(_ stored: Date?, _ incoming: Date) -> Bool {
        guard let stored else { return false }
        return Int(stored.timeIntervalSince1970) == Int(incoming.timeIntervalSince1970)
    }
}
