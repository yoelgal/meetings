import Foundation

/// The half of the write-up editor that is a *rule* rather than a typeface: what a keystroke should
/// do to the text around it.
///
/// It lives beside ``MarkdownSyntax`` and for the same reason — `MeetingsApp` is an executable
/// target with no tests behind it, and "Return at the end of a bullet continues the list" is logic.
/// Everything here is a pure function over a `String` and a caret, so the view has one job left:
/// hand over the document, apply the edit it gets back, and put the selection where it says.
///
/// **Character offsets throughout**, never UTF-8 or UTF-16 ones. The editor turns them into
/// `AttributedString.Index`es with `offsetByCharacters`, and a count taken in the wrong unit is how
/// a caret lands mid-emoji.
public enum MarkdownEditing {
    /// One replacement, and where the selection ends up once it has been applied. An empty
    /// `selection` is a caret.
    public struct Edit: Equatable, Sendable {
        public let range: Range<Int>
        public let replacement: String
        public let selection: Range<Int>

        public init(range: Range<Int>, replacement: String, selection: Range<Int>) {
            self.range = range
            self.replacement = replacement
            self.selection = selection
        }

        /// Applying it, for tests and for anything that holds a plain string.
        public func applied(to text: String) -> String {
            var characters = Array(text)
            characters.replaceSubrange(range, with: replacement)
            return String(characters)
        }
    }

    // MARK: - What a keystroke earns

    /// The follow-up edit one keystroke earns, or nil for the overwhelming majority that earn none.
    ///
    /// Deliberately driven by **what the text became**, not by intercepting the key. A `TextEditor`
    /// is an `NSTextView` and Return and Delete are its own; fighting it for them means a second
    /// input path that disagrees with the first about undo, dead keys and input methods. Comparing
    /// the document either side of a keystroke costs one diff and cannot disagree with anything.
    public static func followUp(before: String, after: String, caret: Int) -> Edit? {
        let old = Array(before)
        let new = Array(after)
        if new.count == old.count + 1 {
            guard caret >= 1, caret <= new.count else { return nil }
            switch new[caret - 1] {
            case "\n": return listContinuation(new, caret: caret)
            case " ": return shorthand(new, caret: caret)
            default: return nil
            }
        }
        if new.count == old.count - 1 {
            return markerBackspace(old, caret: caret)
        }
        return nil
    }

    /// Return was pressed at the end of a list item. A fresh marker if the item had content, and
    /// the marker taken away if it did not — pressing Return twice is how everybody ends a list,
    /// and an editor that answers it with a third empty bullet is one you fight.
    private static func listContinuation(_ characters: [Character], caret: Int) -> Edit? {
        let end = caret - 1
        let start = lineStart(characters, before: end)
        let line = String(characters[start..<end])
        guard MarkdownSyntax.line(line) == .bullet,
              let marker = MarkdownSyntax.blockMarker(line)
        else { return nil }

        let characters0 = Array(line)
        let content = String(characters0[marker.upperBound...])
        guard content.contains(where: { !$0.isWhitespace }) else {
            // The empty item and the newline it just produced both go, which leaves the caret on a
            // blank line exactly where the bullet was.
            return Edit(range: start..<caret, replacement: "", selection: start..<start)
        }
        let indent = String(characters0[0..<marker.lowerBound])
        let next = indent + nextMarker(String(characters0[marker]))
        return Edit(
            range: caret..<caret,
            replacement: next,
            selection: (caret + next.count)..<(caret + next.count)
        )
    }

    /// The marker the item after this one gets. Ordered lists count on; a ticked box comes back
    /// unticked, because the next thing you write is not already done.
    static func nextMarker(_ marker: String) -> String {
        let digits = marker.prefix(while: \.isNumber)
        if !digits.isEmpty, let number = Int(digits) {
            return "\(number + 1)" + marker.dropFirst(digits.count)
        }
        if let box = marker.range(of: "[x]") ?? marker.range(of: "[X]") {
            return marker.replacingCharacters(in: box, with: "[ ]")
        }
        return marker
    }

