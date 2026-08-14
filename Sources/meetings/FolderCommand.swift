import ArgumentParser
import Foundation
import MeetingsCore

/// Flat folders (`parent_id` exists but is always null in v1). A folder is also a
/// vocabulary scope, which is what makes deleting one more consequential than it looks.
struct FolderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folder",
        abstract: "Folders, which are also vocabulary scopes.",
        subcommands: [FolderList.self, FolderCreate.self, FolderDelete.self],
        defaultSubcommand: FolderList.self
    )
}

struct FolderList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List folders with what is in them."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let folders = try context.store.folders().map { folder in
                FolderJSON(
                    name: folder.name,
                    id: folder.id,
                    meetings: try context.store.meetings(folderID: folder.id).count,
                    vocabulary: try context.store.vocabularyTerms(folderID: folder.id).count
                )
            }
            let unfiled = try context.store.meetings(folderID: nil).count

            if global.json {
                try Out.json(FolderListJSON(folders: folders, unfiled: unfiled))
                return
            }
            guard !folders.isEmpty else {
                Out.note("No folders yet. Make one with meetings folder create <name>.")
                return
            }
            Out.line(Format.columns(folders.map { folder in
                ["\(folder.meetings)", "\(folder.vocabulary) terms", folder.name]
            } + [["\(unfiled)", "-", "(unfiled)"]]).joined(separator: "\n"))
        }
    }
}

struct FolderCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a folder."
    )

    @Argument(help: "The folder name. Names are unique, ignoring case.")
    var name: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CLIError.usage("A folder needs a name.") }
            let context = try CLIContext.open()
            // A duplicate name surfaces as StoreError.invalidState, which is exit 3 — the folder is
            // a legal thing to want, it just already exists.
            let folder = try context.store.createFolder(Folder(name: trimmed))

            if global.json {
                try Out.json(FolderJSON(name: folder.name, id: folder.id, meetings: 0, vocabulary: 0))
                return
            }
            Out.line("Created folder \(folder.name)")
        }
    }
}

struct FolderDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a folder.",
        discussion: """
            A folder holding meetings is not deleted without --force. Its meetings survive as \
            unfiled, but its folder-scoped vocabulary is deleted with it and cannot be undone. \
            --force says exactly what it removed.
            """
    )

    @Argument(help: "The folder name.")
    var name: String

    @Flag(name: .long, help: "Delete it anyway: meetings become unfiled, scoped vocabulary is deleted.")
    var force = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            guard let folder = try context.store.folder(named: name) else {
                throw CLIError.notFound("No folder named \(name)")
            }
            let meetings = try context.store.meetings(folderID: folder.id)
            let terms = try context.store.vocabularyTerms(folderID: folder.id)

            // The asymmetry is the reason this refuses rather than just doing it: `folder_id` on a
            // meeting is ON DELETE SET NULL, so the meetings are recoverable — they turn up in
            // Unfiled and can be moved back. Vocabulary is ON DELETE CASCADE, so a folder's jargon
            // is gone for good, and it is the part nobody notices until transcripts quietly get
            // worse. So say what will go, and make the caller say it is fine.
            if !force, !meetings.isEmpty || !terms.isEmpty {
                throw CLIError.invalidState("""
                    \(folder.name) still holds \(count(meetings.count, "meeting")) and \
                    \(count(terms.count, "vocabulary term")). Deleting it makes those meetings \
                    unfiled and removes those terms permanently. Pass --force if that is what you \
                    want, or move the meetings first with meetings move <ref> --folder <name>.
                    """)
            }
            _ = try context.store.deleteFolder(id: folder.id)

            if global.json {
                try Out.json(FolderDeleteJSON(
                    deleted: folder.name,
                    meetingsUnfiled: meetings.count,
                    vocabularyDeleted: terms.count
                ))
                return
            }
            Out.line("Deleted folder \(folder.name). \(count(meetings.count, "meeting")) now unfiled, "
                + "\(count(terms.count, "vocabulary term")) removed")
        }
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

private struct FolderListJSON: Encodable {
    let folders: [FolderJSON]
    /// Meetings with no folder. Not a folder itself — there is no row for it — but the sidebar and
    /// every listing treat it as one, so an agent should be able to see the count.
    let unfiled: Int
}

private struct FolderDeleteJSON: Encodable {
    let deleted: String
    let meetingsUnfiled: Int
    let vocabularyDeleted: Int
}
