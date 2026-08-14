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
    }

    /// Wrapping the selection in the pair, or unwrapping it when it is already wrapped. A toggle,
    /// because ⌘B on bold text meaning "more bold" is not a behaviour anybody has.
    ///
    /// With no selection the pair goes in and the caret lands between the halves, so the next thing
    /// typed is inside it. With a selection the selection survives on the inner text, so the
    /// shortcut can be pressed twice to undo itself.
    public static func toggle(_ mark: InlineMark, in text: String, selection: Range<Int>) -> Edit {
        let characters = Array(text)
        let open = Array(mark.open)
        let selected = Array(characters[selection])

        // Already wrapped, either just outside the selection or inside it — selecting the word and
        // selecting `**the word**` are the same intent and both have to toggle.
        if let (whole, close) = wrapping(mark, characters, selection) {
            return removing(open.count, close, characters, whole)
        }

        let replacement = mark.open + String(selected) + mark.close
        let inner = (selection.lowerBound + open.count)..<(selection.lowerBound + open.count + selected.count)
        // A link already has its label — what it is missing is somewhere to go, so the selection
        // lands on the placeholder target and the next thing typed replaces it.
        let caret = mark == .link
            ? (inner.upperBound + 2)..<(inner.upperBound + 5)
            : inner
        return Edit(range: selection, replacement: replacement, selection: caret)
    }

    /// Whether the selection already carries `mark` — what a toolbar draws as a pressed button, and
    /// the same question ``toggle(_:in:selection:)`` asks to decide which way it is going. One
    /// answer behind both, so the button cannot say "on" while the shortcut turns it on again.
    public static func isActive(_ mark: InlineMark, in text: String, selection: Range<Int>) -> Bool {
        wrapping(mark, Array(text), selection) != nil
    }

    /// The pair around the selection, as (the whole span including both halves, the closing half) —
    /// found either just outside the selection or inside it, because selecting the word and
    /// selecting `**the word**` are the same intent.
    private static func wrapping(
        _ mark: InlineMark, _ characters: [Character], _ selection: Range<Int>
    ) -> (whole: Range<Int>, close: Range<Int>)? {
        guard selection.lowerBound >= 0, selection.upperBound <= characters.count else { return nil }
        let open = Array(mark.open)

        let outside = selection.lowerBound - open.count
        if outside >= 0, Array(characters[outside..<selection.lowerBound]) == open,
           let close = closed(mark, characters, from: selection.upperBound, limit: characters.count),
           close.lowerBound == selection.upperBound {
            return (outside..<close.upperBound, close)
        }

        let selected = Array(characters[selection])
        guard selected.count > open.count, selected.starts(with: open) else { return nil }
        var probe = selection.lowerBound + open.count
        while probe < selection.upperBound {
            if let close = closed(mark, characters, from: probe, limit: selection.upperBound),
               close.upperBound == selection.upperBound {
                return (selection, close)
            }
            probe += 1
        }
        return nil
    }

    /// Where the closing half of the pair sits, starting the search at `from`.
    private static func closed(
        _ mark: InlineMark, _ characters: [Character], from: Int, limit: Int
    ) -> Range<Int>? {
        if mark == .link {
            // `](` then anything up to the first `)`. The target is whatever the author put there.
            guard from + 1 < limit, characters[from] == "]", characters[from + 1] == "(" else { return nil }
            var end = from + 2
            while end < limit, characters[end] != ")" { end += 1 }
            return end < limit ? from..<(end + 1) : nil
        }
        let close = Array(mark.close)
        guard from + close.count <= limit,
              Array(characters[from..<(from + close.count)]) == close
        else { return nil }
        return from..<(from + close.count)
    }

    /// Both halves removed, leaving the text that was between them selected.
    private static func removing(
        _ openWidth: Int, _ close: Range<Int>, _ characters: [Character], _ whole: Range<Int>
    ) -> Edit {
        let inner = (whole.lowerBound + openWidth)..<close.lowerBound
        let text = String(characters[inner])
        return Edit(
            range: whole,
            replacement: text,
            selection: whole.lowerBound..<(whole.lowerBound + text.count)
        )
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
    /// through here — the slash menu consuming its own `/query`, and anything else with an empty
    /// range at the caret — so there is one answer to "what does Heading 2 do to this line".
    ///
    /// `replacing` is the span to swallow on the way. Each line the range touches loses the marker
    /// it had and gains `command`'s.
    public static func applyBlock(
        _ command: SlashCommand, in text: String, replacing range: Range<Int>
    ) -> Edit {
        let characters = Array(text)
        guard command.replacesMarker else {
            let caret = range.lowerBound + command.insertion.count
            return Edit(range: range, replacement: command.insertion, selection: caret..<caret)
        }
        let start = lineStart(characters, before: range.lowerBound)
        var end = max(range.upperBound, range.lowerBound)
        while end < characters.count, characters[end] != "\n" { end += 1 }

        var rebuilt: [String] = []
        var cursor = start
        var lineNumber = 0
        while cursor <= end {
            var stop = cursor
            while stop < end, characters[stop] != "\n" { stop += 1 }
            // The line with the range in it loses those characters; the rest keep everything.
            var line = Array(characters[cursor..<stop])
            if range.lowerBound >= cursor, range.upperBound <= stop, !range.isEmpty {
                line.replaceSubrange((range.lowerBound - cursor)..<(range.upperBound - cursor), with: [])
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            var body = String(line[indent...])
            if let marker = MarkdownSyntax.blockMarker(String(line)) {
                body = String(line[marker.upperBound...])
            }
            // A numbered list counts from where it was asked for, not from one every time.
            let marker = command.id == "number" ? "\(lineNumber + 1). " : command.insertion
            rebuilt.append(String(line[0..<indent]) + marker + body)
            lineNumber += 1
            cursor = stop + 1
        }
        let replacement = rebuilt.joined(separator: "\n")
        let caret = start + replacement.count
        return Edit(range: start..<end, replacement: replacement, selection: caret..<caret)
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
    public static func insert(_ command: SlashCommand, over range: Range<Int>, in text: String) -> Edit {
        applyBlock(command, in: text, replacing: range)
    }
}