    /// A space landed. The shorthands that are *already* markdown — `- `, `* `, `1. `, `## ` — need
    /// no edit at all: they are the characters the store holds and the editor draws them as what
    /// they are the moment they land. Only the action box is shorthand for something longer.
    private static func shorthand(_ characters: [Character], caret: Int) -> Edit? {
        let start = lineStart(characters, before: caret)
        let typed = String(characters[start..<caret])
        let indent = typed.prefix { $0 == " " || $0 == "\t" }
        let rest = typed.dropFirst(indent.count)
        let box: String
        switch rest {
        case "[] ", "[ ] ": box = "[ ] "
        case "[x] ", "[X] ": box = "[x] "
        default: return nil
        }
        let replacement = indent + "- " + box
        let caretAfter = start + replacement.count
        return Edit(range: start..<caret, replacement: replacement, selection: caretAfter..<caretAfter)
    }

    /// Backspace landed inside the marker that makes this line a heading, a bullet or an action.
    /// Take the whole marker rather than leaving `-foo` or `#Title` behind — an editor that eats
    /// markers one character at a time makes you press it four times to unmake a checkbox.
    ///
    /// `caret` is where the insertion point sits *after* the deletion, which is also the index in
    /// the old document of the character that went.
    private static func markerBackspace(_ old: [Character], caret: Int) -> Edit? {
        guard caret >= 0, caret < old.count else { return nil }
        let start = lineStart(old, before: caret)
        var end = caret
        while end < old.count, old[end] != "\n" { end += 1 }
        guard let marker = MarkdownSyntax.blockMarker(String(old[start..<end])) else { return nil }
        let deleted = caret - start
        guard marker.contains(deleted) else { return nil }
        // What survived the deletion, in the *new* document: the marker minus the one character.
        let remaining = (start + marker.lowerBound)..<(start + marker.upperBound - 1)
        guard !remaining.isEmpty else { return nil }
        return Edit(
            range: remaining,
            replacement: "",
            selection: remaining.lowerBound..<remaining.lowerBound
        )
    }

    private static func lineStart(_ characters: [Character], before index: Int) -> Int {
        var start = min(index, characters.count)
        while start > 0, characters[start - 1] != "\n" { start -= 1 }
        return start
    }

    // MARK: - Ticking a box

    /// Ticking or unticking the task list item that `offset` falls on — **one character**, `x` for
    /// a space or a space for an `x`.
    ///
    /// It is here rather than in the view for the reason everything else in this file is: it is the
    /// same transform whether a pointer clicked the checkbox the editor draws over the box or a
    /// future keyboard shortcut asked for it, and it goes through ``Edit`` so the click lands on the
    /// undo stack and provokes the autosave exactly as typing the character would.
    ///
    /// The caret is left at the start of the item's own text. A click in a text view moves the
    /// insertion point wherever it lands; landing it in the sentence rather than inside the brackets
    /// is the only part of that worth deciding.
    public static func toggleTask(in text: String, at offset: Int) -> Edit? {
        let characters = Array(text)
        guard offset >= 0, offset <= characters.count else { return nil }
        let start = lineStart(characters, before: offset)
        var end = start
        while end < characters.count, characters[end] != "\n" { end += 1 }
        guard let item = MarkdownSyntax.taskItem(String(characters[start..<end])) else { return nil }
        let tick = start + item.box.lowerBound + 1
        let caret = start + item.textStart
        return Edit(
            range: tick..<(tick + 1),
            replacement: item.done ? " " : "x",
            selection: caret..<caret
        )
    }

    // MARK: - Where a floating surface goes

    /// Where the toolbar over a selection — or the menu under the caret — is drawn, in the editor's
    /// own coordinates.
    public struct Placement: Equatable, Sendable {
        public let x: CGFloat
        public let y: CGFloat
        /// True when there was no room above the anchor and it went underneath instead.
        public let below: Bool

