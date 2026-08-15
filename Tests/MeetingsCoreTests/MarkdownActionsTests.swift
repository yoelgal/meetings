import Foundation
import MarkdownEngine
import Testing

@testable import MeetingsCore

/// The write-up is the record for actions, so this is the parser that decides what somebody owes.
/// Everything it answers is a pure function over a string, which is the whole reason the decision
/// lives in `MeetingsCore` rather than in the view that draws the checkbox.
@Suite struct MarkdownActionsTests {
    // MARK: - What is a task list item

    /// GFM's own spelling, and all of it: the three bullet markers, ordered items, indentation, and
    /// `x` in either case.
    @Test func everyGFMSpellingOfATaskItemIsOne() throws {
        for line in ["- [ ] task", "* [ ] task", "+ [ ] task", "1. [ ] task", "2) [ ] task",
                     "  - [ ] task", "\t- [ ] task"] {
            let action = try #require(MarkdownActions.action(in: line), "\(line) is a task item")
            #expect(action.text == "task")
            #expect(action.done == false)
        }
        for line in ["- [x] task", "- [X] task", "  * [x] task"] {
            let action = try #require(MarkdownActions.action(in: line), "\(line) is a done task item")
            #expect(action.done)
        }
    }

    /// The lines that look like one and are not. A box needs both brackets and a space, an `x` or an
    /// `X` between them, and a list marker in front of it — a bracket opening a sentence, or one in a
    /// heading or a quote, is prose.
    @Test func aBulletThatMerelyStartsWithABracketIsNotAnAction() {
        for line in ["- [] task", "- [ok] task", "[ ] task", "- task",
                     "## [ ] not a list", "> [ ] quoted", "- [ ]"] {
            #expect(MarkdownActions.action(in: line) == nil, "\(line) is not an action")
        }
    }

    /// The offsets a checkbox is drawn at and a tick is applied to. `box` is the three characters of
    /// the box itself, so `box.lowerBound + 1` is the one character that changes, and `textStart` is
    /// where the item's own sentence begins.
    @Test func aTaskItemSaysWhereItsBoxAndItsTextAre() throws {
        let item = try #require(MarkdownActions.taskItem("  - [x] ship the write-up"))
        #expect(item.done)
        #expect(item.box == 4..<7)
        #expect(item.textStart == 8)
        let characters = Array("  - [x] ship the write-up")
        #expect(String(characters[item.box]) == "[x]")
        #expect(String(characters[item.textStart...]) == "ship the write-up")
    }

    // MARK: - The seam with the editor

