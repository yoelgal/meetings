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

    /// Underscore emphasis is CommonMark's rule, not the naive one. `_italic_` is italic; an
    /// underscore touching a word character on the inside is part of the word, which is what keeps
    /// a store full of identifiers from italicising itself.
    @Test func underscoresAreEmphasisOnlyWhenTheyAreNotInsideAWord() {
        #expect(MarkdownSyntax.inline("call meeting_store_open twice").isEmpty)
        #expect(MarkdownSyntax.inline("_italic_") == [.init(style: .emphasis, range: 0..<8)])
        #expect(MarkdownSyntax.inline("__bold__") == [.init(style: .strong, range: 0..<8)])
    }

    // MARK: - The rest of the inline constructs

    @Test func strikethroughNeedsBothTildes() {
        #expect(MarkdownSyntax.inline("~~dropped~~") == [.init(style: .strike, range: 0..<11)])
        // A single tilde is a tilde. `~/Documents` is a path, not the start of anything.
        #expect(MarkdownSyntax.inline("~dropped~").isEmpty)
        #expect(MarkdownSyntax.inline("cd ~/notes and ~/docs").isEmpty)
    }

    @Test func aLinkIsOneRunCoveringItsLabelAndItsTarget() {
        let spans = MarkdownSyntax.inline("see [the docs](https://x.dev) now")
        #expect(spans == [.init(style: .link, range: 4..<29)])
        #expect(String(Array("see [the docs](https://x.dev) now")[4..<29]) == "[the docs](https://x.dev)")
    }

    /// `***x***` is both, and the pair is emitted outermost first so a renderer that applies them
    /// in order layers italic on top of bold rather than replacing it.
    @Test func tripledDelimitersAreBoldAndItalicTogether() {
        #expect(MarkdownSyntax.inline("***both***") == [
            .init(style: .strong, range: 0..<10),
            .init(style: .emphasis, range: 1..<9),
        ])
    }

    @Test func aRunInsideAnotherIsFoundAfterTheOneItIsIn() {
        #expect(MarkdownSyntax.inline("**bold and _italic_**") == [
            .init(style: .strong, range: 0..<21),
            .init(style: .emphasis, range: 11..<19),
        ])
        // Except inside code, where nothing is markup — a backticked command is characters.
        #expect(MarkdownSyntax.inline("`meetings --flag **x**`")
            == [.init(style: .code, range: 0..<23)])
    }

    /// The rule that makes every one of these usable on text somebody is still typing: markup with
    /// no closing half is literal, for **every** construct rather than for bold as a special case.
    @Test func unterminatedMarkupOfEveryKindStaysLiteral() {
        for half in ["a **b", "a __b", "a *b", "a _b", "a ~~b", "a `b", "see [the docs](https://x"] {
            #expect(MarkdownSyntax.inline(half).isEmpty, "\(half) is not markup yet")
        }
        // A link needs its target too — the label alone is a bracket somebody typed.
        #expect(MarkdownSyntax.inline("see [the docs] now").isEmpty)
    }

    // MARK: - The gutter

    /// What gets pushed into the left gutter. The trailing space belongs to the marker: it is the
    /// gap the gutter replaces, and leaving it with the prose puts a different amount of it in
    /// front of every construct.
    @Test func theBlockMarkerIsWhateverSaysWhatTheLineIs() {
        #expect(MarkdownSyntax.blockMarker("## Decisions") == 0..<3)
        #expect(MarkdownSyntax.blockMarker("- ship it") == 0..<2)
        #expect(MarkdownSyntax.blockMarker("1. first") == 0..<3)
        #expect(MarkdownSyntax.blockMarker("> she said") == 0..<2)
        // The box is part of what marks an action, not part of the sentence.
        #expect(MarkdownSyntax.blockMarker("- [ ] task") == 0..<6)
        #expect(MarkdownSyntax.blockMarker("- [x] done") == 0..<6)
        // Being typed.
        #expect(MarkdownSyntax.blockMarker("#") == 0..<1)
        #expect(MarkdownSyntax.blockMarker("- ") == 0..<2)
    }

    /// Indentation is not part of the marker. A nested item keeps its indent and its marker sits
    /// after it, so the gutter is drawn per level instead of collapsing every depth onto one edge.
    @Test func indentationIsNotPartOfTheMarker() {
        #expect(MarkdownSyntax.blockMarker("    - nested") == 4..<6)
        #expect(MarkdownSyntax.blockMarker("\t1. nested") == 1..<4)
    }

    @Test func proseHasNoMarkerAtAll() {
        for line in ["We agreed to ship.", "", "well-known problem", "2024 was worse", "#standup"] {
            #expect(MarkdownSyntax.blockMarker(line) == nil, "\(line) is prose")
        }
    }

    /// What the editor dims: the block marker plus both delimiters of every closed run, merged
    /// where they touch, and never the prose in between.
    @Test func markersAreTheScaffoldingAndNothingElse() {
        #expect(MarkdownSyntax.markers("## Decisions") == [0..<3])
        #expect(MarkdownSyntax.markers("- a **b** c") == [0..<2, 4..<6, 7..<9])
        #expect(MarkdownSyntax.markers("plain prose").isEmpty)
        // A link dims its brackets and its whole target, and leaves the label alone.
        let link = "[docs](https://x.dev)"
        #expect(MarkdownSyntax.markers(link) == [0..<1, 5..<21])
        #expect(String(Array(link)[1..<5]) == "docs")
    }

    /// The whole point of Direction A: prose and list items share one left edge, and a wrapped line
    /// returns to that edge rather than to zero. Both fall out of one hanging indent per paragraph.
    @Test func everyLineOfProseStartsOnTheSameEdgeWhateverMarksIt() {
        let gutter = 6
        // The marker ends on the body edge, so the text after it starts there — whatever its width.
        for line in ["## Decisions", "- ship it", "1. first", "> she said", "- [ ] task"] {
            let indent = MarkdownSyntax.gutterIndent(line, gutter: gutter)
            let marker = MarkdownSyntax.blockMarker(line)!
            #expect(indent.first + marker.count == gutter,
                    "\(line) does not put its text on the body edge")
            #expect(indent.body == gutter, "\(line) does not wrap back to the body edge")
        }
        // And a line with no marker at all starts on that same edge. This is the one a character
        // attribute could never do: there is no character in front of a paragraph to pad.
        #expect(MarkdownSyntax.gutterIndent("We agreed to ship.", gutter: gutter) == (6, 6))
        #expect(MarkdownSyntax.gutterIndent("", gutter: gutter) == (6, 6))
    }

    /// Nesting still has to be visible, and a marker too wide for the gutter must not drag the
    /// whole document right — it overhangs on its own line instead.
    @Test func nestingMovesTheEdgeAndAnOversizeMarkerOverhangsAlone() {
        // Depth pushes the body edge right, and the wrapped lines follow it.
        let nested = MarkdownSyntax.gutterIndent("    - nested", gutter: 6)
        #expect(nested == (4, 10))
        // `- ` starts at column 4+4=8 and ends at 10, which is where its text and its wraps sit.
        #expect(nested.first + 4 + 2 == nested.body)

        // Seven columns of marker in a six-column gutter: clamped, and only this line is affected.
        #expect(MarkdownSyntax.gutterIndent("###### Deep", gutter: 6) == (0, 6))
    }

    /// The offsets the gutter and the dimming are applied at are character offsets, and an emoji is
    /// one character and several scalars. Getting this wrong does not look wrong — it puts the
    /// caret inside the emoji.
    @Test func markerOffsetsAreCharacterOffsetsToo() throws {
        let line = "## 👍 **done** 🎉"
        let characters = Array(line)
        #expect(MarkdownSyntax.blockMarker(line) == 0..<3)
        let markers = MarkdownSyntax.markers(line)
        #expect(markers == [0..<3, 5..<7, 11..<13])
        #expect(String(characters[markers[1].lowerBound..<markers[2].upperBound]) == "**done**")
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

    /// The offsets a checkbox is drawn at and a tick is applied to. `box` is the three characters of
    /// the box itself, so `box.lowerBound + 1` is the one character that changes, and `textStart` is
    /// where the item's own sentence begins.
    @Test func aTaskItemSaysWhereItsBoxAndItsTextAre() throws {
        let item = try #require(MarkdownSyntax.taskItem("  - [x] ship the gutter"))
        #expect(item.done)
        #expect(item.box == 4..<7)
        #expect(item.textStart == 8)
        let characters = Array("  - [x] ship the gutter")
        #expect(String(characters[item.box]) == "[x]")
        #expect(String(characters[item.textStart...]) == "ship the gutter")
    }

    /// ``MarkdownSyntax/blockMarker(_:)`` stays deliberately looser than ``MarkdownSyntax/taskItem(_:)``.
    /// Backspacing the space out of `- [ ] task` leaves `- [ ]task`, which is not a task item any
    /// more — but it is still five characters of marker that have to be deleted together, or
    /// unmaking a checkbox takes four presses of Delete.
    @Test func theGuttersMarkerIsLooserThanTheTaskListSpec() {
        #expect(MarkdownSyntax.blockMarker("- [ ]task") == 0..<5)
        #expect(MarkdownSyntax.taskItem("- [ ]task") == nil)
    }
}
