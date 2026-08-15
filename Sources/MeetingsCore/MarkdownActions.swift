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
    ///
    /// **Anywhere except inside a fenced code block** — see ``scanned(_:)``.
    public static func parse(_ markdown: String) -> [Action] {
        scanned(markdown).compactMap { $0.fenced ? nil : action(in: $0.text) }
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
        scanned(markdown).contains { !$0.fenced && taskItem($0.text) != nil }
    }

    /// The document with its task list rewritten to `actions`, and **nothing else touched**.
    ///
    /// This is what `meetings actions set` does now that the write-up is the record, and the rule it
    /// has to obey is that the rest of the write-up survives: an agent replacing three action items
    /// must not take the decisions and the open questions with them.
    ///
    /// **Each item is rewritten where it stands.** The nth *action* of the document becomes the nth
    /// action sent, in place, keeping its own indentation, list marker and spacing; a shorter list
    /// deletes the leftover lines and a longer one adds its extras after the last existing item.
    /// Collecting every match at the position of the first one looked equivalent and was not —
    /// ``parse(_:)`` reads task items from anywhere in the document, so a nested sub-checklist, or
    /// one the author typed under "Open questions", was hoisted into the Actions block and flattened
    /// to top level by ``rendered(_:)``. That is structure the user typed, and `actions set` does not
    /// own it.
    ///
    /// **Positions are counted the way ``parse(_:)`` counts them**, so an empty half-typed `- [ ]` is
    /// skipped rather than numbered. `actions list` never showed it, and the docs tell an agent to
    /// send items in the order that command gave them — counting boxes here instead meant one box the
    /// user was in the middle of typing shifted every action after it by one, and the agent's third
    /// item landed on the user's fourth. Skipped means untouched: the line stays exactly as typed.
    ///
    /// Rewriting positionally is also what makes the round trip safe: `actions list` reads every
    /// action in the document, so writing that same list straight back reproduces the document —
    /// byte for byte, including the author's own spacing — rather than rearranging it.
    ///
    /// With no actions in the document already, the list is appended to the document's `## Actions`
    /// section, or under a new heading when it has none — see ``appending(_:to:)``, which is the
    /// same operation the store migration runs.
    ///
    /// A checkbox inside a fenced code block is neither counted nor rewritten, exactly as
    /// ``parse(_:)`` does not report one: the two have to agree on positions or the agent's nth item
    /// lands on the user's n+1th line.
    public static func replace(_ actions: [Action], in markdown: String) -> String {
        let scanned = scanned(markdown)
        let lines = scanned.map(\.text)
        let items = lines.indices.filter { !scanned[$0].fenced && action(in: lines[$0]) != nil }
        guard let last = items.last else { return appending(actions, to: markdown) }
        let list = meaningful(actions)

        // nil means "leave the line alone"; an empty array means "the item that was here is gone".
        var rewritten: [Int: [String]] = [:]
        for (position, index) in items.enumerated() {
            rewritten[index] = position < list.count ? [written(list[position], like: lines[index])] : []
        }
        if list.count > items.count {
            // A brand-new action is a top-level action. Writing the extras like the last line put
            // them at whatever indentation and marker that line happened to have — so a document
            // whose final checkbox is a nested sub-item, or one under "## Open questions", turned
            // every new action into a child of it. The one thing the last line does earn is its own
            // list style, when it is itself top level: appending a `*` item to a `*` list.
            let indented = lines[last].first.map { $0 == " " || $0 == "\t" } ?? false
            rewritten[last, default: []] += list[items.count...].map {
                indented ? rendered($0) : written($0, like: lines[last])
            }
        }
        return lines.indices.flatMap { rewritten[$0] ?? [lines[$0]] }.joined(separator: "\n")
    }

    /// One action written as a task item, wearing the indentation, list marker and spacing of the
    /// line it is replacing — `  * [ ] x` stays two spaces in and a `*`, and `- [x]done` stays closed
    /// up, because the shape of the list is the author's and only the tick and the sentence belong to
    /// `actions set`. Reflowing the gap to one space was a diff on a line nobody asked to change,
    /// and it broke the identity `replace(parse(doc), in: doc) == doc` on every shape the editor
    /// draws a box on but GFM spells differently.
    private static func written(_ action: Action, like line: String) -> String {
        guard let item = taskItem(line) else { return rendered(action) }
        let characters = Array(line)
        return String(characters[..<item.box.lowerBound]) + "[\(action.done ? "x" : " ")]"
            + String(characters[item.box.upperBound..<item.textStart]) + action.text
    }

    /// The actions added to the document's `## Actions` section, or under a new heading at the end
    /// of it when the document has no such section.
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
    ///
    /// **A document that already has an `## Actions` heading gets its items under that one**, at the
    /// end of the section, rather than a second heading of the same name at the bottom of the file.
    /// 0.1.2's own `SKILL.md` handed agents the template `## What we decided / ## Actions / ## Open
    /// questions / ## Not covered` *and* told them to call `meetings actions set`, so the documented
    /// old workflow produces exactly the store this runs over: prose bullets under one heading and
    /// the same commitments in the column. Appending unconditionally gave those write-ups two
    /// sections called Actions, permanently, in a pass with no second chance at it.
    ///
    /// **The author's whitespace is not edited.** This used to trim the whole document before
    /// appending to it, which silently rewrote leading and trailing whitespace on every write-up the
    /// migration touched — including the two trailing spaces that are markdown's hard line break.
    /// Only the separator between the write-up and a newly added heading is computed, and only from
    /// how many newlines the document already ends with.
    public static func appending(_ actions: [Action], to markdown: String) -> String {
        var present = Dictionary(parse(markdown).map { ($0.text, 1) }, uniquingKeysWith: +)
        let missing = meaningful(actions).filter { action in
            guard let count = present[action.text], count > 0 else { return true }
            present[action.text] = count - 1
            return false
        }
        guard !missing.isEmpty else { return markdown }
        let items = missing.map(rendered(_:))

        let scanned = scanned(markdown)
        if let heading = scanned.indices.last(where: {
            !scanned[$0].fenced && headingLevel(scanned[$0].text, named: "Actions") != nil
        }) {
            var lines = scanned.map(\.text)
            let point = endOfSection(opening: heading, in: scanned)
            // An `## Actions` with nothing under it yet gets the blank line this writes for a heading
            // of its own, so the two shapes read the same.
            lines.insert(contentsOf: point == heading + 1 ? [""] + items : items, at: point)
            return lines.joined(separator: "\n")
        }

        let block = "## Actions\n\n" + items.joined(separator: "\n")
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return block }
        let trailing = markdown.reversed().prefix { $0 == "\n" }.count
        return markdown + String(repeating: "\n", count: max(0, 2 - trailing)) + block
    }

    /// The line the section opened at `heading` ends on: past everything written under it, before the
    /// blank lines separating it from the next heading of the same level or higher.
    private static func endOfSection(opening heading: Int, in scanned: [(text: String, fenced: Bool)]) -> Int {
        let level = headingLevel(scanned[heading].text) ?? 2
        var end = scanned.count
        for index in (heading + 1)..<scanned.count
        where !scanned[index].fenced && (headingLevel(scanned[index].text).map { $0 <= level } ?? false) {
            end = index
            break
        }
        var point = end
        while point > heading + 1, scanned[point - 1].text.trimmingCharacters(in: .whitespaces).isEmpty {
            point -= 1
        }
        return point
    }

    // MARK: - The little of the document's shape this has to know

    /// The document's lines, each carrying whether it sits inside a fenced code block.
    ///
    /// **A checkbox inside a fence is not an action**, and reading one as an action broke two things
    /// at once. The engine renders that line as code and draws no box, so `meetings actions list`
    /// reported a commitment the app has nowhere to tick — the exact seam divergence the write-up-is-
    /// the-record design exists to remove. And it counted towards ``appending(_:to:)``'s already-
    /// present tally, so a real column action reading `follow up with Sam` was matched by a
    /// `- [ ] follow up with Sam` sitting in a pasted snippet and was never migrated at all.
    ///
    /// **Block quotes need no rule of their own.** A quoted line begins with `>` before any list
    /// marker, and ``taskItem(_:)`` reads `>` as neither a bullet nor a number, so `> - [ ] x` is
    /// already not an action — and the engine draws no box on it either. That agreement is pinned in
    /// the seam probe rather than asserted here.
    ///
    /// This is the only markdown structure this file knows beyond the task item itself, and it is
    /// here for the same reason ``taskItem(_:)`` is: it is what the CLI has to read out of somebody's
    /// write-up, and the engine's answer is the one it is held to.
    ///
    /// **A fence is what the engine calls a fence, which is narrower than CommonMark**, and the
    /// boundary was measured rather than assumed — `MarkdownActionsTests` renders each of these and
    /// counts the boxes it draws:
    ///
    /// - Backticks only. `~~~` is not a fence to the engine, so a checkbox between two of them is a
    ///   real, clickable box and therefore a real action.
    /// - Three or more, at column zero. A leading space is not a fence; neither is a four-space
    ///   indented block, which the engine does not read as code either.
    /// - Any fence line closes an open one, whatever its length and whatever follows it, so
    ///   ` ```swift ` closes and a shorter run closes a longer one.
    /// - **An opening fence never closed fences nothing at all.** The engine renders the rest of the
    ///   document as ordinary markdown, boxes and all, rather than swallowing it to the end.
    ///
    /// Following the engine into all four rather than being stricter is the same call the rest of
    /// this file already made: the box on screen is the thing the user pressed, so the box on screen
    /// is the action.
    static func scanned(_ markdown: String) -> [(text: String, fenced: Bool)] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fenced = [Bool](repeating: false, count: lines.count)
        var open: Int?
        for index in lines.indices where lines[index].prefix(while: { $0 == "`" }).count >= 3 {
            guard let start = open else {
                open = index
                continue
            }
            for inside in start...index { fenced[inside] = true }
            open = nil
        }
        // `open` non-nil here is an unclosed fence, and it is left as prose deliberately — see above.
        return lines.indices.map { (text: lines[$0], fenced: fenced[$0]) }
    }

    /// An ATX heading's level, or nil for a line that is not one. With `named:`, only a heading whose
    /// own text is that word — `## Actions`, at whatever level and in whatever case the author wrote.
    private static func headingLevel(_ text: String, named: String? = nil) -> Int? {
        let characters = Array(text)
        let indent = characters.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let level = characters[indent...].prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = characters[(indent + level)...]
        guard after.first.map({ $0 == " " || $0 == "\t" }) ?? true else { return nil }
        guard let named else { return level }
        let title = String(after).trimmingCharacters(in: CharacterSet(charactersIn: " \t#"))
        return title.caseInsensitiveCompare(named) == .orderedSame ? level : nil
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
    /// The loosening admits one shape worth naming: `- [x](https://example.com/report)`, a list item
    /// whose *link label* is `x`. The engine draws a ticked, clickable checkbox on it and renders the
    /// rest as a link — measured, not assumed, and pinned in the probe set — so this reads it as a
    /// done action with the text `(https://example.com/report)`. That is the rule working: the user
    /// can tick that box, and a box the user can tick is an action.
    ///
    /// The two parsers agree on every shape probed, quotes and malformed boxes included. Nothing
    /// makes them agree by construction, which is why the test drives the engine rather than trusting
    /// this comment.
    ///
    /// **A line is not the whole probe.** This function reads one line and cannot see a fenced code
    /// block, which is a construct the engine most certainly does see — a `- [ ] follow up with Sam`
    /// inside a pasted snippet was an action to the CLI and no box at all on screen. That is
    /// ``scanned(_:)``'s job, and the boundary between the engine's idea of a fence and CommonMark's
    /// is recorded there, measured the same way.
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
