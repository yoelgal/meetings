import Foundation
import Testing

@testable import MeetingsCore

/// Every formatting transform the editor offers, against every case that matters: where the
/// selection is, what markup is already there, and what happens when the same button is pressed
/// twice.
///
/// It is a matrix rather than a list of anecdotes because the two defects that provoked it were
/// unrelated to each other — bold lit the italic button, and a list marker deleted the word it was
/// asked for — and two unrelated defects in one small surface is a layer that was never tested as a
/// grid. **Both** the resulting string and the resulting selection are asserted throughout: a
/// transform that produces the right text and leaves the caret somewhere random is the failure the
/// user actually reports, and it is invisible to a test that only reads the document.
@Suite struct MarkdownTransformMatrixTests {
    private func selected(_ text: String, _ range: Range<Int>) -> String {
        String(Array(text)[range])
    }

    private func toggling(
        _ mark: MarkdownEditing.InlineMark, _ text: String, _ selection: Range<Int>
    ) -> (text: String, selection: Range<Int>) {
        let edit = MarkdownEditing.toggle(mark, in: text, selection: selection)
        return (edit.applied(to: text), edit.selection)
    }

    private func applying(
        _ id: String, _ text: String, _ range: Range<Int>
    ) -> (text: String, selection: Range<Int>) {
        let command = MarkdownEditing.slashCommands.first { $0.id == id }!
        let edit = MarkdownEditing.applyBlock(command, in: text, over: range)
        return (edit.applied(to: text), edit.selection)
    }

    /// The commands that mark a *line*, which is every case where the selection has to survive.
    private var markerCommands: [MarkdownEditing.SlashCommand] {
        MarkdownEditing.slashCommands.filter(\.replacesMarker)
    }

    // MARK: - The reported defect: `**bold**` contains `*bold*`

    /// "If I highlight some text and press on the bold icon, it also activates the italics icon."
    ///
    /// `**` and `*` are different delimiter runs, and an active-state that answers "is this italic"
    /// by looking for one asterisk says yes to every bold word in the document.
    @Test func strongEmphasisIsNotEmphasis() {
        let bold = "the **shipped** part"
        #expect(MarkdownEditing.isActive(.bold, in: bold, selection: 6..<13))
        #expect(!MarkdownEditing.isActive(.italic, in: bold, selection: 6..<13),
                "bold is not italic, and the toolbar cannot draw both buttons pressed")

        let italic = "the *shipped* part"
        #expect(MarkdownEditing.isActive(.italic, in: italic, selection: 5..<12))
        #expect(!MarkdownEditing.isActive(.bold, in: italic, selection: 5..<12))

