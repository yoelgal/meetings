import ArgumentParser
import Foundation
import MeetingsCore

/// Live notes — what you typed *during* the meeting. Every one carries the offset it was written at
/// and anchors to the transcript position at that instant, which is what makes "clicking a
/// note scrolls the transcript to its anchor" possible at all.
struct NoteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Live notes taken during a meeting.",
        subcommands: [NoteAdd.self, NoteList.self],
        defaultSubcommand: NoteList.self
    )
}

struct NoteAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a live note at a point in the recording.",
        discussion: """
            Live notes only. A note's whole value is where it sits in the transcript, so --at is \
            required unless a recording is running, in which case the elapsed time is used.

            --at takes 12:30, 1:05:00, 12m, 750s or a number of seconds, the same offsets \
            `meetings transcript` prints.
            """
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Argument(help: "The note, or - to read stdin.")
    var text: String?

    @Option(name: .long, help: "Where in the recording the note belongs, e.g. 12:30.")
    var at: String?

    @Option(name: .long, help: "Read the note from this file instead.")
    var file: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let body = try TextInput.nonEmpty(text, file: file, what: "the note")
            // Everything that can be checked without touching the store is checked first: the text,
            // then the offset's spelling. A `--at` of "banana" must not leave a materialised row
            // behind for a note that never landed.
            let explicitOffset = try at.map(Parse.offsetMs)
            let context = try CLIContext.open()
            // Without `--at` the offset can only come from a running recording, so `recording` is
            // the only state this write works from — checked before a `cal:` ref materialises,
            // because the row it would create is `scheduled` and could never have satisfied it.
            let (meeting, materialised) = try await context.writeTarget(
                ref,
                allowing: explicitOffset == nil ? [.recording] : Set(MeetingState.allCases),
                refusal: Self.refusal
            )
            let offsetMs = try explicitOffset ?? Self.elapsedMs(meeting)

            let note = try context.store.addNote(meetingID: meeting.id, tOffsetMs: offsetMs, text: body)
            let folder = try meeting.folderID.flatMap { try context.store.folder(id: $0)?.name }

            if global.json {
                var result = WriteResultJSON(meeting, folder: folder, materialised: materialised)
                result.note = NoteJSON(note)
                try Out.json(result)
                return
            }
            Out.line("Note added at \(Format.offset(ms: offsetMs)) on \(meeting.id) (\(meeting.title))")
        }
    }

    /// The offset the note anchors at, and the one thing this command refuses to invent.
    ///
    /// Without `--at` the only honest source is a recording that is actually running: `started_at`
    /// is on the row, so the elapsed time is the same number the app's own timer shows. Anywhere
    /// else there is nothing to derive it from, and a note at a made-up offset does not fail — it
    /// anchors to a random point in the transcript and stays there, quietly wrong, next to a
    /// sentence nobody said when you wrote it.
    static func elapsedMs(_ meeting: Meeting) throws -> Int {
        guard meeting.state == .recording, let startedAt = meeting.startedAt else {
            throw refusal(meeting.title, meeting.state)
        }
        return max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    /// The same sentence whether the state was read off an existing row or off the `scheduled` row a
    /// `cal:` ref would have created.
    static func refusal(_ title: String, _ state: MeetingState) -> CLIError {
        CLIError.invalidState("""
            \(title) is \(state.rawValue), so there is no elapsed time to anchor this note to. \
            Pass --at <offset>. For notes written before the meeting, use meetings prenotes add.
            """)
    }
}

struct NoteList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List a meeting's live notes, in the order they were written."
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            var title = ""
            var notes: [Note] = []
            switch try await context.readTarget(ref) {
            case .event(let event):
                // A calendar event with no row has no notes. That is an empty list, not an error —
                // the same answer `transcript` gives, so an agent can ask without branching first.
                title = event.title
            case .meeting(let meeting):
                title = meeting.title
                notes = try context.store.notes(meetingID: meeting.id)
            }

            if global.json {
                try Out.json(NoteListJSON(title: title, notes: notes.map(NoteJSON.init)))
                return
            }
            guard !notes.isEmpty else {
                Out.note("\(title) has no live notes.")
                return
            }
            Out.line(Format.columns(notes.map { note in
                [Format.offset(ms: note.tOffsetMs), Format.oneLine(note.text)]
            }).joined(separator: "\n"))
        }
    }
}

private struct NoteListJSON: Encodable {
    let title: String
    let notes: [NoteJSON]
}
