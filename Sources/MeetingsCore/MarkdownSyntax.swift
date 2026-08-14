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

    /// The leading run of characters that says what the line *is* — `##`, `-`, `1.`, `>`, `- [ ]` —
    /// with the space after it, as character offsets into the line. Nil for prose.
    ///
    /// Leading indentation is deliberately **not** part of it. A nested item keeps its indent and
    /// its marker sits after it, so the gutter is drawn per level rather than collapsing every
    /// depth onto one edge.
    public static func blockMarker(_ line: some StringProtocol) -> Range<Int>? {
        let characters = Array(line)
        let indent = characters.prefix { $0 == " " || $0 == "\t" }.count
        let rest = characters[indent...]
        guard let first = rest.first else { return nil }

        /// The space after a marker belongs to the marker: it is the gap the gutter replaces, and
        /// leaving it with the prose puts a different amount of it in front of every construct.
        func withTrailingSpace(_ end: Int) -> Range<Int> {
            end < characters.count && characters[end] == " " ? indent..<(end + 1) : indent..<end
        }

        if first == "#" {
            let hashes = rest.prefix { $0 == "#" }.count
            let after = indent + hashes
            guard after == characters.count || characters[after] == " " else { return nil }
            return withTrailingSpace(after)
        }
        if first == ">" { return withTrailingSpace(indent + 1) }

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
        // A bare `-` with nothing after it is the first keystroke of an item, and it is already a
        // marker — otherwise the line jumps sideways the instant the space lands.
        guard end == characters.count || characters[end] == " " else { return nil }
        var marker = withTrailingSpace(end)
        // `- [ ]` and `- [x]`: the box is part of what marks the line, not part of the sentence.
        let box = marker.upperBound
        if box + 2 < characters.count, characters[box] == "[", characters[box + 2] == "]",
           characters[box + 1] == " " || characters[box + 1] == "x" || characters[box + 1] == "X" {
            marker = marker.lowerBound..<withTrailingSpace(box + 3).upperBound
        }
        return marker
    }

    /// Every character in the line that is *markup rather than prose* — the block marker, and both
    /// delimiters of every closed inline run — left to right and merged where they touch.
    ///
    /// This is what the editor dims. It is a separate answer from ``inline(_:)`` because the two
    /// questions differ: `inline` asks which characters to draw **bold**, `markers` asks which ones
    /// are scaffolding the reader should be able to look past.
    public static func markers(_ line: some StringProtocol) -> [Range<Int>] {
        var found: [Range<Int>] = []
        if let block = blockMarker(line) { found.append(block) }
        var spans: [Span] = []
        scan(Array(line), offset: 0, spans: &spans, markers: &found)
        return merge(found)
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    public enum Inline: Equatable, Sendable {
        case strong
        case emphasis
        case strike
        case code
        /// The whole of `[label](url)`. The label is scanned for markup of its own; the brackets
        /// and the target are markers, so ``markers(_:)`` dims them.
        case link
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

    /// The inline runs in one line, in the order they should be *applied*: a run that contains
    /// another comes first, so italic layers on top of the bold it sits inside and `***both***`
    /// ends up both.
    ///
    /// A run only exists once it is closed, which is what makes this usable on text being typed: a
    /// lone `**`, a `~~` with no partner, a `[label](` still missing its `)` — none of them are
    /// anything yet, and the rest of the line does not change weight while the user reaches for the
    /// second half.
    ///
    /// ponytail: underscore emphasis is CommonMark's, not naive. `_italic_` is italic and
    /// `meeting_store_open` is not, because an underscore touching a word character on the inside
    /// is never a delimiter. Without that rule a store full of identifiers italicises itself.
    public static func inline(_ text: some StringProtocol) -> [Span] {
        var spans: [Span] = []
        var markers: [Range<Int>] = []
        scan(Array(text), offset: 0, spans: &spans, markers: &markers)
        return spans
    }

    /// One pass, producing both answers. They are found by the same walk — separating them would
    /// mean two parsers agreeing about what closes what, which is exactly how they drift.
    private static func scan(
        _ characters: [Character], offset: Int, spans: inout [Span], markers: inout [Range<Int>]
    ) {
        var index = 0
        while index < characters.count {
            if let link = link(characters, at: index) {
                spans.append(Span(style: .link, range: (offset + index)..<(offset + link.end)))
                markers.append((offset + index)..<(offset + index + 1))
                markers.append((offset + link.label.upperBound)..<(offset + link.end))
                scan(Array(characters[link.label]),
                     offset: offset + link.label.lowerBound, spans: &spans, markers: &markers)
                index = link.end
                continue
            }
            guard let mark = delimiter(characters[index]) else {
                index += 1
                continue
            }
            let run = min(characters[index...].prefix { $0 == characters[index] }.count, mark.widest)
            guard run >= mark.narrowest,
                  opens(characters, at: index, mark: characters[index]),
                  let close = closing(characters, from: index + run, mark: characters[index], width: run)
            else {
                index += 1
                continue
            }
            let end = close + run
            switch (mark.style, run) {
            case (.emphasis, 2): spans.append(Span(style: .strong, range: (offset + index)..<(offset + end)))
            // `***x***` is both, and it is one construct rather than a bold that happens to abut an
            // italic — so it is emitted as the pair it means.
            case (.emphasis, 3):
                spans.append(Span(style: .strong, range: (offset + index)..<(offset + end)))
                spans.append(Span(style: .emphasis, range: (offset + index + 1)..<(offset + end - 1)))
            default: spans.append(Span(style: mark.style, range: (offset + index)..<(offset + end)))
            }
            markers.append((offset + index)..<(offset + index + run))
            markers.append((offset + close)..<(offset + end))
            // Markup inside a closed span belongs to that span, so `**a * b**` is one strong run.
            // Code is the exception in the other direction: a backticked `**` is two characters of
            // a command, and nothing inside it is markup.
            if mark.style != .code {
                scan(Array(characters[(index + run)..<close]),
                     offset: offset + index + run, spans: &spans, markers: &markers)
            }
            index = end
        }
    }

    private static func delimiter(_ character: Character) -> (style: Inline, narrowest: Int, widest: Int)? {
        switch character {
        case "`": (.code, 1, 1)
        // A single `~` is a tilde somebody typed. Strikethrough is the doubled one, and only that.
        case "~": (.strike, 2, 2)
        case "*", "_": (.emphasis, 1, 3)
        default: nil
        }
    }

    /// CommonMark's left-flanking rule, applied only where it earns its keep. An underscore between
    /// two word characters is part of the word.
    private static func opens(_ characters: [Character], at index: Int, mark: Character) -> Bool {
        guard mark == "_" else { return true }
        guard index > 0 else { return true }
        return !characters[index - 1].isLetter && !characters[index - 1].isNumber
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
            let after = index + run
            let flanks = mark != "_"
                || after >= characters.count
                || (!characters[after].isLetter && !characters[after].isNumber)
            guard run >= width, index > start, flanks else {
                index += max(run, 1)
                continue
            }
            return index
        }
        return nil
    }

    /// `[label](url)` at `index`, or nil. The label may not span a `]`, and the target may not span
    /// a `)` — both are the common case and both keep a half-typed link inert.
    private static func link(
        _ characters: [Character], at index: Int
    ) -> (label: Range<Int>, end: Int)? {
        guard characters[index] == "[" else { return nil }
        var close = index + 1
        while close < characters.count, characters[close] != "]" { close += 1 }
        guard close < characters.count, close > index + 1,
              close + 1 < characters.count, characters[close + 1] == "("
        else { return nil }
        var target = close + 2
        while target < characters.count, characters[target] != ")" { target += 1 }
        guard target < characters.count else { return nil }
        return ((index + 1)..<close, target + 1)
    }
}
