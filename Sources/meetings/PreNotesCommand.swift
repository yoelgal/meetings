import ArgumentParser
import Foundation
import MeetingsCore

/// Pre-notes are what you wrote *before* the meeting, and they are the steer for everything written
/// after it. They are also the first thing an agent writes against a calendar event, which
/// is why `add` and `set` materialise the row.
struct PreNotesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prenotes",
        abstract: "Read and write the notes you take before a meeting.",
        discussion: """
            add appends a paragraph; set replaces everything. Both accept the text as an argument, \
            as --file <path>, or as - to read stdin.

            Writing against cal:<eventIdentifier> creates the scheduled meeting first, so there is \
            no separate create step.
            """,
        subcommands: [PreNotesGet.self, PreNotesAdd.self, PreNotesSet.self],
        defaultSubcommand: PreNotesGet.self
    )
}

struct PreNotesGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print a meeting's pre-notes and nothing else."
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            // A read, so an untouched calendar event answers "nothing written yet" rather than
            // materialising a row just to tell you it is empty.
            switch try await context.readTarget(ref) {
            case .event(let event):
                if global.json {
                    try Out.json(PreNotesJSON(ref: "cal:\(event.id)", title: event.title, preNotes: ""))
                    return
                }
                Out.note("\(event.title) has no pre-notes yet.")
            case .meeting(let meeting):
                if global.json {
                    try Out.json(PreNotesJSON(ref: meeting.id, title: meeting.title, preNotes: meeting.preNotes))
                    return
                }
                guard let text = meeting.preNotes.nilIfEmpty else {
                    Out.note("\(meeting.title) has no pre-notes yet.")
                    return
                }
                Out.line(text)
            }
        }
    }
}

struct PreNotesAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Append a paragraph to a meeting's pre-notes."
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Argument(help: "The text to append, or - to read stdin.")
    var text: String?

    @Option(name: .long, help: "Read the text from this file instead.")
    var file: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await PreNotesWrite.run(
            ref: ref, text: text, file: file, json: global.json, verb: "Appended to the",
            combine: { existing, addition in
                // A blank line between paragraphs, because pre-notes are markdown and two lines
                // welded together become one paragraph that says something neither of them said.
                guard let existing = existing.nilIfEmpty else { return addition }
                return existing.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + addition
            }
        )
    }
}

struct PreNotesSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Replace a meeting's pre-notes."
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Argument(help: "The replacement text, or - to read stdin.")
    var text: String?

    @Option(name: .long, help: "Read the replacement from this file instead.")
    var file: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await PreNotesWrite.run(
            ref: ref, text: text, file: file, json: global.json, verb: "Replaced the",
            combine: { _, replacement in replacement }
        )
    }
}

/// Append and replace differ by one closure, so they share everything else — including the
/// materialise-then-write order, which is the part that has to be identical.
private enum PreNotesWrite {
    static func run(
        ref: String,
        text: String?,
        file: String?,
        json: Bool,
        verb: String,
        combine: @escaping @Sendable (String, String) -> String
    ) async throws {
        try await emitting(json: json) {
            let addition = try TextInput.nonEmpty(text, file: file, what: "the pre-notes")
            let context = try CLIContext.open()
            let (target, materialised) = try await context.writeTarget(ref)

            // Read-modify-write inside the store's transaction rather than out here: the app may be
            // editing the same field, and a fetch-then-save would quietly drop its edit.
            let updated = try context.store.updateMeeting(id: target.id) { meeting in
                meeting.preNotes = combine(meeting.preNotes, addition)
            }
            let folder = try updated.folderID.flatMap { try context.store.folder(id: $0)?.name }

            if json {
                var result = WriteResultJSON(updated, folder: folder, materialised: materialised)
                result.preNotes = updated.preNotes
                try Out.json(result)
                return
            }
            if materialised {
                Out.note("Created the meeting row for \(updated.title) from its calendar event.")
            }
            Out.line("\(verb) pre-notes on \(updated.id) (\(updated.title))")
        }
    }
}

private struct PreNotesJSON: Encodable {
    let ref: String
    let title: String
    let preNotes: String
}