        public init(x: CGFloat, y: CGFloat, below: Bool) {
            self.x = x
            self.y = y
            self.below = below
        }
    }

    /// Centred over `anchor`, above it when there is room and below it when there is not, and
    /// **never outside the editor**.
    ///
    /// The clamp is the part that was missing, and it is not a nicety. The toolbar is about 280 pt
    /// wide and it was centred on the selection with nothing bounding the result, so a selection
    /// that starts at the left edge of the text — which is where a drag usually starts — put its
    /// origin at roughly −95, outside the document column and past the left edge of the split
    /// view's detail pane. An `NSSplitView` pane clips, so those points were not merely off the
    /// measure, they were not drawn.
    ///
    /// It is a pure function over four numbers so that it can be tested, which is the whole reason
    /// it is here rather than inline in an `alignmentGuide` closure where nothing could reach it.
    /// A zero-height or zero-width anchor is still a position — a caret has no width, and a surface
    /// that refused to place itself over one would be a menu that never opened.
    public static func floating(
        over anchor: CGRect, size: CGSize, in width: CGFloat, gap: CGFloat = 6
    ) -> Placement {
        let centred = anchor.midX - size.width / 2
        // `max(…, 0)` on the upper bound as well, because an editor narrower than the surface has
        // no valid range at all and `min(x, negative)` would push it off the *left* instead.
        let x = min(max(centred, 0), max(width - size.width, 0))
        let above = anchor.minY - size.height - gap
        guard above >= 0 else {
            return Placement(x: x, y: anchor.maxY + gap, below: true)
        }
        return Placement(x: x, y: above, below: false)
    }

    // MARK: - Inline formatting, as a toggle

    /// The five pairs the keyboard shortcuts wrap a selection in.
    public enum InlineMark: String, Sendable, CaseIterable {
        case bold, italic, strikethrough, code, link

        public var open: String {
            switch self {
            case .bold: "**"
            case .italic: "*"
            case .strikethrough: "~~"
            case .code: "`"
            case .link: "["
            }
        }

        public var close: String {
            switch self {
            case .link: "](url)"
            default: open
            }
        }

        /// The run this mark *is*, in the parser's vocabulary. Detection goes through
        /// ``MarkdownSyntax/inline(_:)`` rather than through a second scanner of its own: `**bold**`
        /// contains `*bold*` as a substring, so anything that answers "is this italic" by looking
        /// for one asterisk says yes to every bold word on the line.
        var style: MarkdownSyntax.Inline {
            switch self {
            case .bold: .strong
            case .italic: .emphasis
            case .strikethrough: .strike
            case .code: .code
            case .link: .link
            }
        }
    }

    /// Wrapping the selection in the pair, or unwrapping it when it is already wrapped. A toggle,
    /// because ⌘B on bold text meaning "more bold" is not a behaviour anybody has.
    ///
    /// With no selection the pair goes in and the caret lands between the halves, so the next thing
    /// typed is inside it. With a selection the selection survives on the inner text, so the
    /// shortcut can be pressed twice to undo itself.
    public static func toggle(_ mark: InlineMark, in text: String, selection: Range<Int>) -> Edit {
        let characters = Array(text)
        let core = core(of: selection, in: characters)

        // Already wrapped, either just outside the selection or inside it — selecting the word and
        // selecting `**the word**` are the same intent and both have to toggle.
        if let (whole, inner) = wrapping(mark, characters, core) {
            let content = String(characters[inner])
            return Edit(
                range: whole,
                replacement: content,
                selection: whole.lowerBound..<(whole.lowerBound + content.count)
            )
        }

        let selected = String(characters[core])
        let open = mark.open.count
        let replacement = mark.open + selected + mark.close
        let inner = (core.lowerBound + open)..<(core.lowerBound + open + selected.count)
        // A link already has its label — what it is missing is somewhere to go, so the selection
        // lands on the placeholder target and the next thing typed replaces it.
        let caret = mark == .link
            ? (inner.upperBound + 2)..<(inner.upperBound + 5)
            : inner
        return Edit(range: core, replacement: replacement, selection: caret)
    }

