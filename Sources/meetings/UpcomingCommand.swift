import ArgumentParser
import Foundation
import MeetingsCore

/// Calendar events and scheduled meetings in one list, each carrying the ref you write against —
/// `cal:<eventIdentifier>` while an event has no row, the meeting id once it has one. The agent
/// never has to know which it is holding.
struct UpcomingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upcoming",
        abstract: "What is coming up, from the calendar and from the store.",
        discussion: """
            --match scores every candidate against title, attendee names, attendee emails and \
            calendar name, and returns all of them with their score. It never picks one. \
            Disambiguation is the agent's job.
            """
    )

    @Option(name: .long, help: "How far ahead to look, in days. Defaults to the calendar.lookAheadDays setting.")
    var days: Int?

    @Option(name: .long, help: "Score candidates against this text instead of listing everything.")
    var match: String?

    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard days.map({ $0 > 0 }) ?? true else {
            throw ValidationError("--days takes a number greater than zero.")
        }
    }

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            // The flag overrides the setting for this one invocation rather than writing it: an
            // agent asking "what's on this fortnight" must not quietly change what the window shows.
            let days = self.days ?? CalendarSync.lookAheadDays(in: context.store)

            if let match {
                // The resolver's window is symmetric on purpose — "what did we decide last week" is
                // the same lookup pointed backwards. This command is not that: it is named for what
                // has not happened yet, and the list below it filters to `start >= now` too. So drop
                // the past here rather than narrowing the resolver for every caller, and say how many
                // went, because silently hiding the meeting somebody asked for is the worse failure.
                let now = Date()
                let all = try await context.resolver.match(match, within: days)
                let candidates = all.filter { ($0.start ?? .distantPast) >= now }
                let dropped = all.filter { ($0.start ?? .distantPast) < now }
                let hidden = dropped.count
                // The disambiguation rule the skill states is "list title, date and attendees for
                // each", so the candidates carry attendees. Without them every ambiguous match cost
                // an extra `show` per candidate just to ask the one question the CLI insists on.
                let described = try await withAttendees(candidates, context: context)
                if global.json {
                    // The dropped candidates ride along rather than being counted and discarded.
                    // An agent asked "add notes to my call with Will" whose only Will was this
                    // morning would otherwise see an empty list and tell the user there is no such
                    // meeting — the CLI knowing better and not saying so is the worse failure.
                    try Out.json(MatchJSON(
                        query: match,
                        candidates: described,
                        hidden: try await withAttendees(dropped, context: context)
                    ))
                    return
                }
                if hidden > 0 {
                    Out.note(
                        "\(hidden) earlier match\(hidden == 1 ? "" : "es") hidden. Upcoming lists "
                            + "only what has not started. Use meetings search for past meetings."
                    )
                }
                guard !candidates.isEmpty else {
                    Out.note("Nothing scored above the threshold for \(match).")
                    return
                }
                Out.line(Format.columns(described.map { candidate in
                    [
                        String(format: "%.2f", candidate.score),
                        candidate.ref,
                        Format.when(candidate.start),
                        candidate.matchedOn.joined(separator: "+"),
                        Format.oneLine(candidate.title),
                        Format.attendees(candidate.attendees),
                    ]
                }).joined(separator: "\n"))
                return
            }

            let now = Date()
            let horizon = now.addingTimeInterval(Double(days) * 86_400)
            // Meetings, not the whole calendar — the same `isMeeting` the app's Upcoming filters on,
            // so an agent reading this list sees exactly what the user sees. Ad-hoc scheduled
            // meetings below are not calendar events and are not filtered.
            let events = try await context.calendar.events(from: now, to: horizon)
                .filter(\.isMeeting)
            let names = try context.folderNames()

            var entries: [UpcomingJSON] = []
            var coveredMeetingIDs: Set<String> = []
            for event in events {
                if let meeting = try context.store.meeting(calendarEventID: event.id) {
                    coveredMeetingIDs.insert(meeting.id)
                    entries.append(UpcomingJSON(
                        event: event,
                        meeting: meeting,
                        folder: meeting.folderID.flatMap { names[$0] }
                    ))
                } else {
                    entries.append(UpcomingJSON(event: event))
                }
            }

            // Ad-hoc scheduled meetings — created in the app, not from an invitation — are upcoming
            // too, and an agent asked "what's on tomorrow" that missed them would be wrong.
            for meeting in try context.store.meetings(state: .scheduled) {
                guard !coveredMeetingIDs.contains(meeting.id), let start = meeting.scheduledStart else { continue }
                guard start >= now, start <= horizon else { continue }
                entries.append(UpcomingJSON(meeting: meeting, folder: meeting.folderID.flatMap { names[$0] }))
            }
            entries.sort { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }

            if global.json {
                try Out.json(UpcomingListJSON(days: days, upcoming: entries))
                return
            }

            guard !entries.isEmpty else {
                Out.note("Nothing in the next \(days) day\(days == 1 ? "" : "s").")
                return
            }

            Out.line(Format.columns(entries.map { entry in
                [
                    entry.ref,
                    Format.when(entry.start),
                    Format.duration(ms: entry.durationMs),
                    entry.state ?? "calendar",
                    Format.oneLine(entry.title),
                ]
            }).joined(separator: "\n"))
        }
    }

    /// A read per candidate, which is cheap because `--match` returns a handful and never a page.
    /// A candidate whose ref will not resolve keeps its empty attendee list rather than failing the
    /// whole listing — the score and the title are still the answer to the question that was asked.
    private func withAttendees(
        _ candidates: [MatchCandidate],
        context: CLIContext
    ) async throws -> [CandidateJSON] {
        var described: [CandidateJSON] = []
        for candidate in candidates {
            let attendees: [Attendee]
            switch try? await context.readTarget(candidate.ref) {
            case .event(let event): attendees = event.attendees
            case .meeting(let meeting): attendees = meeting.attendees
            case nil: attendees = []
            }
            described.append(CandidateJSON(candidate, attendees: attendees))
        }
        return described
    }
}

