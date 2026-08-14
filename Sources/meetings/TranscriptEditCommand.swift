import ArgumentParser
import Foundation
import MeetingsCore

/// Correcting a transcript segment, and — the part that actually matters — promoting the correction
/// into the vocabulary so the same word is not wrong in the next fifty meetings.
struct TranscriptEditCommand: AsyncParsableCommand {
    /// Registered as `transcript-edit` and reached as `meetings transcript edit` — see
    /// `MeetingsCLI.normalisedArguments`, which is where the two-word spelling is turned into this
    /// one. It cannot be a subcommand of `transcript`: that command takes a positional `<ref>`, and
    /// ArgumentParser fills positionals before it looks for a subcommand name, so `edit` would be
    /// swallowed as the ref.
    static let configuration = CommandConfiguration(
        commandName: "transcript-edit",
        abstract: "Correct one transcript segment (meetings transcript edit <ref>).",
        discussion: """
            Only in ready or complete. Editing during recording is refused because the batch pass \
            replaces the live transcript wholesale on stop and the correction would vanish with it.

            An edited segment is kept verbatim through every later re-transcription, and the \
            machine's own version of the same span is dropped rather than kept alongside it.

            --add-vocab adds the corrected word or short phrase as a vocabulary term with \
            source=correction, scoped to the meeting's folder.
            """
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Option(name: .long, help: "The segment id, as printed by meetings transcript --json.")
    var segment: Int64

    @Option(name: .long, help: "The corrected text for that segment.")
    var text: String

    @Flag(name: .long, help: "Also add the corrected term to the vocabulary.")
    var addVocab = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let corrected = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty else {
                throw CLIError.usage("--text is the corrected line. An empty segment is a deletion, which this is not.")
            }
            let context = try CLIContext.open()

            // The state guard runs here as well as in the store, and it runs *first*, before the
            // term is extracted. Otherwise `--add-vocab` on a recording meeting would answer 64
            // (bad phrase) when the real answer is 3 (wrong state) — one error per cause.
            //
            // It also runs before the row is materialised: a `cal:` ref would create a `scheduled`
            // meeting, which this command then always refuses, leaving behind a meeting for an edit
            // that never happened. Nothing about a segment id can be true of a row that has no
            // transcript, so the refusal costs the store nothing.
            let (meeting, materialised) = try await context.writeTarget(
                ref,
                allowing: [.ready, .complete],
                refusal: { title, state in
                    CLIError.invalidState("""
                        \(title) is \(state.rawValue). Transcript edits are only allowed once a \
                        meeting is ready or complete. The batch pass replaces the live transcript \
                        on stop, so an earlier edit would be thrown away with it.
                        """)
                }
            )
            guard let existing = try context.store.transcriptSegment(id: segment) else {
                throw CLIError.notFound("No transcript segment with id \(segment)")
            }
            // A segment id is a global integer, so nothing but this check stops a valid ref and
            // somebody else's segment id from editing a meeting you never named.
            guard existing.meetingID == meeting.id else {
                throw CLIError.notFound("Segment \(segment) belongs to another meeting, not \(meeting.title)")
            }

            var promoted = addVocab ? try Correction.term(from: existing.text, to: corrected) : nil
            // Too short to reach the recogniser, so it is not stored — but the correction itself is
            // still good and still lands. A warning rather than a refusal: failing the edit over
            // the vocabulary half of it would throw away the part that worked.
            let unpromotable = promoted.flatMap(VocabularyRules.refusal(for:))
            if unpromotable != nil { promoted = nil }
            let updated = try context.store.editSegment(id: segment, text: corrected)
            let folder = try meeting.folderID.flatMap { try context.store.folder(id: $0) }
            let term = try promoted.map { term in
                try context.store.addVocabularyTerm(VocabularyTerm(
                    term: term,
                    // Same scope rule the attendee auto-seed uses: a correction made in a folder is
                    // that folder's jargon, and pushing it at every meeting is how vocabulary starts
                    // firing on words nobody said.
                    folderID: folder?.id,
                    source: .correction
                ))
            }

            if global.json {
                var result = WriteResultJSON(meeting, folder: folder?.name, materialised: materialised)
                result.segment = SegmentJSON(updated)
                result.vocabulary = term.map { VocabJSON($0, folder: folder?.name) }
                result.vocabularyRefused = unpromotable
                try Out.json(result)
                return
            }
            Out.line("Segment \(segment) corrected on \(meeting.id) (\(meeting.title))")
            if let term {
                Out.line("Added \(term.term) to the vocabulary (\(folder?.name ?? "global"))")
            }
            if let unpromotable { Out.note("Not added to the vocabulary: \(unpromotable)") }
        }
    }
}