    /// Whether the selection already carries `mark` — what a toolbar draws as a pressed button, and
    /// the same question ``toggle(_:in:selection:)`` asks to decide which way it is going. One
    /// answer behind both, so the button cannot say "on" while the shortcut turns it on again.
    public static func isActive(_ mark: InlineMark, in text: String, selection: Range<Int>) -> Bool {
        let characters = Array(text)
        return wrapping(mark, characters, core(of: selection, in: characters)) != nil
    }

    /// The characters a toggle actually acts on: the selection, clamped into the document and with
    /// its outer whitespace left out.
    ///
    /// The trim is not tidiness. `**word **` is not bold — CommonMark's right-flanking rule wants a
    /// non-space before the closing run — and a double-click takes the space after the word with it,
    /// so untrimmed the commonest selection in the editor produces four literal asterisks.
    private static func core(of selection: Range<Int>, in characters: [Character]) -> Range<Int> {
        let lower = min(max(selection.lowerBound, 0), characters.count)
        var start = lower
        var end = min(max(selection.upperBound, lower), characters.count)
        let outer = start..<end
        while start < end, characters[start].isWhitespace { start += 1 }
        while end > start, characters[end - 1].isWhitespace { end -= 1 }
        // All whitespace is not a mistyped word, and collapsing it to a caret would move the edit.
        return start < end ? start..<end : outer
    }

    /// The run of `mark` around the selection, as (the whole span including both delimiters, the
    /// text between them) — found either just outside the selection or inside it, because selecting
    /// the word and selecting `**the word**` are the same intent.
    ///
    /// The runs come from ``MarkdownSyntax/inline(_:)``, which is the editor's own parser: it knows
    /// `*`, `**` and `***` are three different delimiters, that an underscore inside a word is not
    /// one at all, and that nothing inside a backticked span is markup. A second scanner here would
    /// be a second answer to draw a pressed button from.
    private static func wrapping(
        _ mark: InlineMark, _ characters: [Character], _ selection: Range<Int>
    ) -> (whole: Range<Int>, inner: Range<Int>)? {
        guard selection.lowerBound >= 0, selection.upperBound <= characters.count else { return nil }
        // Per line, because no inline run closes across a break — and a selection that spans one
        // is therefore inside nothing.
        let start = lineStart(characters, before: selection.lowerBound)
        var end = start
        while end < characters.count, characters[end] != "\n" { end += 1 }
        guard selection.upperBound <= end else { return adjacent(mark, characters, selection) }

        let line = Array(characters[start..<end])
        var found: (whole: Range<Int>, inner: Range<Int>)?
        for span in MarkdownSyntax.inline(String(line)) where span.style == mark.style {
            let whole = (start + span.range.lowerBound)..<(start + span.range.upperBound)
            let inner = content(of: span, in: line, offset: start)
            // Inside the run, and touching the text rather than sitting past its far delimiter —
            // a caret between the two closing asterisks of `**bold**` is not in the bold.
            guard whole.lowerBound <= selection.lowerBound, selection.upperBound <= whole.upperBound,
                  inner.lowerBound <= selection.upperBound, selection.lowerBound <= inner.upperBound
            else { continue }
            // The innermost match: in `**bold with _em_ inside**` the underscores are the emphasis.
            if found.map({ whole.count < $0.whole.count }) ?? true { found = (whole, inner) }
        }
        return found ?? adjacent(mark, characters, selection)
    }