/// One scored candidate, plus the attendees the disambiguation question has to name.
struct CandidateJSON: Encodable {
    let ref: String
    let title: String
    let start: Date?
    let score: Double
    let matchedOn: [String]
    let attendees: [Attendee]

    init(_ candidate: MatchCandidate, attendees: [Attendee]) {
        self.ref = candidate.ref
        self.title = candidate.title
        self.start = candidate.start
        self.score = candidate.score
        self.matchedOn = candidate.matchedOn
        self.attendees = attendees
    }
}

/// One row of `upcoming`, whichever of the two things it came from.
struct UpcomingJSON: Encodable {
    let ref: String
    let title: String
    let start: Date?
    let end: Date?
    let durationMs: Int?
    let attendees: [Attendee]
    let calendarName: String?
    let videoLink: String?
    /// False while the event is calendar-only. A write against its `cal:` ref materialises the row.
    let hasRow: Bool
    /// The meeting state, present only once there is a row to have one.
    let state: String?
    let folder: String?

    init(event: CalendarEvent) {
        self.ref = "cal:\(event.id)"
        self.title = event.title
        self.start = event.start
        self.end = event.end
        self.durationMs = Int(event.end.timeIntervalSince(event.start) * 1000)
        self.attendees = event.attendees
        self.calendarName = event.calendarName
        self.videoLink = event.videoLink?.absoluteString
        self.hasRow = false
        self.state = nil
        self.folder = nil
    }

    init(event: CalendarEvent, meeting: Meeting, folder: String?) {
        self.ref = meeting.id
        self.title = meeting.title
        self.start = meeting.scheduledStart ?? event.start
        self.end = meeting.scheduledEnd ?? event.end
        self.durationMs = MeetingJSON.durationMs(meeting)
            ?? Int(event.end.timeIntervalSince(event.start) * 1000)
        self.attendees = meeting.attendees.isEmpty ? event.attendees : meeting.attendees
        self.calendarName = event.calendarName
        self.videoLink = event.videoLink?.absoluteString
        self.hasRow = true
        self.state = meeting.state.rawValue
        self.folder = folder
    }

    init(meeting: Meeting, folder: String?) {
        self.ref = meeting.id
        self.title = meeting.title
        self.start = meeting.scheduledStart
        self.end = meeting.scheduledEnd
        self.durationMs = MeetingJSON.durationMs(meeting)
        self.attendees = meeting.attendees
        self.calendarName = nil
        self.videoLink = nil
        self.hasRow = true
        self.state = meeting.state.rawValue
        self.folder = folder
    }
}

private struct UpcomingListJSON: Encodable {
    let days: Int
    let upcoming: [UpcomingJSON]
}

private struct MatchJSON: Encodable {
    let query: String
    let candidates: [CandidateJSON]
    /// Candidates that scored but have already started. `upcoming` is named for what has not
    /// happened yet, so they are not in `candidates` — but they are here, because an agent that
    /// cannot see them cannot tell "no such meeting" from "it was this morning".
    let hidden: [CandidateJSON]
}
