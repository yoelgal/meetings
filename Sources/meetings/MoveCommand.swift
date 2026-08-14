import ArgumentParser
import Foundation
import MeetingsCore

/// Filing a meeting. Also a vocabulary decision: a meeting's folder is what decides which scoped
/// terms the recogniser gets for it, so moving one changes what its re-transcription hears.
struct MoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a meeting into a folder.",
        discussion: """
            The folder has to exist. Create one with meetings folder create <name>.

            --folder "" moves the meeting back to unfiled.
            """
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Option(name: .long, help: "The destination folder, or \"\" for unfiled.")
    var folder: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            let destination = name.isEmpty ? nil : try context.store.folder(named: name)
            if !name.isEmpty, destination == nil {
                throw CLIError.notFound("No folder named \(name). Create it with meetings folder create \(name).")
            }
            let (target, materialised) = try await context.writeTarget(ref)

            let updated = try context.store.updateMeeting(id: target.id) { meeting in
                meeting.folderID = destination?.id
            }

            if global.json {
                try Out.json(WriteResultJSON(updated, folder: destination?.name, materialised: materialised))
                return
            }
            Out.line("Moved \(updated.id) (\(updated.title)) to \(destination?.name ?? "unfiled")")
        }
    }
}