    /// The pair this very shortcut just typed, sitting immediately either side of the selection.
    ///
    /// The parser answers what markdown *means*, and there are three things it rightly calls
    /// nothing that a toggle still has to be able to take back off: an empty pair around a caret
    /// (`**|**`, which is four literal asterisks, and `[](url)`, which is a link with no label), a
    /// pair either side of a line break, and a pair inside a code span, where nothing is markup.
    /// Without this, pressing ⌘B twice in any of them adds a second pair instead of removing the
    /// first.
    ///
    /// The run either side has to end where the pair does — that is the rule the old detector was
    /// missing, and the reason italic read as on inside every bold word on the line.
    private static func adjacent(
        _ mark: InlineMark, _ characters: [Character], _ selection: Range<Int>
    ) -> (whole: Range<Int>, inner: Range<Int>)? {
        let open = Array(mark.open)
        let close = Array(mark.close)
        let before = selection.lowerBound - open.count
        let after = selection.upperBound + close.count
        guard before >= 0, after <= characters.count,
              Array(characters[before..<selection.lowerBound]) == open,
              Array(characters[selection.upperBound..<after]) == close,
              before == 0 || characters[before - 1] != open[0],
              after == characters.count || characters[after] != close[0],
              // …and the selection must not continue the run inwards. One `*` either side of
              // `*bold*` selected out of `**bold**` is the outer half of a strong run, not an
              // emphasis around it — taking it off would unbold text nobody asked to unbold.
              characters[selection].first != open[0], characters[selection].last != close[0]
        else { return nil }
        return (before..<after, selection)
    }

    /// The text a run wraps, without its delimiters. `***both***` is a strong run with an emphasis
    /// one inside it, so taking two characters off each end of the strong leaves `*both*` — which is
    /// exactly what "no longer bold, still italic" means.
    private static func content(
        of span: MarkdownSyntax.Span, in line: [Character], offset: Int
    ) -> Range<Int> {
        let range = span.range
        switch span.style {
        case .strong, .strike:
            return (offset + range.lowerBound + 2)..<(offset + range.upperBound - 2)
        case .emphasis, .code:
            return (offset + range.lowerBound + 1)..<(offset + range.upperBound - 1)
        case .link:
            // `[label](url)` — the label, which is the half worth keeping when the link comes off.
            var close = range.lowerBound + 1
            while close < range.upperBound, line[close] != "]" { close += 1 }
            return (offset + range.lowerBound + 1)..<(offset + close)
        }
    }

    // MARK: - The slash menu

    /// One item of the menu `/` opens. `insertion` replaces the `/query` that summoned it, and the
    /// caret lands `caretOffset` characters into what was inserted.
    public struct SlashCommand: Equatable, Sendable, Identifiable {
        public let id: String
        public let group: String
        public let title: String
        public let symbol: String
        public let insertion: String
        /// True for the constructs that are a *line's* marker — a heading, a bullet, an action.
        /// Choosing one replaces whatever marker the line already had, so H2 after H1 is one step
        /// rather than a `## ` glued onto a `# `. False for the two that are simply text dropped in
        /// at the caret.
        public let replacesMarker: Bool

        public var shorthand: String { "/\(id)" }
    }

