import Foundation
import GRDB

/// Turns a `<ref>` into something to read, or into a row to write against — materialising a
/// `scheduled` meeting from a calendar event on the way if this is the first write to it.
public struct RefResolver: Sendable {
    let store: MeetingStore
    let calendar: any CalendarSource

    public init(store: MeetingStore, calendar: any CalendarSource = CalendarSources.resolved()) {
        self.store = store
        self.calendar = calendar
    }

    /// A uuid is its row. A `cal:` id is the row that already carries that calendar event if one
    /// exists — the row is the fuller answer, it has the notes on it — and otherwise the bare event,
    /// so `meetings show cal:…` prints an untouched calendar event rather than failing.
    public func resolveForRead(_ ref: MeetingRef) async throws -> ReadTarget {
        switch ref {
        case .id(let id):
            guard let meeting = try store.meeting(id: id) else { throw RefError.notFound(ref) }
            return .meeting(meeting)
        case .calendar(let eventID):
            if let meeting = try store.meeting(calendarEventID: eventID) {
                return .meeting(meeting)
            }
            guard let event = try await calendar.event(withIdentifier: eventID) else {
                throw RefError.notFound(ref)
            }
            return .event(event)
        }
    }

    /// Materialises a `cal:` ref into a real row before returning it: the agent never needs
    /// a separate create step, and `scheduled` rows still only exist for meetings you have touched.
    ///
    /// Idempotent, and not by checking first. Two processes — the app and a CLI write, or two CLI
    /// writes — can both find no row and both insert; what makes exactly one of them win is the
    /// unique index on `calendar_event_id`. The loser catches the constraint violation and reads
    /// back the row the winner made. A check-then-insert alone would race and give you two rows for
    /// one meeting, with your notes split across them.
    public func resolveForWrite(_ ref: MeetingRef) async throws -> Meeting {
        switch ref {
        case .id(let id):
            guard let meeting = try store.meeting(id: id) else { throw RefError.notFound(ref) }
            return meeting

        case .calendar(let eventID):
            if let existing = try store.meeting(calendarEventID: eventID) { return existing }
            guard let event = try await calendar.event(withIdentifier: eventID) else {
                throw RefError.notFound(ref)
            }

            let meeting = Meeting(
                title: event.title,
                state: .scheduled,
                // The id this was *asked* for, not the one the fetched event reports. They differ,
                // and the difference is a live bug rather than a hypothetical: EventKit gives each
                // occurrence of a recurring series its own identifier, while
                // `event(withIdentifier:)` hands back an event carrying the series identifier. So
                // the second occurrence looked itself up under the occurrence id, found nothing,
                // and inserted under the series id, which the first occurrence already owned. The
                // unique index refused it, the recovery below re-read under the occurrence id,
                // found nothing again, and rethrew: "UNIQUE constraint failed:
                // meetings.calendar_event_id" across the top of the window, every poll.
                //
                // Keying the row by the requested id is also what makes `cal:<ref>` resolve to the
                // row it created: an agent holding a ref must not be handed a row filed under a
                // different one.
                calendarEventID: eventID,
                scheduledStart: event.start,
                scheduledEnd: event.end,
                attendees: event.attendees
            )
            do {
                try store.createMeeting(meeting)
            } catch {
                // Whoever else got there first is the answer, and the question worth asking is
                // "is there a row now", not "was that the exact result code I predicted".
                //
                // This used to match `DatabaseError` with `resultCode == .SQLITE_CONSTRAINT`, which
                // is one GRDB detail away from surfacing a race as a failure: a unique violation
                // reported under its extended code, or an error wrapped on its way up, falls
                // through the pattern and the whole calendar read dies with "UNIQUE constraint
                // failed: meetings.calendar_event_id" in front of the user. The recovery does not
                // depend on the code, so neither should the catch.
                guard let winner = try store.meeting(calendarEventID: eventID) else { throw error }
                return winner
            }
            // Only the row that actually landed seeds. The vocabulary insert is idempotent anyway,
            // but there is no reason for the loser of the race to redo the winner's work.
            try AutoSeed.seed(attendees: event.attendees, folderID: meeting.folderID, into: store)
            return meeting
        }
    }

