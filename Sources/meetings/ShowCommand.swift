import ArgumentParser
import Foundation
import MeetingsCore

/// The read an agent hits constantly, so it stays cheap: with no flags it prints what a meeting *is*
/// and never touches the transcript table. You pay for the transcript only when you ask for it.
struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one meeting, or a calendar event that has no row yet.",
        discussion: """
            With no section flags: title, timings, attendees, pre-notes, summary and actions. The \
            transcript is never loaded for that.

            With exactly one section flag, only that section's text is printed, so \
            `meetings show <ref> --summary > summary.md` gives you the summary and nothing else. \
            With several, each is printed under a heading. Sections with nothing in them are left \
            out rather than printed empty.
            """
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Flag(name: .long, help: "Include the live notes taken during the meeting.")
    var notes = false

    @Flag(name: .long, help: "Include the full transcript.")
    var transcript = false

    @Flag(name: .long, help: "Include the summary.")
    var summary = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            switch try await context.readTarget(ref) {
            case .event(let event):
                try showEvent(event)
            case .meeting(let meeting):
                try showMeeting(meeting, context: context)
            }
        }
    }

    private var selectedSections: [String] {
        var selected: [String] = []
        if summary { selected.append("summary") }
        if notes { selected.append("notes") }
        if transcript { selected.append("transcript") }
        return selected
    }

    // MARK: - A calendar event with no row

    private func showEvent(_ event: CalendarEvent) throws {
        if global.json {
            try Out.json(EventShowJSON(kind: "event", event: EventJSON(event)))
            return
        }
        guard selectedSections.isEmpty else {
            Out.note("\(event.title) is a calendar event with no meeting row yet, so it has no \(selectedSections.joined(separator: ", ")).")
            return
        }
        Out.line(event.title)
        var rows = [
            ["ref", "cal:\(event.id)"],
            ["when", "\(Format.when(event.start)) (\(Format.duration(ms: Int(event.end.timeIntervalSince(event.start) * 1000))))"],
            ["state", "calendar event, nothing recorded yet"],
            ["calendar", event.calendarName],
        ]
        if !event.attendees.isEmpty { rows.append(["attendees", Format.attendees(event.attendees)]) }
        if let link = event.videoLink { rows.append(["video", link.absoluteString]) }
        Out.line(Format.columns(rows).joined(separator: "\n"))
        if let invitation = event.notes, !invitation.isEmpty {
            Out.line()
            Out.line("## invitation")
            Out.line(invitation)
        }
    }

    // MARK: - A meeting row

    private func showMeeting(_ meeting: Meeting, context: CLIContext) throws {
        let folder = try meeting.folderID.flatMap { try context.store.folder(id: $0)?.name }
        let sections = selectedSections

        let liveNotes = notes ? try context.store.notes(meetingID: meeting.id) : []
        let segments = transcript ? try context.store.segments(meetingID: meeting.id) : []
        // Always, and whatever section was asked for: a half transcript that reads as a whole one is
        // the failure this exists to prevent, and the row it comes from is one indexed lookup.
        let issues = (try? context.store.transcriptIssues(meetingID: meeting.id)) ?? []

        if global.json {
            try Out.json(MeetingShowJSON(
                kind: "meeting",
                meeting: MeetingJSON(meeting, folder: folder, transcriptIssues: issues),
                preNotes: sections.isEmpty ? emptyToNil(meeting.preNotes) : nil,
                summary: sections.isEmpty || summary ? meeting.summary.flatMap(emptyToNil) : nil,
                actions: sections.isEmpty ? MarkdownActions.parse(meeting.summary ?? "").nilIfEmpty : nil,
                notes: notes ? liveNotes.map(NoteJSON.init) : nil,
                transcript: transcript ? segments.map(SegmentJSON.init) : nil
            ))
            return
        }

        // One flag means "give me that text and nothing else" — the form that pipes into a file. The
        // warning still has to be said, so it goes to stderr: the pipe stays exactly the text that
        // was asked for, and the person watching still learns the transcript is missing a side.
        if sections.count == 1 {
            for issue in issues { Out.note(issue.sentence) }
            switch sections[0] {
            case "summary":
                guard let summary = meeting.summary?.nilIfEmpty else {
                    Out.note("\(meeting.title) has no summary yet.")
                    return
                }
                Out.line(summary)
            case "notes":
                guard !liveNotes.isEmpty else {
                    Out.note("\(meeting.title) has no live notes.")
                    return
                }
                Out.line(liveNotes.map { "[\(Format.offset(ms: $0.tOffsetMs))] \($0.text)" }.joined(separator: "\n"))
            default:
                guard !segments.isEmpty else {
                    Out.note("\(meeting.title) has no transcript.")
                    return
                }
                Out.line(TranscriptRender.markdown(segments).joined(separator: "\n"))
            }
            return
        }

        if sections.isEmpty {
            Out.line(meeting.title)
            var rows = [
                ["ref", meeting.id],
                ["when", "\(Format.when(meeting.sortDate)) (\(Format.duration(ms: MeetingJSON.durationMs(meeting))))"],
                ["state", meeting.state.rawValue],
            ]
            if let folder { rows.append(["folder", folder]) }
            if !meeting.attendees.isEmpty { rows.append(["attendees", Format.attendees(meeting.attendees)]) }
            if meeting.source == .imported {
                rows.append(["imported", meeting.importedFrom ?? "yes"])
            }
            // What the row records, not why. `audio_purged_at` says the audio is gone and when;
            // naming this machine's retention sweep as the cause would be a guess, since a restored
            // bundle carries the column over from wherever it was purged. `meetings status` is
            // where the retention setting is explained.
            if let purged = meeting.audioPurgedAt {
                rows.append(["audio", "deleted \(Format.when(purged))"])
            }
            Out.line(Format.columns(rows).joined(separator: "\n"))
            // Directly under the header rows rather than in a section at the bottom: it changes how
            // everything below it should be read.
            if !issues.isEmpty {
                section("transcript issues", issues.map(\.sentence).joined(separator: "\n"))
            }
            section("pre-notes", meeting.preNotes.nilIfEmpty)
            section("summary", meeting.summary?.nilIfEmpty)
            // Read back out of the write-up above, so this is a structured view of what is
            // already on screen rather than a second list that can disagree with it.
            if let actions = MarkdownActions.parse(meeting.summary ?? "").nilIfEmpty {
                section("actions", actions.map(Self.line(for:)).joined(separator: "\n"))
            }
            return
        }

        Out.line(meeting.title)
        if !issues.isEmpty {
            section("transcript issues", issues.map(\.sentence).joined(separator: "\n"))
        }
        if summary { section("summary", meeting.summary?.nilIfEmpty) }
        if notes {
            section("notes", liveNotes.isEmpty
                ? nil
                : liveNotes.map { "[\(Format.offset(ms: $0.tOffsetMs))] \($0.text)" }.joined(separator: "\n"))
        }
        if transcript {
            section("transcript", segments.isEmpty ? nil : TranscriptRender.markdown(segments).joined(separator: "\n"))
        }
    }

    /// A section with nothing in it is left out, never printed empty.
    private func section(_ title: String, _ body: String?) {
        guard let body else { return }
        Out.line()
        Out.line("## \(title)")
        Out.line(body)
    }

    private static func line(for action: Action) -> String {
        var line = "[\(action.done ? "x" : " ")] \(action.text)"
        let trailing = [action.owner, action.due.map { "due \($0)" }].compactMap { $0 }
        if !trailing.isEmpty { line += " (\(trailing.joined(separator: ", ")))" }
        return line
    }

    private func emptyToNil(_ text: String) -> String? { text.nilIfEmpty }
}

extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

private struct MeetingShowJSON: Encodable {
    let kind: String
    let meeting: MeetingJSON
    let preNotes: String?
    let summary: String?
    let actions: [Action]?
    let notes: [NoteJSON]?
    let transcript: [SegmentJSON]?
}

private struct EventShowJSON: Encodable {
    let kind: String
    let event: EventJSON
}