    /// **The** block transform. Every surface that turns lines into a heading or a list comes
    /// through here — the slash menu, and the toolbar over a selection — so there is one answer to
    /// "what does Heading 2 do to this line".
    ///
    /// `over` is the caret or selection the command was asked for, and it is **not** a span to
    /// swallow. A block marker belongs to a *line*: the toolbar hands over the words somebody
    /// highlighted, and deleting them to put a bullet at the start of their sentence is the defect
    /// this parameter was renamed for. Each line the range touches loses the marker it had and gains
    /// `command`'s; the text between them is untouched and the selection follows it.
    ///
    /// Asking for the marker a line already carries takes it off again — a button that only ever
    /// goes on is one whose only "off" is undo.
    public static func applyBlock(
        _ command: SlashCommand, in text: String, over range: Range<Int>
    ) -> Edit {
        let characters = Array(text)
        guard command.replacesMarker else {
            // A construct that ends a line has to start one too, or `/divider` half-way through a
            // sentence leaves `we agreed---` — three hyphens that are not a rule at all.
            let ownLine = command.insertion.hasSuffix("\n")
                && range.lowerBound > lineStart(characters, before: range.lowerBound)
            let insertion = ownLine ? "\n" + command.insertion : command.insertion
            let caret = range.lowerBound + insertion.count
            return Edit(range: range, replacement: insertion, selection: caret..<caret)
        }
        let start = lineStart(characters, before: range.lowerBound)
        var end = range.upperBound
        // A selection that ends on a line break stops at the line it ends: dragging through
        // `one\n` is one line selected, not two.
        if end > range.lowerBound, end > 0, characters[end - 1] == "\n" { end -= 1 }
        while end < characters.count, characters[end] != "\n" { end += 1 }

        var lines: [(range: Range<Int>, indent: Int, body: Int)] = []
        var cursor = start
        while cursor <= end {
            var stop = cursor
            while stop < end, characters[stop] != "\n" { stop += 1 }
            let line = String(characters[cursor..<stop])
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            lines.append((cursor..<stop, indent, MarkdownSyntax.blockMarker(line)?.upperBound ?? indent))
            cursor = stop + 1
        }
        // Pressed twice: every line already is this construct, and at least one of them has
        // something to say. An empty `- ` is somebody mid-item, and taking their bullet away as
        // they reach for the menu is not a toggle they asked for.
        let taking = lines.allSatisfy { carries(command, String(characters[$0.range])) }
            && lines.contains { $0.range.lowerBound + $0.body < $0.range.upperBound }

        var rebuilt: [String] = []
        var shifts: [(range: Range<Int>, body: Int, delta: Int, shift: Int)] = []
        var shift = 0
        for (number, line) in lines.enumerated() {
            let source = Array(characters[line.range])
            // A numbered list counts from where it was asked for, not from one every time.
            let marker = taking ? "" : (command.id == "number" ? "\(number + 1). " : command.insertion)
            rebuilt.append(String(source[0..<line.indent]) + marker + String(source[line.body...]))
            let head = line.indent + marker.count
            shifts.append((line.range, head, head - line.body, shift))
            shift += head - line.body
        }

        /// Where an offset ends up. Anything inside the old marker lands on the new line's first
        /// character of prose rather than inside the marker that replaced it.
        func moved(_ offset: Int) -> Int {
            guard let line = shifts.first(where: { offset <= $0.range.upperBound }) else {
                return offset + shift
            }
            return max(offset + line.shift + line.delta, line.range.lowerBound + line.shift + line.body)
        }

        return Edit(
            range: start..<end,
            replacement: rebuilt.joined(separator: "\n"),
            selection: moved(range.lowerBound)..<moved(range.upperBound)
        )
    }

    /// Whether the line already is what `command` makes. Deliberately per construct rather than a
    /// string comparison on the marker: `- [ ] task` starts with `- `, and a bulleted-list button
    /// that read it as "already a bullet" would strip the checkbox instead of unmaking the action.
    private static func carries(_ command: SlashCommand, _ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        switch command.id {
        case "h1", "h2", "h3":
            return MarkdownSyntax.line(line) == .heading(level: command.insertion.count { $0 == "#" })
        case "todo": return MarkdownSyntax.taskItem(line) != nil
        case "bullet":
            return MarkdownSyntax.line(line) == .bullet && MarkdownSyntax.taskItem(line) == nil
                && !(trimmed.first?.isNumber ?? true)
        case "number":
            return MarkdownSyntax.line(line) == .bullet && MarkdownSyntax.taskItem(line) == nil
                && trimmed.first?.isNumber == true
        case "quote": return MarkdownSyntax.line(line) == .quote
        default: return false
        }
    }

