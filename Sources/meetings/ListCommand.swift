import ArgumentParser
import Foundation
import MeetingsCore

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List meetings, newest first.",
        discussion: """
            Columns are ref, date, duration, state, folder, title. The ref is the first field so a \
            listing pipes straight into another command.
            """
    )

    @Option(name: .long, help: "Only meetings in this folder.")
    var folder: String?

    @Option(name: .long, help: "Only meetings on or after this date: 2026-08-01, an ISO-8601 instant, or a window like 7d.")
    var since: String?

    @Option(name: .long, help: "Only meetings in this state: scheduled, recording, transcribing, ready or complete.")
    var state: MeetingState?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let names = try context.folderNames()
            let cutoff = try since.map(Parse.since)

            // Ask the store for the narrowest set it can answer directly, then apply what is left in
            // memory. A personal store holds hundreds of meetings, not millions.
            var meetings: [Meeting]
            if let folder {
                meetings = try context.store.meetings(folderID: try context.folderID(named: folder))
            } else if let state {
                meetings = try context.store.meetings(state: state)
            } else {
                meetings = try context.store.allMeetings()
            }
            if let state { meetings = meetings.filter { $0.state == state } }
            if let cutoff {
                // A row with no date at all cannot be shown to be after the cutoff, so it is not.
                meetings = meetings.filter { ($0.sortDate ?? .distantPast) >= cutoff }
            }

            // One query for the whole listing rather than one per row: a transcript failure is rare,
            // so almost every list pays a single empty lookup and nothing else.
            let incomplete = (try? context.store.meetingIDsWithTranscriptIssues()) ?? []

            if global.json {
                try Out.json(ListJSON(meetings: try meetings.map { meeting in
                    MeetingJSON(
                        meeting,
                        folder: meeting.folderID.flatMap { names[$0] },
                        transcriptIssues: incomplete.contains(meeting.id)
                            ? try context.store.transcriptIssues(meetingID: meeting.id)
                            : []
                    )
                }))
                return
            }

            guard !meetings.isEmpty else {
                Out.note("No meetings match.")
                return
            }

            let rows = meetings.map { meeting in
                [
                    meeting.id,
                    Format.when(meeting.sortDate),
                    Format.duration(ms: MeetingJSON.durationMs(meeting)),
                    // A suffix rather than a seventh column: the state cell stays one token, so the
                    // listing still cuts on whitespace, and "ready*" is visibly not "ready".
                    meeting.state.rawValue + (incomplete.contains(meeting.id) ? "*" : ""),
                    meeting.folderID.flatMap { names[$0] } ?? "-",
                    Format.oneLine(meeting.title),
                ]
            }
            Out.line(Format.columns(rows).joined(separator: "\n"))
            // The legend goes to stderr so the table itself stays exactly the rows it says it is.
            if meetings.contains(where: { incomplete.contains($0.id) }) {
                Out.note("* one channel of that meeting could not be transcribed. meetings show <ref> says which.")
            }
        }
    }
}

private struct ListJSON: Encodable {
    let meetings: [MeetingJSON]
}
