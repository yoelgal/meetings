import Foundation
import Testing

@testable import MeetingsCore

/// What a keystroke does to the text around it. Every case here is one the editor answers *while
/// somebody is typing*, so the inputs are half-finished on purpose and the failures that matter are
/// the ones where the caret ends up somewhere the user did not put it.
@Suite struct MarkdownEditingTests {
    /// The whole point of the follow-up: what the document became, and where the caret is in it.
    private func typed(_ before: String, _ after: String, caret: Int) -> (String, Range<Int>)? {
        guard let edit = MarkdownEditing.followUp(before: before, after: after, caret: caret)
        else { return nil }
        return (edit.applied(to: after), edit.selection)
    }

    // MARK: - Return continues a list, and ends it

    @Test func returnAtTheEndOfAnItemStartsTheNextOne() throws {
        let (text, caret) = try #require(typed("- ship it", "- ship it\n", caret: 10))
        #expect(text == "- ship it\n- ")
        #expect(caret == 12..<12)
    }

    @Test func anOrderedListCountsOn() throws {
        let (text, _) = try #require(typed("1. first", "1. first\n", caret: 9))
        #expect(text == "1. first\n2. ")
        // And it keeps whichever punctuation the author used.
        let (paren, _) = try #require(typed("3) third", "3) third\n", caret: 9))
        #expect(paren == "3) third\n4) ")
    }

    /// A ticked action does not breed more ticked actions. The next thing you write is not done.
    @Test func anActionContinuesUnticked() throws {
        let (text, _) = try #require(typed("- [x] shipped", "- [x] shipped\n", caret: 14))
        #expect(text == "- [x] shipped\n- [ ] ")
    }

    /// Return on an empty item is how everybody ends a list. An editor that answers it with a third
    /// empty bullet is one you fight.
    @Test func returnOnAnEmptyItemEndsTheList() throws {
        let (text, caret) = try #require(typed("- one\n- ", "- one\n- \n", caret: 9))
        #expect(text == "- one\n")
        #expect(caret == 6..<6)
    }

    @Test func returnOnProseIsLeftAlone() {
        #expect(MarkdownEditing.followUp(before: "we agreed", after: "we agreed\n", caret: 10) == nil)
        // A heading is not a list: Return after one starts a paragraph, not another heading.
        #expect(MarkdownEditing.followUp(before: "## Notes", after: "## Notes\n", caret: 9) == nil)
    }

    // MARK: - Shorthand that is not already markdown

