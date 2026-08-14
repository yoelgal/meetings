import Foundation
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

    /// The lines that look like one and are not. The space after the box is the spec's, and without
    /// it a bullet whose sentence opens with a bracket would grow a checkbox.
    @Test func aBulletThatMerelyStartsWithABracketIsNotAnAction() {
        for line in ["- [x]task", "- [] task", "- [ok] task", "[ ] task", "- task",
                     "## [ ] not a list", "> [ ] quoted", "- [ ]"] {
            #expect(MarkdownActions.action(in: line) == nil, "\(line) is not an action")
        }
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