        // `***x***` genuinely is both, and that is the one case where both buttons are right.
        let both = "the ***shipped*** part"
        #expect(MarkdownEditing.isActive(.bold, in: both, selection: 7..<14))
        #expect(MarkdownEditing.isActive(.italic, in: both, selection: 7..<14))
    }

    /// The same ambiguity in the underscore forms, which the editor's parser has always read as
    /// emphasis — so the toolbar has to as well, or the button lies about text the document draws
    /// in italic.
    @Test func underscoresAreTheSameTwoRuns() {
        #expect(MarkdownEditing.isActive(.bold, in: "the __shipped__ part", selection: 6..<13))
        #expect(!MarkdownEditing.isActive(.italic, in: "the __shipped__ part", selection: 6..<13))
        #expect(MarkdownEditing.isActive(.italic, in: "the _shipped_ part", selection: 5..<12))
        #expect(!MarkdownEditing.isActive(.bold, in: "the _shipped_ part", selection: 5..<12))

        // Taking one off works, and puts back the canonical delimiter. Normalising `_` to `*` is
        // the deliberate half of that: a toggle knows what emphasis *is*, not which of the two
        // spellings the author typed.
        let off = toggling(.italic, "the _shipped_ part", 5..<12)
        #expect(off.text == "the shipped part")
        #expect(off.selection == 4..<11)
        #expect(toggling(.italic, off.text, off.selection).text == "the *shipped* part")

        // An underscore inside a word is not a delimiter, so an identifier is not italic.
        #expect(!MarkdownEditing.isActive(.italic, in: "meeting_store_open", selection: 8..<13))
        #expect(toggling(.italic, "meeting_store_open", 8..<13).text == "meeting_*store*_open")
    }

    /// Nothing inside a backticked span is markup, so the buttons over one read off — and pressing
    /// one twice still has to come back off, which is the case a parser alone cannot answer.
    @Test func markupInsideCodeIsInert() {
        let text = "run `git commit` now"
        #expect(MarkdownEditing.isActive(.code, in: text, selection: 5..<15))
        #expect(!MarkdownEditing.isActive(.bold, in: text, selection: 9..<15))

        let bolded = toggling(.bold, text, 9..<15)
        #expect(bolded.text == "run `git **commit**` now")
        #expect(toggling(.bold, bolded.text, bolded.selection).text == text,
                "a second press takes off the pair the first one typed, parser or no parser")
    }

    // MARK: - Every mark, at every position on a line

    @Test func everyMarkWrapsWhereverTheSelectionSits() {
        let text = "one two three"
        let expected: [MarkdownEditing.InlineMark: (String, String, String, String)] = [
            .bold: ("**one** two three", "one **two** three", "one two **three**", "one ****two three"),
            .italic: ("*one* two three", "one *two* three", "one two *three*", "one **two three"),
            .strikethrough: ("~~one~~ two three", "one ~~two~~ three", "one two ~~three~~", "one ~~~~two three"),
            .code: ("`one` two three", "one `two` three", "one two `three`", "one ``two three"),
            .link: ("[one](url) two three", "one [two](url) three", "one two [three](url)", "one [](url)two three"),
        ]
        for (mark, wrapped) in expected {
            let start = toggling(mark, text, 0..<3)
            #expect(start.text == wrapped.0, "\(mark) at the start of a line")
            #expect(selected(start.text, start.selection) == (mark == .link ? "url" : "one"))

            let middle = toggling(mark, text, 4..<7)
            #expect(middle.text == wrapped.1, "\(mark) in the middle")
            #expect(selected(middle.text, middle.selection) == (mark == .link ? "url" : "two"))

            let end = toggling(mark, text, 8..<13)
            #expect(end.text == wrapped.2, "\(mark) at the end")
            #expect(selected(end.text, end.selection) == (mark == .link ? "url" : "three"))

            // A caret, which is somebody about to type inside the pair.
            let caret = toggling(mark, text, 4..<4)
            #expect(caret.text == wrapped.3, "\(mark) at a caret")
            #expect(caret.selection == (mark == .link ? 7..<10 : (4 + mark.open.count)..<(4 + mark.open.count)))
        }
    }

    /// A double-click takes the space after the word with it, and `**word **` is not bold —
    /// CommonMark wants a non-space before the closing run. The commonest selection in the editor
    /// would otherwise produce four literal asterisks.
    @Test func theSpaceARoundASelectionStaysOutsideTheMarkers() {
        let trailing = toggling(.bold, "one two three", 4..<8)
        #expect(trailing.text == "one **two** three")
        #expect(selected(trailing.text, trailing.selection) == "two")

        let both = toggling(.italic, "one two three", 3..<8)
        #expect(both.text == "one *two* three")

        // Whitespace on its own is not a mistyped word, and collapsing it would move the edit.
        #expect(toggling(.bold, "one two", 3..<4).text == "one** **two")
    }

    // MARK: - Selections that already touch markup

    @Test func aSelectionInsideExactlyOnOrOverlappingMarkupToggles() {
        let text = "a **bold** c"
        // Inside the pair — the text, not its delimiters.
        let inside = toggling(.bold, text, 4..<8)
        #expect(inside.text == "a bold c")
        #expect(inside.selection == 2..<6)
        // Exactly the whole run, delimiters included: the same intent.
        let exact = toggling(.bold, text, 2..<10)
        #expect(exact.text == "a bold c")
        #expect(exact.selection == 2..<6)
        // A caret inside the word is enough to read as on, and a caret past the closing run is not.
        #expect(MarkdownEditing.isActive(.bold, in: text, selection: 6..<6))
        #expect(MarkdownEditing.isActive(.bold, in: text, selection: 4..<4))
        #expect(!MarkdownEditing.isActive(.bold, in: text, selection: 10..<10))
        #expect(!MarkdownEditing.isActive(.bold, in: text, selection: 1..<1))

        // Half in and half out is not the run, so it wraps what was highlighted.
        let overlapping = toggling(.bold, text, 0..<6)
        #expect(overlapping.text == "**a **bo**ld** c")
        #expect(selected(overlapping.text, overlapping.selection) == "a **bo")
        #expect(!MarkdownEditing.isActive(.bold, in: text, selection: 0..<6))
    }

    @Test func nestedMarkupComesApartOneLayerAtATime() {
        let both = "a ***both*** c"
        #expect(toggling(.bold, both, 5..<9).text == "a *both* c")
        #expect(toggling(.italic, both, 5..<9).text == "a **both** c")

        // The inner run of a mixed pair is the one that answers for the selection inside it.
        let mixed = "a **bold with _em_ inside** c"
        #expect(MarkdownEditing.isActive(.italic, in: mixed, selection: 15..<17))
        #expect(MarkdownEditing.isActive(.bold, in: mixed, selection: 15..<17))
        let unemphasised = toggling(.italic, mixed, 15..<17)
        #expect(unemphasised.text == "a **bold with em inside** c")
        #expect(selected(unemphasised.text, unemphasised.selection) == "em")
        #expect(toggling(.bold, mixed, 15..<17).text == "a bold with _em_ inside c")

        // A different mark over an existing one layers rather than replacing it.
        #expect(toggling(.strikethrough, "a **bold** c", 4..<8).text == "a **~~bold~~** c")
        #expect(toggling(.code, "a *it* c", 3..<5).text == "a *`it`* c")
        #expect(toggling(.bold, "a *it* c", 3..<5).text == "a ***it*** c")
    }

    /// No inline run closes across a line break, so a selection that spans one is inside nothing —
    /// it is wrapped whole. The pair is then adjacent to the selection, which is what lets a second
    /// press take it back off.
    ///
    /// ponytail: wrapping each line separately would be more correct markdown and a second
    /// selection model to keep in step. Obsidian does exactly this, and the round trip is what
    /// stops it being a one-way door.
    @Test func aSelectionAcrossLinesIsWrappedWhole() {
        let wrapped = toggling(.bold, "one\ntwo", 0..<7)
        #expect(wrapped.text == "**one\ntwo**")
        #expect(wrapped.selection == 2..<9)
        #expect(MarkdownEditing.isActive(.bold, in: wrapped.text, selection: wrapped.selection))
        #expect(toggling(.bold, wrapped.text, wrapped.selection).text == "one\ntwo")
        // And it is not read as markup for the line the caret is actually on.
        #expect(!MarkdownEditing.isActive(.bold, in: wrapped.text, selection: 3..<4))
    }

    // MARK: - The properties, over the whole matrix

    /// Every case in the grid, for the round trip and for the agreement between the button and the
    /// shortcut. A transform is a toggle or it is a one-way door whose only exit is undo.
    private static let inlineMatrix: [(String, Range<Int>)] = [
        ("one two three", 0..<3), ("one two three", 4..<7), ("one two three", 8..<13),
        ("one two three", 4..<4), ("one two three", 0..<13), ("one two three", 4..<8),
        ("one\ntwo", 0..<7), ("one\ntwo", 4..<7),
        ("a **bold** c", 4..<8), ("a **bold** c", 2..<10), ("a **bold** c", 0..<6),
        ("a *it* c", 3..<5), ("a ***both*** c", 5..<9),
        ("a **bold with _em_ inside** c", 15..<17),
        ("run `git commit` now", 9..<15),
        ("", 0..<0), ("   ", 1..<2),
        ("👍 done 🎉", 2..<6), ("👨‍👩‍👧 family", 2..<8), ("cafe\u{301} au lait", 0..<4),
    ]

    @Test func togglingTwiceReturnsTheOriginalCharacterForCharacter() {
        for mark in MarkdownEditing.InlineMark.allCases {
            // Underscore emphasis is the one thing a round trip normalises rather than restores:
            // taking `_em_` off and putting it back writes `*em*`, because a toggle knows what
            // emphasis is and not which of its two spellings the author typed. Asserted as its own
            // case in `underscoresAreTheSameTwoRuns`.
            for (text, selection) in Self.inlineMatrix where !text.contains("_") {
                let once = MarkdownEditing.toggle(mark, in: text, selection: selection)
                let intermediate = once.applied(to: text)
                // A link puts the selection on the placeholder target, because that is the half
                // still missing — so the second press is aimed at the label it just made.
                let again = mark == .link && !MarkdownEditing.isActive(mark, in: text, selection: selection)
                    ? label(in: intermediate, of: once.selection)
                    : once.selection
                let back = MarkdownEditing.toggle(mark, in: intermediate, selection: again)
                #expect(back.applied(to: intermediate) == text,
                        "\(mark) on \(text.debugDescription) at \(selection) does not come back off")
            }
        }
    }

    /// `[label](url)` with the selection on the target: where the label sits.
    private func label(in text: String, of target: Range<Int>) -> Range<Int> {
        let characters = Array(text)
        var open = target.lowerBound - 2
        while open > 0, characters[open] != "[" { open -= 1 }
        return (open + 1)..<(target.lowerBound - 2)
    }

    @Test func theActiveStateAndTheToggleNeverDisagree() {
        for mark in MarkdownEditing.InlineMark.allCases {
            for (text, selection) in Self.inlineMatrix {
                let on = MarkdownEditing.isActive(mark, in: text, selection: selection)
                let edit = MarkdownEditing.toggle(mark, in: text, selection: selection)
                let after = edit.applied(to: text)
                // Pressed means the toggle takes it off, which is a document that got shorter.
                #expect(on == (after.count < text.count),
                        "\(mark) on \(text.debugDescription) at \(selection) draws \(on) and does the opposite")
                // And whichever way it went, the button now reads the other way.
                let selection = mark == .link && !on ? label(in: after, of: edit.selection) : edit.selection
                #expect(MarkdownEditing.isActive(mark, in: after, selection: selection) == !on,
                        "\(mark) on \(text.debugDescription) does not change the button it is drawn from")
            }
        }
    }

    // MARK: - The reported defect: a block marker eating the selection

    /// "If I highlight a word at the end of a sentence and press on the bullet list option, it
    /// deletes the word and puts a bullet at the start of the sentence."
    ///
    /// A block marker applies to the **line**. The toolbar hands over a selection, and the transform
    /// read it as a span to swallow — so the word went and the bullet landed at the start of the
    /// sentence, exactly as reported.
    @Test func aBlockMarkerNeverEatsTheSelectionItWasAskedFor() {
        let text = "we shipped the gutter"
        for command in markerCommands {
            for (name, range) in [("start", 0..<2), ("middle", 3..<10), ("end", 15..<21)] {
                let result = applying(command.id, text, range)
                #expect(result.text == command.insertion + text,
                        "\(command.id) at the \(name) of the line must only add its marker")
                #expect(selected(result.text, result.selection) == selected(text, range),
                        "\(command.id) at the \(name) has to leave the highlighted words selected")
                #expect(result.selection
                    == (range.lowerBound + command.insertion.count)..<(range.upperBound + command.insertion.count))
            }
        }
    }

    @Test func everyBlockCommandAtACaretPutsTheCaretBackInTheProse() {
        for command in markerCommands {
            let width = command.insertion.count
            for caret in [0, 3, 21] {
                let result = applying(command.id, "we shipped the gutter", caret..<caret)
                #expect(result.text == command.insertion + "we shipped the gutter")
                #expect(result.selection == (caret + width)..<(caret + width),
                        "\(command.id) has to move the caret with the text under it")
            }
        }
    }

    // MARK: - Lines that already are something

    @Test func aMarkerReplacesTheMarkerTheLineAlreadyHad() {
        let cases: [(String, String, Range<Int>, String, Range<Int>)] = [
            ("number", "- item", 2..<6, "1. item", 3..<7),
            ("bullet", "1. item", 3..<7, "- item", 2..<6),
            ("bullet", "## Title", 3..<8, "- Title", 2..<7),
            ("h2", "# Title", 2..<7, "## Title", 3..<8),
            ("bullet", "- [ ] task", 6..<10, "- task", 2..<6),
            ("number", "- [ ] task", 6..<10, "1. task", 3..<7),
            ("h2", "> quoted", 2..<8, "## quoted", 3..<9),
            ("todo", "- item", 2..<6, "- [ ] item", 6..<10),
            ("number", "  - item", 4..<8, "  1. item", 5..<9),
            ("quote", "### Notes", 4..<9, "> Notes", 2..<7),
        ]
        for (id, before, selection, after, moved) in cases {
            let result = applying(id, before, selection)
            #expect(result.text == after, "\(id) on \(before): markers replace, they do not stack")
            #expect(result.selection == moved, "\(id) on \(before): the text keeps its selection")
            #expect(selected(result.text, result.selection) == selected(before, selection))
        }
    }

    /// The same button pressed twice, which is how anybody unmakes a heading they did not want.
    @Test func askingForTheMarkerALineAlreadyCarriesTakesItOff() {
        for command in markerCommands {
            let once = applying(command.id, "the line", 4..<8)
            let twice = applying(command.id, once.text, once.selection)
            #expect(twice.text == "the line", "\(command.id) does not come back off")
            #expect(twice.selection == 4..<8, "\(command.id) loses the selection on the way back")
        }
        // A bullet is not an action and an action is not a bullet, so neither strips the other.
        #expect(applying("bullet", "- [ ] task", 6..<10).text == "- task")
        #expect(applying("todo", "- task", 2..<6).text == "- [ ] task")
        // Nor is one heading level another.
        #expect(applying("h3", "# Title", 2..<7).text == "### Title")
    }

    @Test func emptyWhitespaceAndMarkerOnlyLines() {
        let cases: [(String, String, Range<Int>, String, Range<Int>)] = [
            ("bullet", "", 0..<0, "- ", 2..<2),
            ("todo", "", 0..<0, "- [ ] ", 6..<6),
            // Indentation is structure: the marker goes after it, not in front of it.
            ("quote", "   ", 3..<3, "   > ", 5..<5),
            ("h2", "\t", 1..<1, "\t## ", 4..<4),
            // A line that is only a marker is somebody mid-item, and taking their bullet away as
            // they reach for the menu is not a toggle they asked for.
            ("bullet", "- ", 2..<2, "- ", 2..<2),
            ("todo", "- [ ] ", 6..<6, "- [ ] ", 6..<6),
            ("number", "- ", 2..<2, "1. ", 3..<3),
        ]
        for (id, before, caret, after, moved) in cases {
            let result = applying(id, before, caret)
            #expect(result.text == after, "\(id) on \(before.debugDescription)")
            #expect(result.selection == moved, "\(id) on \(before.debugDescription) put the caret adrift")
        }
    }

    // MARK: - Several lines at once

    @Test func aBlockCommandOverSeveralLinesMarksEachOfThem() {
        let text = "alpha\nbeta\ngamma"
        let numbered = applying("number", text, 2..<13)
        #expect(numbered.text == "1. alpha\n2. beta\n3. gamma")
        #expect(numbered.selection == 5..<22)
        // The markers inside a multi-line selection join it, but its ends still hold the same two
        // characters they were dragged over.
        #expect(selected(numbered.text, numbered.selection).hasPrefix("pha"))
        #expect(selected(numbered.text, numbered.selection).hasSuffix("ga"))

        // Every line loses the marker it had, and the numbering counts from where it was asked for.
        let mixed = applying("number", "- one\n## two\nthree", 0..<18)
        #expect(mixed.text == "1. one\n2. two\n3. three")

        // A selection that ends on a line break is the line it ends, not the one after it.
        #expect(applying("bullet", "one\ntwo", 0..<4).text == "- one\ntwo")
        // And the whole document at once still comes back off in one press.
        let bulleted = applying("bullet", text, 0..<16)
        #expect(bulleted.text == "- alpha\n- beta\n- gamma")
        #expect(applying("bullet", bulleted.text, bulleted.selection).text == text)
    }

    // MARK: - The two that are not markers

    /// `code` and `divider` drop text in at the caret rather than marking a line, so they are the
    /// two commands that behave like typing — including replacing a selection, which is what typing
    /// does.
    @Test func theInsertionsThatAreNotMarkers() {
        let cases: [(String, String, Range<Int>, String, Range<Int>)] = [
            ("code", "note ", 5..<5, "note `code`", 11..<11),
            ("code", "one two", 4..<7, "one `code`", 10..<10),
            // A rule that is not at the start of a line is three hyphens in a sentence.
            ("divider", "", 0..<0, "---\n", 4..<4),
            ("divider", "we agreed ", 10..<10, "we agreed \n---\n", 15..<15),
        ]
        for (id, before, range, after, moved) in cases {
            let result = applying(id, before, range)
            #expect(result.text == after, "\(id) on \(before.debugDescription)")
            #expect(result.selection == moved, "\(id) on \(before.debugDescription) put the caret adrift")
        }
    }

    // MARK: - The slash menu and the toolbar, through one transform

    /// The menu swallows the `/query` that summoned it; the toolbar keeps the selection it was
    /// given. Both then go through the same transform, so "what does Heading 2 do to this line" has
    /// one answer.
    @Test func theMenuSwallowsItsQueryAndTheToolbarKeepsItsSelection() {
        let h2 = MarkdownEditing.slashCommands.first { $0.id == "h2" }!
        let bare = MarkdownEditing.insert(h2, over: 0..<3, in: "/h2")
        #expect(bare.applied(to: "/h2") == "## ")
        #expect(bare.selection == 3..<3)

        let midLine = MarkdownEditing.slashCommands.first { $0.id == "bullet" }!
        let after = MarkdownEditing.insert(midLine, over: 6..<13, in: "notes /bullet")
        #expect(after.applied(to: "notes /bullet") == "- notes ")
        #expect(after.selection == 8..<8)

        // The query goes even for the commands that are not markers.
        let divider = MarkdownEditing.slashCommands.first { $0.id == "divider" }!
        let ruled = MarkdownEditing.insert(divider, over: 6..<14, in: "notes /divider")
        #expect(ruled.applied(to: "notes /divider") == "notes \n---\n")

        // And a command chosen on a line that already has a marker keeps it to one marker.
        let listed = MarkdownEditing.insert(midLine, over: 2..<9, in: "# /bullet")
        #expect(listed.applied(to: "# /bullet") == "- ")
    }

    /// The app and the CLI must not disagree about what a checkbox is: `/todo` writes the line, and
    /// ``MarkdownActions`` is what `meetings actions list` reads back out of the document.
    @Test func theActionTransformWritesWhatTheActionParserReads() {
        let made = applying("todo", "call Sam", 0..<8)
        #expect(made.text == "- [ ] call Sam")
        #expect(made.text == MarkdownActions.rendered(Action(text: "call Sam", done: false)))
        #expect(MarkdownActions.parse(made.text).map(\.text) == ["call Sam"])
        #expect(MarkdownActions.parse(made.text).map(\.done) == [false])
        #expect(MarkdownSyntax.taskItem(made.text) != nil)

        // And ticking the box the transform wrote is the one character the parser reads as done.
        let ticked = MarkdownEditing.toggleTask(in: made.text, at: 3)!
        #expect(MarkdownActions.parse(ticked.applied(to: made.text)).map(\.done) == [true])
    }

    // MARK: - Multi-byte content

    /// Every offset in this file is a **character** offset. Counted in bytes or UTF-16 units, a
    /// transform lands inside an emoji — and a selection that survives the transform textually but
    /// not positionally is the same bug wearing a different coat.
    @Test func offsetsSurviveEmojiZWJSequencesAndCombiningMarks() {
        for text in ["👍 done 🎉", "👨‍👩‍👧 family", "cafe\u{301} au lait", "🇬🇧 flag"] {
            let characters = Array(text)
            let word = 2..<min(6, characters.count)
            let bolded = toggling(.bold, text, word)
            #expect(selected(bolded.text, bolded.selection) == selected(text, word),
                    "\(text) lost its selection to bold")
            #expect(toggling(.bold, bolded.text, bolded.selection).text == text)

            for command in markerCommands {
                let marked = applying(command.id, text, word)
                #expect(marked.text == command.insertion + text, "\(command.id) mangled \(text)")
                #expect(selected(marked.text, marked.selection) == selected(text, word),
                        "\(command.id) lost the selection in \(text)")
            }
        }
    }
}