    @Test func theActionBoxExpandsAsItIsTyped() throws {
        for shorthand in ["[]", "[ ]"] {
            let (text, caret) = try #require(
                typed(shorthand, shorthand + " ", caret: shorthand.count + 1)
            )
            #expect(text == "- [ ] ")
            #expect(caret == 6..<6)
        }
        let (ticked, _) = try #require(typed("[x]", "[x] ", caret: 4))
        #expect(ticked == "- [x] ")
    }

    @Test func theActionBoxKeepsItsIndentWhenItIsNested() throws {
        let (text, _) = try #require(typed("  []", "  [] ", caret: 5))
        #expect(text == "  - [ ] ")
    }

    /// `- `, `* `, `1. ` and `## ` are already the characters markdown wants, so there is nothing to
    /// rewrite — they become what they are by being drawn, not by being replaced. A follow-up here
    /// would be an edit the user did not ask for.
    @Test func theShorthandThatIsAlreadyMarkdownIsNotRewritten() {
        for (before, after) in [("-", "- "), ("*", "* "), ("1.", "1. "), ("#", "# "), ("##", "## ")] {
            #expect(MarkdownEditing.followUp(before: before, after: after, caret: after.count) == nil,
                    "\(after) is already markdown and must be left exactly as typed")
            #expect(MarkdownSyntax.blockMarker(after) != nil,
                    "\(after) has to read as a marker the moment the space lands")
        }
    }

    // MARK: - Backspace

    @Test func backspaceAtTheStartOfAnItemTakesTheWholeMarker() throws {
        let (text, caret) = try #require(typed("- ship it", "-ship it", caret: 1))
        #expect(text == "ship it")
        #expect(caret == 0..<0)
    }

    @Test func backspaceTakesAnActionBoxInOneGoRatherThanFourPresses() throws {
        let (text, _) = try #require(typed("- [ ] task", "- [ ]task", caret: 5))
        #expect(text == "task")
    }

    @Test func backspaceInsideTheProseIsJustABackspace() {
        #expect(MarkdownEditing.followUp(before: "- ship it", after: "- ship t", caret: 7) == nil)
    }

    // MARK: - Multi-byte content

    /// The editor turns every offset here into an `AttributedString.Index` with `offsetByCharacters`,
    /// so an offset counted in the wrong unit does not merely look wrong — it puts the caret inside
    /// an emoji. Every number this type produces is a **character** offset.
    @Test func offsetsSurviveEmojiAndCombiningMarks() throws {
        // Thirteen *characters*, nineteen UTF-8 bytes. Counted in bytes the follow-up below would
        // land six positions late, in the middle of the party popper.
        #expect(Array("- 👍 shipped 🎉").count == 13)
        #expect("- 👍 shipped 🎉".utf8.count == 19)
        let (text, caret) = try #require(typed("- 👍 shipped 🎉", "- 👍 shipped 🎉\n", caret: 14))
        #expect(text == "- 👍 shipped 🎉\n- ")
        #expect(caret == 16..<16)
        #expect(Array(text).count == 16)

        let bold = MarkdownEditing.toggle(.bold, in: "👍 done 🎉", selection: 2..<6)
        #expect(bold.applied(to: "👍 done 🎉") == "👍 **done** 🎉")
        #expect(String(Array(bold.applied(to: "👍 done 🎉"))[bold.selection]) == "done")
    }

    // MARK: - Inline formatting, as a toggle

    @Test func everyMarkWrapsASelectionAndKeepsItOnTheInnerText() throws {
        for (mark, wrapped) in [
            (MarkdownEditing.InlineMark.bold, "a **b** c"),
            (.italic, "a *b* c"),
            (.strikethrough, "a ~~b~~ c"),
            (.code, "a `b` c"),
        ] {
            let edit = MarkdownEditing.toggle(mark, in: "a b c", selection: 2..<3)
            #expect(edit.applied(to: "a b c") == wrapped, "\(mark) should wrap")
            #expect(Array(edit.applied(to: "a b c"))[edit.selection] == ["b"],
                    "\(mark) has to leave the selection on the text, so pressing it again undoes it")
        }
    }

    @Test func everyMarkUnwrapsTextItAlreadyWrapped() {
        for (mark, wrapped) in [
            (MarkdownEditing.InlineMark.bold, "a **b** c"),
            (.italic, "a *b* c"),
            (.strikethrough, "a ~~b~~ c"),
            (.code, "a `b` c"),
        ] {
            // Selected from the inside — the text, not its delimiters.
            let inner = MarkdownEditing.toggle(mark, in: wrapped, selection: (2 + mark.open.count)..<(3 + mark.open.count))
            #expect(inner.applied(to: wrapped) == "a b c", "\(mark) has to toggle off from inside")
            // And from the outside, delimiters included.
            let outer = MarkdownEditing.toggle(
                mark, in: wrapped, selection: 2..<(wrapped.count - 2)
            )
            #expect(outer.applied(to: wrapped) == "a b c", "\(mark) has to toggle off from outside")
        }
    }

    /// Pressing it twice in a row has to land back where it started, or the shortcut is a one-way
    /// door and the only way out is undo.
    @Test func togglingTwiceIsTheIdentity() {
        for mark in MarkdownEditing.InlineMark.allCases where mark != .link {
            let first = MarkdownEditing.toggle(mark, in: "a b c", selection: 2..<3)
            let once = first.applied(to: "a b c")
            let second = MarkdownEditing.toggle(mark, in: once, selection: first.selection)
            #expect(second.applied(to: once) == "a b c", "\(mark) does not toggle back")
        }
    }

    @Test func withNoSelectionThePairGoesInAndTheCaretLandsBetweenTheHalves() {
        let edit = MarkdownEditing.toggle(.bold, in: "", selection: 0..<0)
        #expect(edit.applied(to: "") == "****")
        #expect(edit.selection == 2..<2)
    }

    /// A link is the one that does not put the caret on the label: the label is what you selected,
    /// and the thing still missing is where it goes.
    @Test func aLinkWrapsTheLabelAndSelectsThePlaceholderTarget() {
        let edit = MarkdownEditing.toggle(.link, in: "docs", selection: 0..<4)
        let linked = edit.applied(to: "docs")
        #expect(linked == "[docs](url)")
        #expect(String(Array(linked)[edit.selection]) == "url")

        let off = MarkdownEditing.toggle(.link, in: linked, selection: 1..<5)
        #expect(off.applied(to: linked) == "docs")
    }

    /// The toolbar draws a pressed button from this, and `toggle` decides which way it is going
    /// from the same answer — so the two cannot disagree about whether the selection is bold.
    @Test func theActiveStateAgreesWithWhichWayTheToggleGoes() {
        for mark in MarkdownEditing.InlineMark.allCases where mark != .link {
            #expect(!MarkdownEditing.isActive(mark, in: "a b c", selection: 2..<3),
                    "\(mark) is not on over plain text")
            let wrapped = MarkdownEditing.toggle(mark, in: "a b c", selection: 2..<3).applied(to: "a b c")
            let inner = (2 + mark.open.count)..<(3 + mark.open.count)
            #expect(MarkdownEditing.isActive(mark, in: wrapped, selection: inner),
                    "\(mark) has to read as on once it is applied")
            // Selecting the delimiters too is the same intent and reads the same way.
            #expect(MarkdownEditing.isActive(mark, in: wrapped, selection: 2..<(wrapped.count - 2)))
            // And turning it off turns the button off.
            let plain = MarkdownEditing.toggle(mark, in: wrapped, selection: inner).applied(to: wrapped)
            #expect(!MarkdownEditing.isActive(mark, in: plain, selection: 2..<3))
        }
    }

    // MARK: - The slash menu

    @Test func aSlashOpensTheMenuOnlyWhereItStartsAWord() {
        #expect(MarkdownEditing.slashQuery(in: "/", caret: 1) == 0..<1)
        #expect(MarkdownEditing.slashQuery(in: "/h2", caret: 3) == 0..<3)
        #expect(MarkdownEditing.slashQuery(in: "notes /h", caret: 8) == 6..<8)
        // The two that would otherwise pop a menu mid-sentence.
        #expect(MarkdownEditing.slashQuery(in: "and/or", caret: 6) == nil)
        #expect(MarkdownEditing.slashQuery(in: "https://x", caret: 9) == nil)
        #expect(MarkdownEditing.slashQuery(in: "no slash here", caret: 13) == nil)
        // A space ends the query: `/h2 then` is prose again.
        #expect(MarkdownEditing.slashQuery(in: "/h2 then", caret: 8) == nil)
    }

    @Test func typingNarrowsTheMenu() {
        #expect(MarkdownEditing.slashMatches("").count == MarkdownEditing.slashCommands.count)
        #expect(MarkdownEditing.slashMatches("/h").map(\.id) == ["h1", "h2", "h3"])
        #expect(MarkdownEditing.slashMatches("h2").map(\.id) == ["h2"])
        #expect(MarkdownEditing.slashMatches("todo").map(\.id) == ["todo"])
        // Matched on the title too, because "action" is what the item is called.
        #expect(MarkdownEditing.slashMatches("action").map(\.id) == ["todo"])
        #expect(MarkdownEditing.slashMatches("zzz").isEmpty)
    }

    @Test func choosingACommandReplacesTheQueryThatSummonedIt() throws {
        let h2 = try #require(MarkdownEditing.slashCommands.first { $0.id == "h2" })
        let edit = MarkdownEditing.insert(h2, over: 0..<3, in: "/h2")
        #expect(edit.applied(to: "/h2") == "## ")
        #expect(edit.selection == 3..<3)
    }

    /// One transform behind every surface. The menu, and anything else that offers "turn into",
    /// have to produce the same text or they are two features wearing one name.
    @Test func aBlockCommandReplacesWhateverMarkerTheLineAlreadyHad() throws {
        let h2 = try #require(MarkdownEditing.slashCommands.first { $0.id == "h2" })
        // H1 to H2 is one step, not a `## ` glued onto a `# `.
        let promoted = MarkdownEditing.applyBlock(h2, in: "# Notes", replacing: 7..<7)
        #expect(promoted.applied(to: "# Notes") == "## Notes")

        let bullet = try #require(MarkdownEditing.slashCommands.first { $0.id == "bullet" })
        #expect(MarkdownEditing.applyBlock(bullet, in: "- [ ] task", replacing: 10..<10)
            .applied(to: "- [ ] task") == "- task")
        // Indentation is structure and survives.
        #expect(MarkdownEditing.applyBlock(bullet, in: "    plain", replacing: 9..<9)
            .applied(to: "    plain") == "    - plain")
    }

    @Test func aBlockCommandOverSeveralLinesTakesThemAll() throws {
        let number = try #require(MarkdownEditing.slashCommands.first { $0.id == "number" })
        let edit = MarkdownEditing.applyBlock(number, in: "one\ntwo\nthree", replacing: 1..<9)
        #expect(edit.applied(to: "one\ntwo\nthree") == "1. one\n2. two\n3. three")
    }

    /// A blank box in a menu is invisible until somebody opens it, and by then it has shipped.
    @Test func everyCommandNamesASymbolAndAShorthand() {
        for command in MarkdownEditing.slashCommands {
            #expect(!command.symbol.isEmpty)
            #expect(command.shorthand == "/\(command.id)")
            #expect(["Headings", "Lists", "Blocks"].contains(command.group))
        }
        #expect(MarkdownEditing.blockCommands.filter { !$0.replacesMarker }.isEmpty,
                "the turn-into group can only offer constructs that replace a line's marker")
    }

    // MARK: - Ticking a box

    /// Clicking a checkbox is one character, and it goes through the same ``MarkdownEditing/Edit``
    /// every keystroke's follow-up does — which is what puts it on the undo stack and provokes the
    /// autosave rather than writing to a column of its own.
    @Test func tickingABoxChangesOneCharacter() throws {
        let text = "# Standup\n\n- [ ] anchor live notes\n- [x] ship the gutter\n"
        let box = try #require(text.range(of: "- [ ] anchor"))
        let offset = text.distance(from: text.startIndex, to: box.lowerBound) + 3

        let ticked = try #require(MarkdownEditing.toggleTask(in: text, at: offset))
        #expect(ticked.replacement == "x")
        #expect(ticked.range.count == 1)
        #expect(ticked.applied(to: text)
            == "# Standup\n\n- [x] anchor live notes\n- [x] ship the gutter\n")

        // And back again, from anywhere on the line — a click lands on the box, but the transform
        // is about the line rather than about the character that was hit.
        let done = try #require(text.range(of: "- [x] ship"))
        let anywhere = text.distance(from: text.startIndex, to: done.lowerBound) + 9
        let unticked = try #require(MarkdownEditing.toggleTask(in: text, at: anywhere))
        #expect(unticked.replacement == " ")
        #expect(unticked.applied(to: text)
            == "# Standup\n\n- [ ] anchor live notes\n- [ ] ship the gutter\n")
    }

    /// The caret lands in the sentence rather than inside the brackets: a click in a text view moves
    /// the insertion point wherever it hit, and inside a marker is not somewhere to leave it.
    @Test func tickingLeavesTheCaretAtTheStartOfTheAction() throws {
        let edit = try #require(MarkdownEditing.toggleTask(in: "- [ ] ship it", at: 3))
        #expect(edit.selection == 6..<6)
    }

    @Test func aLineThatIsNotATaskItemHasNothingToToggle() {
        for text in ["just prose", "- an ordinary bullet", "## Actions", ""] {
            #expect(MarkdownEditing.toggleTask(in: text, at: 2) == nil, "\(text) has no box")
        }
    }

    // MARK: - Where the toolbar goes

    /// The defect this function exists for. The toolbar is centred on the selection and is about
    /// 280 pt wide, so a selection starting at the text's left edge computed a negative origin —
    /// outside the editor, outside the document column, and past the left edge of the split view's
    /// detail pane, which clips. Nothing bounded it, so those points were simply not drawn.
    @Test func aFloatingSurfaceIsNeverPushedOutsideTheEditor() {
        let toolbar = CGSize(width: 280, height: 30)

        // A selection of one word at the start of a line: centring alone would put it at −95.
        let atTheEdge = MarkdownEditing.floating(
            over: CGRect(x: 45, y: 120, width: 40, height: 18), size: toolbar, in: 520
        )
        #expect(atTheEdge.x == 0, "clamped to the editor's left edge rather than off it")

        // And the same at the other end.
        let atTheFarEdge = MarkdownEditing.floating(
            over: CGRect(x: 470, y: 120, width: 45, height: 18), size: toolbar, in: 520
        )
        #expect(atTheFarEdge.x == 240, "clamped so its right edge lands on the editor's")

        // An editor narrower than the surface has no valid range at all, and the answer is the left
        // edge — not a negative x from clamping to a negative upper bound.
        let cramped = MarkdownEditing.floating(
            over: CGRect(x: 10, y: 120, width: 20, height: 18), size: toolbar, in: 200
        )
        #expect(cramped.x == 0)
    }

    @Test func aFloatingSurfaceSitsOverTheTextAndFlipsWhenThereIsNoRoom() {
        let toolbar = CGSize(width: 280, height: 30)

        let roomy = MarkdownEditing.floating(
            over: CGRect(x: 200, y: 120, width: 60, height: 18), size: toolbar, in: 520
        )
        #expect(roomy.below == false)
        #expect(roomy.y == 84, "sits above the selection, its own height plus the gap")
        #expect(roomy.x == 90, "and centred on it")

        // The first line of the document has nothing above it, and a toolbar off the top edge is a
        // toolbar you cannot press.
        let atTheTop = MarkdownEditing.floating(
            over: CGRect(x: 200, y: 6, width: 60, height: 18), size: toolbar, in: 520
        )
        #expect(atTheTop.below)
        #expect(atTheTop.y == 30, "under the selection instead")
    }

    /// A caret has no width, and a surface that refused to place itself over one would be a menu
    /// that never opened — which is the same class of failure as a toolbar that never appears.
    @Test func aZeroSizedAnchorStillGetsAPlacement() {
        let placement = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 200, width: 0, height: 18),
            size: CGSize(width: 300, height: 220), in: 520
        )
        #expect(placement.below, "no room above for a 220 pt menu at y = 200")
        #expect(placement.y == 224)
        #expect(placement.x == 0)
    }
}
