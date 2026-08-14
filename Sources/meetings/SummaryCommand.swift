import ArgumentParser
import Foundation
import MeetingsCore

/// Where an agent's write-up lands. `meetings show <ref> --summary` reads it back; there is no
/// `summary get`, because that would be the same command twice.
struct SummaryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary",
        abstract: "The agent-written write-up of a meeting.",
        subcommands: [SummarySet.self]
    )
}

struct SummarySet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Write a meeting's summary.",
        discussion: """
            Takes the markdown as an argument, as --file <path>, or as - to read stdin, so an agent \
            can pipe what it generated straight in.

            A meeting with a summary is complete by definition, so this moves a ready \
            meeting to complete. Setting an empty summary clears it and moves it back.
            """
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Argument(help: "The summary markdown, or - to read stdin.")
    var text: String?

    @Option(name: .long, help: "Read the summary from this file instead.")
    var file: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let markdown = try TextInput.read(text, file: file, what: "the summary")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let context = try CLIContext.open()
            let (target, materialised) = try await context.writeTarget(ref)

            // The field and the state move together, in `Meeting.setSummary` — the app's editor
            // clears the same column, and one rule in one place is what keeps a summary cleared
            // here and one cleared in the window landing in the same state.
            let updated = try context.store.updateMeeting(id: target.id) { $0.setSummary(markdown) }
            let folder = try updated.folderID.flatMap { try context.store.folder(id: $0)?.name }

            if global.json {
                var result = WriteResultJSON(updated, folder: folder, materialised: materialised)
                result.summary = updated.summary
                try Out.json(result)
                return
            }
            guard !markdown.isEmpty else {
                Out.line("Cleared the summary on \(updated.id). \(updated.title) is \(updated.state.rawValue)")
                return
            }
            Out.line("Summary written on \(updated.id). \(updated.title) is \(updated.state.rawValue)")
        }
    }
}