    /// Every candidate over threshold, scored and sorted. Never picks one — a CLI that guesses will
    /// eventually write your notes onto the wrong meeting.
    ///
    /// The window is symmetric: `days` back as well as forward, because "add notes to my call with
    /// Will" and "what did we decide last week" are the same lookup pointed in opposite directions.
    public func match(_ query: String, within days: Int = 14) async throws -> [MatchCandidate] {
        let now = Date()
        let span = TimeInterval(days) * 86_400
        let from = now.addingTimeInterval(-span), to = now.addingTimeInterval(span)

        // ponytail: every row, filtered in Swift. A personal store holds thousands of meetings, not
        // millions; when it doesn't, this becomes a WHERE clause on coalesce(started_at, scheduled_start).
        let meetings = try store.allMeetings()
        let materialised = Set(meetings.compactMap(\.calendarEventID))

        var candidates: [MatchCandidate] = []
        for meeting in meetings {
            // A row with no date at all is legal — an imported meeting whose date nobody knew — and
            // hiding it from every search because of that would be its own bug.
            if let date = meeting.sortDate, date < from || date > to { continue }
            let (score, matchedOn) = Match.score(query: query, fields: fields(for: meeting))
            guard score >= Match.threshold else { continue }
            candidates.append(MatchCandidate(
                ref: MeetingRef.id(meeting.id).description,
                title: meeting.title,
                start: meeting.sortDate,
                score: score,
                matchedOn: matchedOn.map(\.rawValue)
            ))
        }

        for event in try await calendar.events(from: from, to: to) {
            // The row won already: it is what a write would land on, and listing both would make
            // the agent ask the user to choose between a meeting and itself.
            if materialised.contains(event.id) { continue }
            let (score, matchedOn) = Match.score(query: query, fields: fields(for: event))
            guard score >= Match.threshold else { continue }
            candidates.append(MatchCandidate(
                ref: MeetingRef.calendar(event.id).description,
                title: event.title,
                start: event.start,
                score: score,
                matchedOn: matchedOn.map(\.rawValue)
            ))
        }

        // Score first; then the one nearest to now, since "my meeting with Will" almost always means
        // the next one or the last one rather than the one three weeks out. `ref` breaks the last tie
        // so the order is stable across runs.
        return candidates.sorted { left, right in
            if abs(left.score - right.score) > 0.0001 { return left.score > right.score }
            let leftGap = left.start.map { abs($0.timeIntervalSince(now)) } ?? .greatestFiniteMagnitude
            let rightGap = right.start.map { abs($0.timeIntervalSince(now)) } ?? .greatestFiniteMagnitude
            if leftGap != rightGap { return leftGap < rightGap }
            return left.ref < right.ref
        }
    }

    // MARK: -

    /// A row carries no calendar name — the event it came from might be long gone, and re-reading
    /// EventKit once per row to recover a field nobody searches by is not worth the call.
    private func fields(for meeting: Meeting) -> [(MatchField, String)] {
        [(.title, meeting.title)] + attendeeFields(meeting.attendees)
    }

    private func fields(for event: CalendarEvent) -> [(MatchField, String)] {
        [(.title, event.title)] + attendeeFields(event.attendees)
            + (event.calendarName.isEmpty ? [] : [(.calendar, event.calendarName)])
    }

    private func attendeeFields(_ attendees: [Attendee]) -> [(MatchField, String)] {
        attendees.flatMap { attendee -> [(MatchField, String)] in
            var fields: [(MatchField, String)] = []
            if let name = attendee.name, !name.isEmpty { fields.append((.attendee, name)) }
            if let email = attendee.email, !email.isEmpty {
                fields.append((.email, Match.emailLocalPart(email)))
            }
            return fields
        }
    }
}
