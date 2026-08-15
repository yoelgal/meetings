import ArgumentParser
import Foundation
import MeetingsCore

/// Actions are **task list items inside the write-up** — `- [ ] anchor live notes` — and these two
/// commands are the structured view of them. Nothing here is a second store: `set` rewrites the task
/// items inside the summary markdown and leaves the rest of the write-up exactly as it found it, and
/// `list` reads the task items back out. One record, so the window and the command line cannot
/// disagree about what is owed.
struct ActionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "actions",
        abstract: "The task list inside a write-up, as data.",
        subcommands: [ActionsSet.self, ActionsList.self],
        defaultSubcommand: ActionsList.self
    )
}

struct ActionsSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Replace the task list inside a meeting's write-up.",
        discussion: """
            Takes a JSON array of {text, owner?, due?, done?} as an argument, as --file <path>, \
            or as - to read stdin. text is required and done defaults to false.

            The actions are stored as GFM task list items in the write-up itself, so this rewrites \
            the `- [ ]` lines of the summary and leaves every other line of it alone. The nth item \
            you send rewrites the nth one in the document, where it stands and with its own \
            indentation, so send them in the order `actions list` gave them; extras land after the \
            last one and leftovers are deleted. With no task list there yet, one is appended under \
            an "## Actions" heading. An empty array removes the task items and nothing else.

            owner and due are accepted and echoed back in --json, but the markdown has nowhere to \
            put them yet, so neither is stored: --json names them in droppedFields when you send \
            one. Write the owner into the text if it matters.
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

            // Through `setSummary`, so a write-up that comes into existence as nothing but its
            // action list moves the meeting on exactly as any other write-up would.
            let updated = try context.store.updateMeeting(id: target.id) { meeting in
                meeting.setSummary(MarkdownActions.replace(actions, in: meeting.summary ?? ""))
            }
            let folder = try updated.folderID.flatMap { try context.store.folder(id: $0)?.name }
            let stored = MarkdownActions.parse(updated.summary ?? "")

            // Said once, on the write that would have dropped them, rather than left for the user to
            // notice missing from `actions list` a week later. Worked out before the `--json` branch
            // and reported inside it: `--json` is the agent-facing path, and an agent that sent an
            // owner got back the reparsed markdown with `"owner": null` and nothing to distinguish
            // "you asked for no owner" from "the owner you sent went nowhere".
            var dropped: [String] = []
            if actions.contains(where: { $0.owner != nil }) { dropped.append("owner") }
            if actions.contains(where: { $0.due != nil }) { dropped.append("due") }

            if global.json {
                var result = WriteResultJSON(updated, folder: folder, materialised: materialised)
                result.actions = stored
                result.droppedFields = dropped.isEmpty ? nil : dropped
                try Out.json(result)
                return
            }
            if !dropped.isEmpty {
                Out.note("owner and due are not stored yet — the write-up carries the text only.")
            }
            let open = stored.filter { !$0.done }.count
            Out.line("\(stored.count) action\(stored.count == 1 ? "" : "s") on \(updated.id), "
                + "\(open) open (\(updated.title))")
        }
    }
}

struct ActionsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Action items across every meeting.",
        discussion: """
            Read out of each write-up's task list. Newest meeting first. Columns are ref, [x] or \
            [ ], owner, due, then the text, so the ref is still the first field and the listing \
            pipes into another command. owner and due are always - for now: the markdown does not \
            carry them.
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

            // ponytail: every summary is parsed in Swift. A personal store holds thousands of rows,
            // not millions, and the parse is one pass per line; when that stops being true this
            // becomes an FTS query for `- [` and a parse of the hits.
            var items: [ActionItemJSON] = []
            for meeting in meetings {
                let folderName = meeting.folderID.flatMap { names[$0] }
                for action in MarkdownActions.parse(meeting.summary ?? "") where !open || !action.done {
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
