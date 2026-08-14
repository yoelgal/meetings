import ArgumentParser
import Foundation
import MeetingsCore

/// `meetings delete <ref> [--yes]`.
///
/// The one command in the tree that destroys a recording. Everything else either adds something or
/// changes a field you can change back; this takes the transcript, the notes and the audio and there
/// is no trash to fish them out of. So it is two steps by default: say what would go, and make the
/// caller say it is fine — the same shape `folder delete` uses for the same reason.
struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a meeting, its transcript and its audio.",
        discussion: """
            There is no undo and no trash. The transcript, the live notes, the pre-notes, the \
            summary, the actions and the recorded audio all go, and the meeting stops matching \
            meetings search.

            Without --yes nothing is written: the command reports what would go and exits 3. Keep a \
            copy first with meetings export <ref> --format bundle --with-audio, which re-imports \
            exactly.

            A meeting that is still recording or transcribing is refused either way — one is having \
            audio written into it and the other is having it read.
            """
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Flag(name: .long, help: "Delete it. Without this the command only reports what would go.")
    var yes = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            // Resolved for **read**, unlike every other write command. `writeTarget` materialises a
            // row for a `cal:` ref that has none, which here would mean creating a meeting purely in
            // order to delete it — a store write for a command the user is about to be told did
            // nothing. A `cal:` ref that does have a row still resolves to it, so an agent holding
            // an event identifier can delete what it recorded.
            let meeting: Meeting
            switch try await context.readTarget(ref) {
            case .meeting(let found):
                meeting = found
            case .event:
                throw CLIError.notFound(
                    "\(ref) is a calendar event with no meeting row yet, so there is nothing to delete."
                )
            }

            // Checked before the preview rather than left to the store, which enforces it either
            // way: without this, a meeting that is mid-recording gets told what deleting it would
            // cost and which flag to pass, and the flag then cannot work. Advice that fails when
            // followed is worse than a refusal.
            guard meeting.state != .recording, meeting.state != .transcribing else {
                throw CLIError.invalidState(
                    "\(meeting.title) is still \(meeting.state.rawValue), so it cannot be deleted "
                        + "yet. Audio is being written into it or read out of it right now."
                )
            }

            let segments = try context.store.segments(meetingID: meeting.id).count
            let notes = try context.store.notes(meetingID: meeting.id).count
            let hasAudio = meeting.audioPath != nil && meeting.audioPurgedAt == nil

            guard yes else {
                // Exit 3 rather than a report and exit 0. Exit 0 means "it worked" to everything
                // that branches on it, and an agent running `meetings delete x && …` must not read
                // success for a delete that deliberately did not happen.
                throw CLIError.invalidState("""
                    \(meeting.title) would lose \(count(segments, "transcript segment")), \
                    \(count(notes, "note"))\(hasAudio ? " and its audio" : ""). There is no undo. \
                    Pass --yes if that is what you want, or keep a copy first with \
                    meetings export \(meeting.id) --format bundle --with-audio.
                    """)
            }

            // False is a row that went missing between the resolve and here — the app deleting it in
            // the other process. Nothing was destroyed by this run, so it reports not-found rather
            // than claiming a deletion it did not make.
            guard try context.store.deleteMeeting(id: meeting.id) else {
                throw CLIError.notFound("No meeting with id \(meeting.id)")
            }

            if global.json {
                try Out.json(DeleteResultJSON(
                    deleted: meeting.id,
                    title: meeting.title,
                    segments: segments,
                    notes: notes,
                    audio: hasAudio
                ))
                return
            }
            Out.line("Deleted \(meeting.id) (\(meeting.title)) "
                + "(\(count(segments, "transcript segment")), \(count(notes, "note"))"
                + "\(hasAudio ? ", audio removed" : ""))")
        }
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

private struct DeleteResultJSON: Encodable {
    /// The id, not a boolean: a caller reading this back has proof of *which* meeting went, and the
    /// envelope only exists on the run that actually deleted one.
    let deleted: String
    let title: String
    let segments: Int
    let notes: Int
    let audio: Bool
}
