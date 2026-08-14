import ArgumentParser
import Foundation
import MeetingsCore

/// Actions are a structured field rather than a heading inside the summary, and that is the whole
/// point: `meetings actions list --open` answers "what do I owe anyone" without parsing prose
///.
struct ActionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "actions",
        abstract: "Action items, as data rather than as prose.",
        subcommands: [ActionsSet.self, ActionsList.self],
        defaultSubcommand: ActionsList.self
    )
}

struct ActionsSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Replace a meeting's action items.",
        discussion: """
            Takes a JSON array of {text, owner?, due?, done?} as an argument, as --file <path>, \
            or as - to read stdin. text is required, done defaults to false, and due is free text \
            like "end of week".

            An empty array clears the list.
            """
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Argument(help: "The JSON array, or - to read stdin.")
    var text: String?

    @Option(name: .long, help: "Read the JSON from this file instead.")
    var file: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            // Parsed before anything is opened or materialised: a malformed array must not leave a
            // freshly created row behind with nothing written to it.
            let actions = try ActionsInput.parse(TextInput.read(text, file: file, what: "the actions JSON"))
            let context = try CLIContext.open()
            let (target, materialised) = try await context.writeTarget(ref)

            let updated = try context.store.updateMeeting(id: target.id) { meeting in
                meeting.actions = actions.isEmpty ? nil : actions
            }
            let folder = try updated.folderID.flatMap { try context.store.folder(id: $0)?.name }

            if global.json {
                var result = WriteResultJSON(updated, folder: folder, materialised: materialised)
                result.actions = updated.actions ?? []
                try Out.json(result)
                return
            }
            let open = actions.filter { !$0.done }.count
            Out.line("\(actions.count) action\(actions.count == 1 ? "" : "s") on \(updated.id), "
                + "\(open) open (\(updated.title))")
        }
    }
}

struct ActionsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Action items across every meeting.",
        discussion: """
            Newest meeting first. Columns are ref, [x] or [ ], owner, due, then the text, so the \
            ref is still the first field and the listing pipes into another command.
            """
    )

    @Flag(name: .long, help: "Only the ones that are not done.")
    var open = false

    @Option(name: .long, help: "Only meetings in this folder.")
    var folder: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let names = try context.folderNames()
            let scope = try context.folder(named: folder)
            let meetings = scope == nil
                ? try context.store.allMeetings()
                : try context.store.meetings(folderID: scope?.id)

            // ponytail: filtered in Swift over every meeting. A personal store holds thousands of
            // rows, not millions; when it doesn't, this becomes a WHERE actions IS NOT NULL.
            var items: [ActionItemJSON] = []
            for meeting in meetings {
                let folderName = meeting.folderID.flatMap { names[$0] }
                for action in meeting.actions ?? [] where !open || !action.done {
                    items.append(ActionItemJSON(action, meeting: meeting, folder: folderName))
                }
            }

            if global.json {
                try Out.json(ActionsListJSON(open: open, actions: items))
                return
            }
            guard !items.isEmpty else {
                Out.note(open ? "Nothing open." : "No actions recorded yet.")
                return
            }
            Out.line(Format.columns(items.map { item in
                [
                    item.ref,
                    item.done ? "[x]" : "[ ]",
                    item.owner ?? "-",
                    item.due ?? "-",
                    Format.oneLine(item.text),
                ]
            }).joined(separator: "\n"))
        }
    }
}

private struct ActionsListJSON: Encodable {
    let open: Bool
    let actions: [ActionItemJSON]
}
