import Foundation

/// What a line of markdown *is*, and which spans inside it are marked up — at the offsets they
/// occupy in the source.
///
/// This is the live editor's question, and it is not ``MarkdownText``'s. That one reflows
/// soft-wrapped lines into blocks in order to *render* a finished document, and the reflow is
/// exactly what an editor must not do to text somebody is still typing: the characters on screen
/// have to stay the characters in the store, at the same offsets, or the caret lands somewhere the
/// user did not put it. So the editor styles the source in place — a heading drawn at heading size
/// with its `##` still visible and still editable — and what it needs from markdown is a
/// classification per line plus the ranges of the inline runs.
///
/// It lives here rather than beside the editor for the same reason ``SharedFieldEdit`` does:
/// `MeetingsApp` is an executable target with no test target behind it, and "which characters are a
/// heading" is the part of that editor which is logic rather than layout.
public enum MarkdownSyntax {
    /// The kind of one *source* line. Deliberately a short list: the editor only distinguishes
    /// what it can draw differently without moving a character.
    public enum Line: Equatable, Sendable {
        /// `#` through `######`, clamped the way CommonMark clamps it. A seventh hash is not a
        /// heading at all, but treating it as level 6 is friendlier than dropping to body text
        /// mid-keystroke while somebody holds the key down.
        case heading(level: Int)
        /// `- x`, `* x`, `+ x`, `1. x`, `2) x`. Task items (`- [ ] x`) land here too: they are
        /// list items, and the app has no behaviour to attach to the brackets — the actions
        /// checklist under the write-up is the structured column, not a line of prose.
        case bullet
        case quote
        case body
    }

    /// Leading whitespace is skipped, so an indented list item is still a list item. A tab counts
    /// as whitespace, and four spaces are *not* treated as a code block — an agent that indents a
    /// continuation line should not have the line change size under it.
    public static func line(_ line: some StringProtocol) -> Line {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first else { return .body }

        if first == "#" {
            let hashes = trimmed.prefix { $0 == "#" }.count
            // `#word` is a tag, not a heading: CommonMark wants a space after the hashes. An empty
            // rest is a heading being typed, and it has to grow as you type or the line jumps.
            let rest = trimmed.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " else { return .body }
            return .heading(level: min(hashes, 6))
        }
        if first == ">" { return .quote }
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) { return .bullet }
        // A bare marker on its own — the first keystroke of a new item.
        if trimmed == "-" || trimmed == "*" || trimmed == "+" { return .bullet }

        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") || rest == "." || rest == ")" {
                return .bullet
            }
        }
        return .body
    }

    public enum Inline: Equatable, Sendable {
        case strong
        case emphasis
        case code
    }

    /// One marked-up run, as **character offsets from the start of the line it was found in**, and
    /// including its own delimiters. The delimiters are part of the span deliberately: they are
    /// still in the document, so leaving them at body weight would draw `**` at one size and the
    /// word it emphasises at another, and the line would visibly reflow as the closing pair landed.
    public struct Span: Equatable, Sendable {
        public let style: Inline
        public let range: Range<Int>

        public init(style: Inline, range: Range<Int>) {
            self.style = style
            self.range = range
        }
    }

    /// The inline runs in one line, left to right and never overlapping.
    ///
    /// A run only exists once it is closed, which is what makes this usable on text being typed: a
    /// lone `**` is not yet anything, and the rest of the line does not turn bold while the user
    /// looks for the second asterisk.
    ///
    /// ponytail: no `_underscore_` emphasis. This is a notes field in a store full of identifiers,
    /// and `snake_case_names` would light up as italics far more often than anybody would mean it.
    public static func inline(_ text: some StringProtocol) -> [Span] {
        let characters = Array(text)
        var spans: [Span] = []
        var index = 0

        while index < characters.count {
            guard let (width, style) = opener(characters, at: index) else {
                index += 1
                continue
            }
            guard let close = closing(characters, from: index + width, mark: characters[index], width: width) else {
                index += 1
                continue
            }
            spans.append(Span(style: style, range: index..<(close + width)))
            // Past the whole run: markup inside a closed span belongs to that span, so `**a * b**`
            // is one strong run and a backticked `**` is code rather than a stray opener.
            index = close + width
        }
        return spans
    }

    private static func opener(_ characters: [Character], at index: Int) -> (width: Int, style: Inline)? {
        switch characters[index] {
        case "`":
            return (1, .code)
        case "*":
            let doubled = index + 1 < characters.count && characters[index + 1] == "*"
            return doubled ? (2, .strong) : (1, .emphasis)
        default:
            return nil
        }
    }

    /// The offset of the closing delimiter, or nil when the run never closes on this line. Content
    /// has to be non-empty, so `****` is four literal asterisks rather than an empty bold run.
    private static func closing(
        _ characters: [Character], from start: Int, mark: Character, width: Int
    ) -> Int? {
        var index = start
        while index + width <= characters.count {
            guard characters[index] == mark else {
                index += 1
                continue
            }
            let run = characters[index...].prefix { $0 == mark }.count
            guard run >= width, index > start else {
                index += max(run, 1)
                continue
            }
            return index
        }
        return nil
    }
}