    /// **Two implementations of "what is a task item", held to one answer.**
    ///
    /// `MarkdownActions.taskItem` decides what `meetings actions list` reports. The engine decides,
    /// independently and in its own AST, what to draw a checkbox over and what a click toggles. A
    /// line the engine ticks that this rejects is a box the user can click that the CLI never shows —
    /// the exact disagreement the write-up-is-the-record design exists to remove, arrived at from the
    /// other end.
    ///
    /// The engine's parse is reached through ``MarkdownHTMLRenderer``, which is the same
    /// `MarkdownAST` list-item walk the styler and the layout fragment use — it emits an
    /// `<input type="checkbox">` for exactly the items it would draw a box on.
    @Test func theEngineAndTheCLIAgreeAboutWhichLinesCarryACheckbox() {
        // Every shape the two parsers could plausibly split on: the box with no space after it, a tab
        // where a space is expected on either side of the box, ordered markers, and a quote.
        //
        // `- [x](url)` is here because dropping the whitespace-after-the-box rule admits it, and it
        // reads like a link whose label is `x` rather than like a task item. The engine's answer
        // decides, and the engine draws a ticked checkbox on it — `<input type="checkbox" checked
        // disabled> (<a href="…">…</a>)` — so it is a box the user can click and the CLI has to show
        // it. `- [ ]x` is the same question one character apart.
        let probes = [
            "- [ ] x", "- [x] x", "- [X] x", "* [ ] x", "+ [ ] x",
            "- [x]done", "- [ ]x", "- [x](https://example.com/report)",
            "-\t[ ] x", "- [ ]\tx", "  - [ ] x", "\t- [ ] x",
            "1. [ ] x", "10. [ ] x", "2) [ ] x",
            "> - [ ] x", "- [] x", "- [ok] x", "[ ] x", "## [ ] x", "- x [ ] y",
        ]
        for line in probes {
            let drawn = MarkdownHTMLRenderer.html(from: line).contains("<input type=\"checkbox\"")
            let read = MarkdownActions.taskItem(line) != nil
            #expect(drawn == read, """
                `\(line.debugDescription)`: the engine \(drawn ? "draws" : "draws no") checkbox and \
                MarkdownActions \(read ? "reads" : "does not read") a task item. Whichever way round \
                it is, one surface has a box the other cannot see — a checkbox the user clicks that \
                `meetings actions list` never shows, or an action with nothing to tick.
                """)
        }
    }

    /// The two shapes that made this a real divergence rather than a theoretical one, kept as their
    /// own case so a re-tightening of ``MarkdownActions/taskItem(_:)`` fails with the reason attached.
    /// Both were drawn with a clickable checkbox and both were invisible to `meetings actions list`:
    /// a box with no space after it, and a tab where the list marker's space goes.
    @Test func theTwoShapesTheEngineTickedAndTheCLICouldNotSee() throws {
        #expect(try #require(MarkdownActions.taskItem("- [x]done")).done)
        #expect(MarkdownActions.action(in: "- [x]done")?.text == "done")
        #expect(MarkdownActions.action(in: "-\t[ ] pick the venue")?.text == "pick the venue")
    }

    /// The shape that looks most like an accident of the loosening: a list item whose *link label* is
    /// `x`. It reads as a done action with the link as its text, and that is the engine's call, not a
    /// guess — the renderer emits a ticked, clickable checkbox for this exact line. Pinned in both
    /// directions: the seam test would catch the engine changing its mind, this says what the answer
    /// currently is so nobody re-tightens the rule on the assumption it was an oversight.
    @Test func aLinkLabelledXIsADoneActionBecauseTheEngineDrawsItsCheckbox() throws {
        let line = "- [x](https://example.com/report)"
        #expect(MarkdownHTMLRenderer.html(from: line).contains("<input type=\"checkbox\" checked"))
        let action = try #require(MarkdownActions.action(in: line))
        #expect(action.done)
        #expect(action.text == "(https://example.com/report)")
    }

    /// The box the engine hands back at the end of `/todo` is one this reads — the contract between
    /// the write-up and the CLI, checked on the exact string the slash command produces.
    @Test func theBoxTheSlashCommandTypesIsOneTheCLIReads() throws {
        let item = try #require(MarkdownActions.taskItem("- [ ] "))
        #expect(!item.done)
        #expect(item.box == 2..<5)
        // …and it is not yet an action, because nobody owes an empty sentence.
        #expect(MarkdownActions.action(in: "- [ ] ") == nil)
    }

    /// A box being typed is a marker, but it is not yet something anybody owes — `meetings actions
    /// list` printing a blank line as a commitment is the failure this avoids.
    @Test func aBoxWithNoTextIsNotYetAnAction() {
        #expect(MarkdownActions.action(in: "- [ ] ") == nil)
        #expect(MarkdownActions.action(in: "- [x]   ") == nil)
    }

    // MARK: - The document

    @Test func actionsAreReadFromAnywhereInTheDocument() {
        let summary = """
            # Standup

            We agreed to ship on Friday.

            - [ ] anchor live notes to system audio
            - a plain bullet that is not an action
            - [x] ship the gutter

            ## Open questions

            - [ ] decide whether the column stays
            """
        let actions = MarkdownActions.parse(summary)
        #expect(actions.map(\.text) == [
            "anchor live notes to system audio",
            "ship the gutter",
            "decide whether the column stays",
        ])
        #expect(actions.map(\.done) == [false, true, false])
    }

    /// Neither is represented in the markdown yet, and the parser must not invent one. The fields
    /// stay on ``Action`` because the CLI's JSON shape does.
    @Test func ownerAndDueAreAlwaysNilBecauseTheMarkdownDoesNotCarryThem() throws {
        let action = try #require(
            MarkdownActions.action(in: "- [ ] ask Sofia about the March timeline @Sofia 📅2026-08-16")
        )
        #expect(action.owner == nil)
        #expect(action.due == nil)
        // And nothing is stripped off the end: an unparsed convention is text, not metadata.
        #expect(action.text == "ask Sofia about the March timeline @Sofia 📅2026-08-16")
    }

    @Test func parsingThenRenderingReproducesTheLine() throws {
        for line in ["- [ ] anchor live notes", "- [x] ship the gutter",
                     "- [ ] an action with @Yoel and 📅2026-08-16 still in its text"] {
            let action = try #require(MarkdownActions.action(in: line))
            #expect(MarkdownActions.rendered(action) == line, "round trip lost something on \(line)")
        }
    }

    // MARK: - Rewriting the list

    /// The rule `meetings actions set` has to obey. An agent replacing the actions must not take the
    /// decisions and the open questions with them.
    @Test func replacingTheListLeavesTheRestOfTheWriteUpAlone() {
        let summary = """
            # Standup

            We agreed to ship on Friday.

            ## Actions

            - [ ] old one
            - [x] another old one

            ## Open questions

            Does the column stay?
            """
        let rewritten = MarkdownActions.replace([Action(text: "the only one left")], in: summary)
        #expect(rewritten == """
            # Standup

            We agreed to ship on Friday.

            ## Actions

            - [ ] the only one left

            ## Open questions

            Does the column stay?
            """)
    }

    /// Clearing the list takes the `- [ ]` lines and only those. The `## Actions` heading stays,
    /// because the heading is prose somebody wrote and this command's whole promise is that it does
    /// not edit prose.
    @Test func anEmptyListRemovesTheTaskItemsAndNothingElse() {
        let summary = "# Standup\n\n## Actions\n\n- [ ] one\n- [x] two\n\nThe end."
        #expect(MarkdownActions.replace([], in: summary) == "# Standup\n\n## Actions\n\n\nThe end.")
    }

    /// The structure the user typed is the user's. `parse` reads task items from anywhere in the
    /// document, and `replace` used to delete every one of them and re-emit the list at the first
    /// one's position — so a sub-checklist nested under a decision, and a checkbox typed under
    /// "Open questions", were both hoisted into the Actions block and flattened to top level. Each
    /// item is rewritten where it stands instead, wearing its own indentation and marker.
    @Test func replacingRewritesEachItemWhereItStandsRatherThanHoistingThem() {
        let summary = """
            # Standup

            We agreed to ship on Friday.

            - [ ] check the numbers
              * [x] nested under the decision

            ## Open questions

            - [ ] does the column stay
            """
        let rewritten = MarkdownActions.replace(
            [
                Action(text: "check the numbers again"),
                Action(text: "nested, still nested", done: true),
                Action(text: "does the column stay"),
            ],
            in: summary
        )
        #expect(rewritten == """
            # Standup

            We agreed to ship on Friday.

            - [ ] check the numbers again
              * [x] nested, still nested

            ## Open questions

            - [ ] does the column stay
            """)
    }

    /// The round trip `meetings actions set` is documented for: `actions list` reads every action in
    /// the document, so writing that same list straight back has to reproduce the document.
    ///
    /// Every shape the seam with the editor admits, not only the well-spaced ones — the promise was
    /// stated where it was not tested. `- [x]done` came back as `- [x] done`, `- [ ]\tx` lost its
    /// tab, and the empty box the user was typing was deleted outright.
    @Test func writingBackWhatWasReadReproducesTheDocument() {
        let summary = "# Standup\n\n- [ ] one\n  + [x] two\n\n## Later\n\n1. [ ] three"
        #expect(MarkdownActions.replace(MarkdownActions.parse(summary), in: summary) == summary)

        let awkward = "- [x]done\n- [ ]\tx\n-\t[ ] y\n- [ ] \n- [ ] plain"
        #expect(MarkdownActions.replace(MarkdownActions.parse(awkward), in: awkward) == awkward)
    }

    /// The index `actions set` counts by is the one `actions list` prints, and that is not the number
    /// of `- [ ]` lines: an empty box is not an action. Counting boxes meant a half-typed one in the
    /// middle of a write-up shifted every item after it by one — the agent's second action landing on
    /// the user's third — and the docs told the agent to send them in `actions list` order.
    @Test func aHalfTypedBoxIsNotCountedAndIsNotTouched() {
        let summary = "## Actions\n\n- [ ] one\n- [ ] \n- [x] two"
        let rewritten = MarkdownActions.replace(
            [Action(text: "one, revised"), Action(text: "two, revised", done: true)], in: summary
        )
        #expect(rewritten == "## Actions\n\n- [ ] one, revised\n- [ ] \n- [x] two, revised")
    }

    /// More items than the document has: the extras land after the last existing one rather than
    /// starting a second list somewhere else.
    @Test func extraItemsLandAfterTheLastExistingOne() {
        let summary = "## Actions\n\n- [ ] one\n\nThe end."
        let rewritten = MarkdownActions.replace(
            [Action(text: "one"), Action(text: "two"), Action(text: "three", done: true)], in: summary
        )
        #expect(rewritten == "## Actions\n\n- [ ] one\n- [ ] two\n- [x] three\n\nThe end.")
    }

    /// An extra is a **new top-level action**, not a child of whatever the document's last checkbox
    /// happened to be. Writing extras "like the last line" copied its indentation and its marker, so
    /// a write-up whose final box is a sub-item under a decision turned every new action the agent
    /// sent into another sub-item of that decision.
    @Test func extrasAreTopLevelWhenTheLastItemIsNested() {
        let summary = "## Actions\n\n- [ ] check the numbers\n  * [ ] nested under it"
        let rewritten = MarkdownActions.replace(
            [Action(text: "check the numbers"), Action(text: "nested under it"), Action(text: "brand new")],
            in: summary
        )
        #expect(rewritten == "## Actions\n\n- [ ] check the numbers\n  * [ ] nested under it\n- [ ] brand new")
    }

    /// The same rule for the other shape it broke: the document's last box sits under a later
    /// heading, in a list the author styled differently. The extra is still a plain top-level action.
    @Test func extrasAreTopLevelWhenTheLastItemIsUnderALaterHeading() {
        let summary = "## Actions\n\n- [ ] one\n\n## Open questions\n\n  + [x] does the column stay"
        let rewritten = MarkdownActions.replace(
            [Action(text: "one"), Action(text: "does the column stay", done: true), Action(text: "brand new")],
            in: summary
        )
        #expect(rewritten == """
            ## Actions

            - [ ] one

            ## Open questions

              + [x] does the column stay
            - [ ] brand new
            """)
    }

    /// What the last line does still earn: its own list style, when it is itself top level. Appending
    /// a `-` item to a `*` list is a diff on a document nobody asked to restyle.
    @Test func extrasWearTheLastItemsMarkerWhenItIsTopLevel() {
        let rewritten = MarkdownActions.replace(
            [Action(text: "one"), Action(text: "two")], in: "* [ ] one"
        )
        #expect(rewritten == "* [ ] one\n* [ ] two")
    }

    @Test func aWriteUpWithNoTaskListGainsOneUnderAHeading() {
        let rewritten = MarkdownActions.replace([Action(text: "ship it", done: true)], in: "# Standup\n\nWe shipped.")
        #expect(rewritten == "# Standup\n\nWe shipped.\n\n## Actions\n\n- [x] ship it")
    }

    @Test func anEmptyWriteUpBecomesJustTheActions() {
        #expect(MarkdownActions.appending([Action(text: "ship it")], to: "")
            == "## Actions\n\n- [ ] ship it")
    }

    // MARK: - The migration's own guarantee

    /// The store migration runs ``MarkdownActions/appending(_:to:)`` over every meeting that had
    /// actions in the old column, and the orphan repair can reopen a store part-way up the ladder —
    /// so running it twice must not leave two copies of the list.
    @Test func appendingIsIdempotent() {
        let actions = [Action(text: "one"), Action(text: "two", done: true)]
        let once = MarkdownActions.appending(actions, to: "# Standup\n\nWe talked.")
        let twice = MarkdownActions.appending(actions, to: once)
        #expect(once == twice)
        #expect(MarkdownActions.parse(twice).count == 2)
    }

    /// An unrelated checkbox in the write-up must not silence the migration for that meeting.
    ///
    /// This pinned the opposite once, and the opposite lost real data: skipping any document that
    /// already carried a task item meant one stray `- [ ] hello` — typed by the author, nothing to
    /// do with the column — stopped every action on that meeting from ever reaching the write-up.
    /// Nothing reads the column afterwards, so they were simply gone from the app. Idempotency is
    /// per action, matched on its text.
    @Test func anUnrelatedCheckboxDoesNotBlockActionsFromMoving() {
        let summary = "# Standup\n\n- [ ] something the user typed"
        let merged = MarkdownActions.appending([Action(text: "from the old column")], to: summary)
        let texts = MarkdownActions.parse(merged).map(\.text)
        #expect(texts == ["something the user typed", "from the old column"])
    }

    /// The other half of the same rule: an action already in the document is not added again, even
    /// though the document carries other task items that are not in the column.
    @Test func anActionAlreadyInTheDocumentIsNotDuplicated() {
        let summary = "# Standup\n\n- [ ] something the user typed\n- [x] one"
        #expect(MarkdownActions.appending([Action(text: "one")], to: summary) == summary)
    }

    /// Two commitments that happen to read the same are two commitments. Matching by presence
    /// rather than by count collapsed a column holding `follow up` twice into one line, and the
    /// migration runs once over a real store with nothing to surface the loss.
    @Test func duplicateActionsInTheOldColumnBothSurviveTheMigration() {
        let actions = [
            Action(text: "follow up", owner: "Sofia", done: false),
            Action(text: "follow up", owner: "Will", done: true),
        ]
        let once = MarkdownActions.appending(actions, to: "# Standup")
        #expect(MarkdownActions.parse(once).map(\.text) == ["follow up", "follow up"])
        // And still idempotent: a re-run finds two already there and adds neither.
        #expect(MarkdownActions.appending(actions, to: once) == once)
    }

    @Test func noActionsMeansNoHeading() {
        #expect(MarkdownActions.appending([], to: "# Standup") == "# Standup")
        #expect(MarkdownActions.carriesActions("# Standup") == false)
    }

    /// An `Action` with no text does not become a line.
    ///
    /// This is where the empty checkbox at the bottom of a write-up came from. `ActionsInput`
    /// rejects an empty text, so the CLI cannot produce one — but the store migration decodes the
    /// legacy `actions` column straight through `JSONDecoder`, which validates nothing, and one
    /// `{"text": ""}` in there rendered as `- [ ] ` and landed at the end of the action list as a
    /// checkbox beside nothing.
    @Test func anActionWithNoTextDoesNotBecomeALine() {
        let appended = MarkdownActions.appending(
            [Action(text: "ship it"), Action(text: ""), Action(text: "   ")], to: "# Standup"
        )
        #expect(appended == "# Standup\n\n## Actions\n\n- [ ] ship it")

        let replaced = MarkdownActions.replace(
            [Action(text: ""), Action(text: "ship it")], in: "- [ ] old"
        )
        #expect(replaced == "- [ ] ship it")
    }

    /// And the reason it mattered twice over: `appending` is idempotent by *text*, and `parse`
    /// cannot see an item with no text — so the empty one was never "already present" and every
    /// re-run of the migration added another. Measured before the fix: three runs, three boxes.
    @Test func anEmptyActionCannotAccumulateAcrossMigrationRuns() {
        let actions = [Action(text: "ship it"), Action(text: "")]
        var document = "# Standup"
        for _ in 0..<3 { document = MarkdownActions.appending(actions, to: document) }
        #expect(document == "# Standup\n\n## Actions\n\n- [ ] ship it")
    }

    /// The line the user typed is theirs. Nothing above filters the *document*: an item somebody is
    /// in the middle of writing survives being parsed, rendered around, and appended to.
    @Test func anEmptyItemTheUserTypedIsLeftAlone() {
        let typed = "## Actions\n\n- [ ] ship it\n- [ ] "
        #expect(MarkdownActions.appending([Action(text: "ship it")], to: typed) == typed)
        #expect(typed.contains("- [ ] "))
    }
}
