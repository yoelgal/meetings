import Foundation

/// Actions, read out of the write-up rather than out of a column beside it.
///
/// **The write-up is the record.** An action is a GFM task list item in the summary markdown —
/// `- [ ] anchor live notes to system audio` — so creating one is typing a line, ticking one is
/// changing a character, and deleting one is deleting the line. There is no second structure to
/// keep in step with the document somebody is reading, which is what the `actions` JSON column was
/// and why ticking a box in the window could disagree with what `meetings actions set` had written.
///
/// It lives beside ``MarkdownSyntax`` for the same reason that does: what counts as an action is a
/// pure function over a string, and it is asked by the CLI, the app and the store migration alike.
///
/// **Owner and due are not represented here yet.** ``Action`` still carries them — the JSON shape
/// the CLI emits has not changed — but nothing writes them into the markdown and nothing reads them
/// back, so an action parsed out of a write-up always has `owner` and `due` nil. A trailing
/// convention (`@Yoel`, `📅2026-08-16`) is the obvious next move, and until there is a real
/// requirement for one, guessing at its syntax would put characters into somebody's documents that
/// a later parser has to cope with. An unparsed `@foo` in the text of an action is harmless; a
/// half-supported convention is not.
public enum MarkdownActions {
    /// Every task list item in the document, in the order it appears.
    ///
    /// Anywhere in the document, not only under a heading called Actions: the heading is prose, and
    /// a checkbox somebody typed in the middle of a paragraph of decisions is still something they
    /// owe. `meetings actions list --open` is the whole reason this is a list rather than a render.
    public static func parse(_ markdown: String) -> [Action] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap(action(in:))
    }

    /// One line's action, or nil if the line is not a task list item.
    public static func action(in line: some StringProtocol) -> Action? {
        guard let item = MarkdownSyntax.taskItem(line) else { return nil }
        let text = String(Array(line)[item.textStart...]).trimmingCharacters(in: .whitespaces)
        // A box with nothing after it is an item being typed, not something anybody owes.
        guard !text.isEmpty else { return nil }
        return Action(text: text, done: item.done)
    }

    /// The markdown line one action is written as. The inverse of ``action(in:)``: parsing a
    /// canonical task item and rendering it again reproduces the line exactly.
    public static func rendered(_ action: Action) -> String {
        "- [\(action.done ? "x" : " ")] \(action.text)"
    }

    /// Whether any line of the document is a task list item.
    public static func carriesActions(_ markdown: String) -> Bool {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { MarkdownSyntax.taskItem($0) != nil }
    }

    /// The document with its task list rewritten to `actions`, and **nothing else touched**.
    ///
    /// This is what `meetings actions set` does now that the write-up is the record, and the rule it
    /// has to obey is that the rest of the write-up survives: an agent replacing three action items
    /// must not take the decisions and the open questions with them. So the existing task items are
    /// removed line by line, the new list goes in where the first of them was, and every other line
    /// of the document is left exactly as it was found.
    ///
    /// With no task items in the document already, the list is appended under an `## Actions`
    /// heading — see ``appending(_:to:)``, which is the same operation the store migration runs.
    public static func replace(_ actions: [Action], in markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.firstIndex(where: { MarkdownSyntax.taskItem($0) != nil }) else {
            return appending(actions, to: markdown)
        }
        let list = actions.map(rendered(_:))
        var rebuilt: [String] = []
        for (index, existing) in lines.enumerated() {
            if index == first { rebuilt.append(contentsOf: list) }
            if MarkdownSyntax.taskItem(existing) == nil { rebuilt.append(existing) }
        }
        return rebuilt.joined(separator: "\n")
    }

    /// The actions added to the end of the document under an `## Actions` heading.
    ///
    /// **Idempotent**, and that is the point: it is what the store migration runs over every meeting
    /// that has actions in the old column, and running it twice must not leave two copies. A
    /// document that already carries task items is returned untouched — it has actions in it
    /// already, whatever else it says.
    public static func appending(_ actions: [Action], to markdown: String) -> String {
        guard !actions.isEmpty, !carriesActions(markdown) else { return markdown }
        let block = "## Actions\n\n" + actions.map(rendered(_:)).joined(separator: "\n")
        let existing = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? block : existing + "\n\n" + block
    }
}
