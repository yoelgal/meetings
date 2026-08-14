import Foundation
import Testing

@testable import MeetingsCore

/// The live editor's markdown decisions. Everything here is about text somebody is **in the middle
/// of typing**: half-written markup is the normal state of this function's input, and the failures
/// that matter are the ones where a line changes size or weight under the cursor.
@Suite struct MarkdownSyntaxTests {
    @Test func headingsAreClassifiedByTheirLevel() {
        #expect(MarkdownSyntax.line("# Title") == .heading(level: 1))
        #expect(MarkdownSyntax.line("## Decisions") == .heading(level: 2))
        #expect(MarkdownSyntax.line("###### Deep") == .heading(level: 6))
        // Clamped rather than dropped: somebody holding the key down should not watch the line fall
        // back to body text on the seventh hash.
        #expect(MarkdownSyntax.line("####### Deeper") == .heading(level: 6))
    }

    /// The hashes alone are a heading being typed. Without this the first keystroke of every
    /// heading draws at body size and the line jumps the moment the space lands.
    @Test func aHeadingBeingTypedIsAlreadyAHeading() {
        #expect(MarkdownSyntax.line("#") == .heading(level: 1))
        #expect(MarkdownSyntax.line("##") == .heading(level: 2))
    }

    /// `#alpha` is a tag, an id, a channel name. CommonMark wants the space and so do we.
    @Test func aHashWithNoSpaceIsNotAHeading() {
        #expect(MarkdownSyntax.line("#standup") == .body)
        #expect(MarkdownSyntax.line("#1 priority") == .body)
    }

    @Test func listItemsOfEveryMarker() {
        for line in ["- ship it", "* ship it", "+ ship it", "1. ship it", "2) ship it"] {
            #expect(MarkdownSyntax.line(line) == .bullet, "\(line) is a list item")
        }
        // Indented, and a task item, are still list items.
        #expect(MarkdownSyntax.line("    - nested") == .bullet)
        #expect(MarkdownSyntax.line("- [ ] not done") == .bullet)
        #expect(MarkdownSyntax.line("- [x] done") == .bullet)
        // The first keystroke of one.
        #expect(MarkdownSyntax.line("-") == .bullet)
        #expect(MarkdownSyntax.line("1.") == .bullet)
    }

    @Test func quotesAndPlainProse() {
        #expect(MarkdownSyntax.line("> she said") == .quote)
        #expect(MarkdownSyntax.line("We agreed to ship on Friday.") == .body)
        #expect(MarkdownSyntax.line("") == .body)
        // A dash inside a sentence is not a bullet, and a year is not an ordered item.
        #expect(MarkdownSyntax.line("well-known problem") == .body)
        #expect(MarkdownSyntax.line("2024 was worse") == .body)
    }

    // MARK: - Inline runs

    @Test func boldItalicAndCodeAreFoundWithTheirDelimiters() {
        #expect(MarkdownSyntax.inline("a **b** c") == [.init(style: .strong, range: 2..<7)])
        #expect(MarkdownSyntax.inline("a *b* c") == [.init(style: .emphasis, range: 2..<5)])
        #expect(MarkdownSyntax.inline("run `meetings show` now")
            == [.init(style: .code, range: 4..<19)])
    }

    /// The one that makes this usable while typing: an opener with no closer is not a run, so the
    /// rest of the line does not go bold while the user reaches for the second asterisk.
    @Test func anUnclosedRunIsNotARun() {
        #expect(MarkdownSyntax.inline("a **b").isEmpty)
        #expect(MarkdownSyntax.inline("a *b").isEmpty)
        #expect(MarkdownSyntax.inline("a `b").isEmpty)
        #expect(MarkdownSyntax.inline("**").isEmpty)
    }

    /// Empty content is not a run either — `****` is four asterisks somebody typed, not bold
    /// nothing.
    @Test func anEmptyRunIsNotARun() {
        #expect(MarkdownSyntax.inline("****").isEmpty)
        #expect(MarkdownSyntax.inline("``").isEmpty)
    }

    /// Markup inside a closed run belongs to that run. A code span full of asterisks is the case
    /// that matters: it is what a summary quoting a command looks like.
    @Test func markupInsideAClosedRunIsPartOfIt() {
        #expect(MarkdownSyntax.inline("`a ** b`") == [.init(style: .code, range: 0..<8)])
        #expect(MarkdownSyntax.inline("**a * b**") == [.init(style: .strong, range: 0..<9)])
    }

    /// ponytail: no underscore emphasis, on purpose. These are notes in a store full of
    /// identifiers, and `snake_case` italicising itself would be wrong far more often than right.
    @Test func underscoresAreNeverEmphasis() {
        #expect(MarkdownSyntax.inline("call meeting_store_open twice").isEmpty)
        #expect(MarkdownSyntax.inline("_not italic_").isEmpty)
    }

    @Test func severalRunsOnOneLineComeBackInOrderAndDoNotOverlap() {
        let spans = MarkdownSyntax.inline("**one** and `two` and *three*")
        #expect(spans.map(\.style) == [.strong, .code, .emphasis])
        for (earlier, later) in zip(spans, spans.dropFirst()) {
            #expect(earlier.range.upperBound <= later.range.lowerBound)
        }
        // And every range is inside the line it came from.
        #expect(spans.allSatisfy { $0.range.upperBound <= "**one** and `two` and *three*".count })
    }

    /// The editor offsets into an `AttributedString` with these numbers, and an off-by-one is a
    /// crash rather than a cosmetic slip. Emoji are one Character and several scalars, which is
    /// exactly where a count taken in the wrong unit goes wrong.
    @Test func offsetsAreCharacterOffsetsIntoTheLine() throws {
        let line = "👍 **shipped** 🎉"
        let span = try #require(MarkdownSyntax.inline(line).first)
        let characters = Array(line)
        #expect(String(characters[span.range]) == "**shipped**")
    }
}
