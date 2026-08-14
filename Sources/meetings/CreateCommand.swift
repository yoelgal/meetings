import ArgumentParser
import Foundation
import MeetingsCore

/// `meetings create` — explicit, fully-specified creation, and the way every legacy
/// dump, voice memo and third-party export comes across.
///
/// **This command infers nothing.** No filename date parsing, no mtime fallback, no title guessing,
/// no adapters for other people's formats. That is not laziness, it is the finding: an agent
/// that reads the files and asks when it is unsure beats every heuristic, and a heuristic that is
/// wrong 5% of the time across 200 meetings is worse than no import at all.
struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a meeting from explicit fields. Nothing is inferred.",
        discussion: """
            Audio present means the meeting enters `transcribing` and joins the batch queue, which \
            the app drains. This command never blocks on transcription. Audio absent means it \
            lands at `complete` immediately. A meeting with notes and no audio and no transcript \
            is legal.

            --audio takes anything AVFoundation reads (m4a, mp3, wav, caf) and converts it to the \
            16 kHz mono the batch pass expects. A single imported file lands on the `mic` channel.

            --transcript-file takes a JSON array of {channel, startMs, endMs, text}, the same \
            shape a bundle's transcript.json has. Plain text lands as one segment covering the \
            whole meeting.

            --summary-file, --prenotes-file and --transcript-file each accept - for stdin.

            In plain mode the new ref is the only thing on stdout, so REF=$(meetings create …) \
            works; the rest goes to stderr. With --json you get the whole row.
            """
    )

    @Option(name: .long, help: "The meeting's title. Required, and never guessed from a filename.")
    var title: String

    @Option(name: .long, help: "When it happened: 2025-11-04T14:00Z, 2025-11-04T14:00, or 2025-11-04.")
    var date: String

    @Option(name: .long, help: "How long it ran: 45m, 1h30m, 90 (minutes).")
    var duration: String?

    @Option(name: .long, help: "Folder name. Created if this store has never seen it.")
    var folder: String?

    @Option(name: .long, help: "Comma-separated: \"Will,Sofia Nunes,sofia@example.com\".")
    var attendees: String?

    @Option(name: .long, help: "An existing recording to attach. Converted to 16 kHz mono mic.wav.")
    var audio: String?

    @Option(name: .customLong("transcript-file"), help: "A transcript to attach: bundle-shaped JSON, or plain text.")
    var transcriptFile: String?

    @Option(name: .customLong("summary-file"), help: "A summary to attach, as markdown.")
    var summaryFile: String?

    @Option(name: .customLong("prenotes-file"), help: "Pre-meeting notes to attach, as markdown.")
    var prenotesFile: String?

    @Option(name: .long, help: "recorded or imported. Marks where this meeting came from.")
    var source: MeetingSource = .recorded

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            // `--title ""` is what a shell hands over when the variable behind it was never set, and
            // it used to create a nameless row: exit 0, a blank line in `list`, and a meeting the
            // agent that made it cannot describe to anybody. The help calls the title required, so
            // requiring it is the honest reading.
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.usage("A meeting needs a title. --title came through empty.")
            }
            guard let when = MeetingCreate.date(from: date) else {
                throw CLIError.usage(
                    "Cannot read \(date) as a date. Use 2025-11-04T14:00Z, 2025-11-04T14:00 or 2025-11-04."
                )
            }
            var seconds: TimeInterval?
            if let duration {
                guard let parsed = MeetingCreate.duration(from: duration) else {
                    throw CLIError.usage("Cannot read \(duration) as a duration. Use 45m, 1h30m or a number of minutes.")
                }
                seconds = parsed
            }

            let stdinFlags = [transcriptFile, summaryFile, prenotesFile].filter { $0 == "-" }
            guard stdinFlags.count <= 1 else {
                throw CLIError.usage("Only one of --transcript-file, --summary-file and --prenotes-file can be -.")
            }

            let audioURL = try audio.map { try IOPath.mustExist($0) }
            let transcriptData = try transcriptFile.map { try data(at: $0) }
            let context = try CLIContext.open()

            let request = MeetingCreate.Request(
                title: title,
                date: when,
                duration: seconds,
                folderName: folder,
                attendees: attendees.map(MeetingCreate.attendees(from:)) ?? [],
                audio: audioURL,
                transcript: try transcriptData.map {
                    try TranscriptDraft.parse($0, durationMs: seconds.map { Int($0 * 1000) })
                } ?? [],
                summary: try summaryFile.map { try IOPath.text(try data(at: $0), from: $0) },
                preNotes: try prenotesFile.map { try IOPath.text(try data(at: $0), from: $0) },
                source: source,
                importedFrom: source == .imported ? provenance : nil
            )

            let result = try MeetingCreate.create(request, store: context.store)
            let meeting = result.meeting
            let folderName = try meeting.folderID.flatMap { try context.store.folder(id: $0)?.name }
            // A created meeting with no audio lands at `complete` whether or not anybody
            // has written it up, so it never appears in `list --state ready`. Say that here rather
            // than let an agent go looking for it in the write-up queue and find an empty list.
            let next: String
            if meeting.state == .transcribing {
                next = "queued for the batch transcription pass; the app runs it"
            } else if result.segmentCount > 0, meeting.summary?.nilIfEmpty == nil {
                next = "nothing required. A created meeting is complete on arrival, so it is not "
                    + "in list --state ready. It has a transcript and no summary. Write one with "
                    + "meetings summary set \(meeting.id)"
            } else {
                next = "nothing. The meeting is complete"
            }

            if global.json {
                try Out.json(CreateResultJSON(
                    ref: meeting.id,
                    title: meeting.title,
                    state: meeting.state.rawValue,
                    folder: folderName,
                    startedAt: meeting.startedAt,
                    endedAt: meeting.endedAt,
                    attendees: meeting.attendees,
                    segments: result.segmentCount,
                    audioFile: result.audioFile?.path,
                    source: meeting.source.rawValue,
                    importedFrom: meeting.importedFrom,
                    markdownDirectory: result.markdownDirectory?.path,
                    next: next
                ))
                return
            }

            // The ref alone on stdout: this command exists to be chained.
            Out.line(meeting.id)
            var rows = [["title", meeting.title], ["state", meeting.state.rawValue]]
            if let folderName { rows.append(["folder", folderName]) }
            if result.segmentCount > 0 { rows.append(["transcript", "\(result.segmentCount) segments"]) }
            if let audioFile = result.audioFile { rows.append(["audio", audioFile.path]) }
            if let markdown = result.markdownDirectory { rows.append(["markdown", markdown.path]) }
            rows.append(["next", next])
            Out.note(Format.columns(rows).joined(separator: "\n"))
        }
    }

    /// `imported_from` holds "the original bundle id or source filename". For a create the
    /// filename is the honest answer, and the audio is the file the meeting most *is*.
    private var provenance: String? {
        [audio, transcriptFile, summaryFile, prenotesFile]
            .compactMap { $0 }
            .first { $0 != "-" }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private func data(at path: String) throws -> Data {
        if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
        return try IOPath.contents(of: path)
    }
}
