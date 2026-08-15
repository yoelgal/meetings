import Foundation

/// Actions, read out of the write-up rather than out of a column beside it.
///
/// **The write-up is the record.** An action is a GFM task list item in the summary markdown —
/// `- [ ] anchor live notes to system audio` — so creating one is typing a line, ticking one is
/// changing a character, and deleting one is deleting the line. There is no second structure to
/// keep in step with the document somebody is reading, which is what the `actions` JSON column was
/// and why ticking a box in the window could disagree with what `meetings actions set` had written.
///
/// It lives in `MeetingsCore` because what counts as an action is a pure function over a string, and
/// it is asked by the CLI, the app and the store migration alike.
///
/// This file used to sit beside a `MarkdownSyntax` enum that classified lines, found inline runs and
/// measured a gutter for the hand-built editor. That editor is gone — `swift-markdown-engine` owns
/// the document, its styling and its checkbox — and with it every one of those functions. What
/// survived is ``taskItem(_:)``, which is not a markdown parser: it is this file's own definition of
/// the one construct the CLI reads back out of a write-up, and it now lives where that definition
/// belongs.
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
        guard let item = taskItem(line) else { return nil }
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

    /// The actions worth writing a line for.
    ///
    /// **An action with no text is not an action**, and ``action(in:)`` has always said so on the
    /// way in — it refuses to parse `- [ ]` as something anybody owes. This is the same rule on the
    /// way out, and without it the two disagreed in a way that showed: an `Action` carrying an empty
    /// text rendered as `- [ ] ` and landed at the end of somebody's action list as a checkbox with
    /// nothing beside it. Worse, ``appending(_:to:)``'s idempotency is `parse`-based, and `parse`
    /// cannot see the line it just wrote — so every re-run of the migration added another one.
    ///
    /// `ActionsInput` rejects an empty text, so this is not the CLI's path; it is the store
    /// migration's, which decodes the legacy `actions` column with `JSONDecoder` and validates
    /// nothing, and any other caller holding an `Action` it did not parse from markdown.
    ///
    /// **This never touches a line already in the document.** A `- [ ]` somebody typed into their
    /// write-up is theirs — the item they are in the middle of writing — and nothing here reads or
    /// rewrites it. Only actions arriving from outside the markdown are filtered.
    private static func meaningful(_ actions: [Action]) -> [Action] {
        actions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Whether any line of the document is a task list item.
    public static func carriesActions(_ markdown: String) -> Bool {
        markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { taskItem($0) != nil }
    }

    /// The document with its task list rewritten to `actions`, and **nothing else touched**.
    ///
    /// This is what `meetings actions set` does now that the write-up is the record, and the rule it
    /// has to obey is that the rest of the write-up survives: an agent replacing three action items
    /// must not take the decisions and the open questions with them.
    ///
    /// **Each item is rewritten where it stands.** The nth task item of the document becomes the nth
    /// action, in place, keeping its own indentation and list marker; a shorter list deletes the
    /// leftover lines and a longer one adds its extras after the last existing item. Collecting
    /// every match at the position of the first one looked equivalent and was not — ``parse(_:)``
    /// reads task items from anywhere in the document, so a nested sub-checklist, or one the author
    /// typed under "Open questions", was hoisted into the Actions block and flattened to top level
    /// by ``rendered(_:)``. That is structure the user typed, and `actions set` does not own it.
    ///
    /// Rewriting positionally is also what makes the round trip safe: `actions list` reads every
    /// task item in the document, so writing that same list straight back has to reproduce the
    /// document rather than rearrange it.
    ///
    /// With no task items in the document already, the list is appended under an `## Actions`
    /// heading — see ``appending(_:to:)``, which is the same operation the store migration runs.
    public static func replace(_ actions: [Action], in markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let items = lines.indices.filter { taskItem(lines[$0]) != nil }
        guard let last = items.last else { return appending(actions, to: markdown) }
        let list = meaningful(actions)

        // nil means "leave the line alone"; an empty array means "the item that was here is gone".
        var rewritten: [Int: [String]] = [:]
        for (position, index) in items.enumerated() {
            rewritten[index] = position < list.count ? [written(list[position], like: lines[index])] : []
        }
        if list.count > items.count {
            rewritten[last, default: []] += list[items.count...].map { written($0, like: lines[last]) }
        }
        return lines.indices.flatMap { rewritten[$0] ?? [lines[$0]] }.joined(separator: "\n")
    }

    /// One action written as a task item, wearing the indentation and list marker of the line it is
    /// replacing — `  * [ ] x` stays two spaces in and a `*`, because the shape of the list is the
    /// author's and only the box and the sentence belong to `actions set`.
    private static func written(_ action: Action, like line: String) -> String {
        guard let item = taskItem(line) else { return rendered(action) }
        return String(Array(line)[..<item.box.lowerBound]) + "[\(action.done ? "x" : " ")] \(action.text)"
    }

    /// The actions added to the end of the document under an `## Actions` heading.
    ///
    /// **Idempotent**, and that is the point: it is what the store migration runs over every meeting
    /// that has actions in the old column, and running it twice must not leave two copies.
    ///
    /// Idempotency is per *action*, not per document, and that distinction is the whole of this
    /// function's correctness. Skipping any document that already carried a task item looked
    /// equivalent and was not: a write-up with one unrelated checkbox anywhere in it — a stray
    /// `- [ ] hello`, a checklist the author typed themselves — silenced the migration for that
    /// meeting entirely, and since nothing reads the old column afterwards, every real action on it
    /// vanished from the app while still sitting in the row. Matching on the text instead means an
    /// already-migrated action is skipped and an un-migrated one is never lost.
    ///
    /// Matching is by *count*, not by presence: a meeting whose old column held `- [ ] follow up`
    /// twice — two real commitments that happened to be typed the same way — gets two lines, and a
    /// re-run then finds two already there and adds neither. A `Set` of the texts collapsed the pair
    /// into one line and lost a commitment where nothing would ever surface the loss.
    public static func appending(_ actions: [Action], to markdown: String) -> String {
        var present = Dictionary(parse(markdown).map { ($0.text, 1) }, uniquingKeysWith: +)
        let missing = meaningful(actions).filter { action in
            guard let count = present[action.text], count > 0 else { return true }
            present[action.text] = count - 1
            return false
        }
        guard !missing.isEmpty else { return markdown }
        let block = "## Actions\n\n" + missing.map(rendered(_:)).joined(separator: "\n")
        let existing = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? block : existing + "\n\n" + block
    }

    // MARK: - What a task item is

    /// One **GFM task list item**: `- [ ] text`, `* [x] text`, `+ [ ] text`, `1. [ ] text`, at any
    /// indentation, with the `x` in either case.
    ///
    /// This is the offsets half of ``action(in:)`` — where the box is and where the sentence starts —
    /// and it is separate from it because a box with no text is still a box: the app has to be able
    /// to see the item somebody is half-way through typing, and `action(in:)` deliberately cannot.
    public struct TaskItem: Equatable, Sendable {
        /// `[x]` or `[X]` rather than `[ ]`.
        public let done: Bool
        /// The three characters of the box, as character offsets into the line. This is what a
        /// checkbox is drawn over, and `box.lowerBound + 1` is the one character a tick changes.
        public let box: Range<Int>
        /// Where the item's own text begins — past the box and the whitespace after it.
        public let textStart: Int

        public init(done: Bool, box: Range<Int>, textStart: Int) {
            self.done = done
            self.box = box
            self.textStart = textStart
        }
    }

    /// **The seam with the editor.** `swift-markdown-engine` decides independently which lines get a
    /// drawn checkbox, and a line it ticks that this rejects is a box the user can click that
    /// `meetings actions list` never shows. `MarkdownActionsTests` drives the engine's own parse
    /// against this function to keep the two in step; where they cannot agree, this comment says
    /// which side wins.
    ///
    /// **The engine wins**, and two rules moved to make that true. This was GFM-strict where the
    /// engine is not: it demanded a space between the list marker and the box (a tab would do in the
    /// engine) and whitespace or end-of-line *after* the box (the engine wants neither). So
    /// `- [x]done` and `-\t[ ] x` were both drawn with a clickable checkbox and both invisible to
    /// `meetings actions list`. Strictness is the wrong instinct here: the box on screen is the thing
    /// the user pressed, so the box on screen is the action.
    ///
    /// The two parsers now agree on every shape probed, quotes and malformed boxes included. Nothing
    /// makes them agree by construction, which is why the test drives the engine rather than trusting
    /// this comment.
    public static func taskItem(_ line: some StringProtocol) -> TaskItem? {
        let characters = Array(line)
        let indent = characters.prefix { $0 == " " || $0 == "\t" }.count
        let rest = characters[indent...]
        guard let first = rest.first else { return nil }

        var end: Int
        if first == "-" || first == "*" || first == "+" {
            end = indent + 1
        } else {
            let digits = rest.prefix(while: \.isNumber).count
            guard digits > 0, digits <= 3, indent + digits < characters.count,
                  characters[indent + digits] == "." || characters[indent + digits] == ")"
            else { return nil }
            end = indent + digits + 1
        }
        // The list marker's own whitespace, then the box.
        guard end < characters.count, characters[end] == " " || characters[end] == "\t" else { return nil }
        let box = end + 1
        guard box + 2 < characters.count, characters[box] == "[", characters[box + 2] == "]"
        else { return nil }
        let done: Bool
        switch characters[box + 1] {
        case " ": done = false
        case "x", "X": done = true
        default: return nil
        }
        var text = box + 3
        while text < characters.count, characters[text] == " " || characters[text] == "\t" { text += 1 }
        return TaskItem(done: done, box: box..<(box + 3), textStart: text)
    }
}