    /// The menu, in the order it is drawn. Block-level only: a slash command fires at a caret with
    /// nothing selected, so bold would have nothing to embolden — inline formatting is the
    /// keyboard shortcuts and the as-you-type styling, and it is not here.
    ///
    /// Every symbol name below is one that resolves on macOS 26. A name that does not exist draws a
    /// blank box, and the menu is the one surface where that is invisible until somebody opens it.
    public static let slashCommands: [SlashCommand] = [
        .init(id: "h1", group: "Headings", title: "Heading 1",
              symbol: "textformat.size.larger", insertion: "# ", replacesMarker: true),
        .init(id: "h2", group: "Headings", title: "Heading 2",
              symbol: "textformat.size", insertion: "## ", replacesMarker: true),
        .init(id: "h3", group: "Headings", title: "Heading 3",
              symbol: "textformat.size.smaller", insertion: "### ", replacesMarker: true),
        .init(id: "bullet", group: "Lists", title: "Bulleted list",
              symbol: "list.bullet", insertion: "- ", replacesMarker: true),
        .init(id: "number", group: "Lists", title: "Numbered list",
              symbol: "list.number", insertion: "1. ", replacesMarker: true),
        .init(id: "todo", group: "Lists", title: "Action",
              symbol: "checklist", insertion: "- [ ] ", replacesMarker: true),
        .init(id: "quote", group: "Blocks", title: "Quote",
              symbol: "text.quote", insertion: "> ", replacesMarker: true),
        .init(id: "code", group: "Blocks", title: "Code",
              symbol: "curlybraces", insertion: "`code`", replacesMarker: false),
        .init(id: "divider", group: "Blocks", title: "Divider",
              symbol: "minus", insertion: "---\n", replacesMarker: false),
    ]

    /// The subset a formatting toolbar offers as "turn into". Same commands, same transform — a
    /// second surface over one model rather than a parallel one.
    public static let blockCommands: [SlashCommand] = slashCommands.filter {
        ["h1", "h2", "h3", "bullet", "todo"].contains($0.id)
    }

    /// The range of the `/query` the caret is sitting in, or nil when it is not in one.
    ///
    /// The slash has to start a word — at the beginning of a line or after whitespace — so
    /// `http://x` and `and/or` never summon a menu mid-sentence.
    public static func slashQuery(in text: String, caret: Int) -> Range<Int>? {
        let characters = Array(text)
        guard caret <= characters.count else { return nil }
        var start = caret
        while start > 0 {
            let character = characters[start - 1]
            if character == "/" {
                start -= 1
                break
            }
            guard character.isLetter || character.isNumber else { return nil }
            start -= 1
            if start == 0 { return nil }
        }
        guard start < caret, characters[start] == "/" else { return nil }
        guard start == 0 || characters[start - 1].isWhitespace else { return nil }
        return start..<caret
    }

    /// The commands a query matches, in menu order. An empty query is every command — `/` on its
    /// own is somebody who wants to see the list.
    public static func slashMatches(_ query: some StringProtocol) -> [SlashCommand] {
        let needle = query.drop { $0 == "/" }.lowercased()
        guard !needle.isEmpty else { return slashCommands }
        return slashCommands.filter { command in
            command.id.hasPrefix(needle)
                || command.title.lowercased().split(separator: " ").contains { $0.hasPrefix(needle) }
        }
    }

    /// Choosing `command` from the menu the `/query` at `range` opened.
    ///
    /// The query goes first and the transform then sees the line as it will be. That order is the
    /// whole distinction between the two surfaces: the menu has a span to swallow and a toolbar
    /// has a selection to keep, and folding both into one "replacing" parameter is what made
    /// pressing a list button over a highlighted word delete the word.
    public static func insert(_ command: SlashCommand, over range: Range<Int>, in text: String) -> Edit {
        guard !range.isEmpty else { return applyBlock(command, in: text, over: range) }
        var characters = Array(text)
        characters.replaceSubrange(range, with: [])
        let caret = range.lowerBound..<range.lowerBound
        let edit = applyBlock(command, in: String(characters), over: caret)
        // The same edit, widened by the query it swallowed. Everything from the caret on sat
        // `range.count` characters later in the document the user is actually looking at.
        return Edit(
            range: edit.range.lowerBound..<(edit.range.upperBound + range.count),
            replacement: edit.replacement,
            selection: edit.selection
        )
    }
}
