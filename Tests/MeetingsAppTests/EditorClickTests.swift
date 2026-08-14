import Foundation
import AppKit
import MeetingsCore
import Testing

@testable import MeetingsApp

/// A write-up with every shape a click can land on: hidden inline markers inside a paragraph that
/// wraps, headings, bullets, and an action list with both a ticked and an unticked box.
let writeUp = """
    ## Summary

    The team walked through the migration plan and agreed the **cutover** window is the last \
    week of the month. Nobody wanted a second freeze, so the plan is one push.

    ## Decisions

    - Ship behind a flag
    - Keep the *old* path for one release

    ## Actions

    - [ ] Draft the rollout note
    - [x] Book the war room
    - [ ] Tell support what changes
    """

/// Every place in it worth clicking.
let clickTargets = [
    "The team walked", "cutover", "week of the month", "## Decisions", "Ship behind",
    "old", "## Actions", "Draft the rollout", "Book the war", "Tell support",
]

/// A click puts a caret down. That is the whole contract, and it was broken.
///
/// **Serialized.** These share one `NSApplication` and draw real views; running them concurrently
/// is asking two windows to be laid out from two threads.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_LIVE_EDITOR"] == "1")) struct EditorClickTests {
    /// **Where the text is must not depend on where the selection is.** This is the click bug's
    /// root cause, stated as an invariant.
    ///
    /// `NSTextView.mouseDown` does not return until the mouse comes up: it maps the pointer to a
    /// character on every event and extends the selection to whatever it last read. If moving that
    /// selection restyles a line — and revealing its markers at full size does exactly that — then
    /// the loop's next reading of the *same* screen point lands on a different character, and the
    /// caret it was going to drop becomes a range that runs away down the document.
    ///
    /// Measured offscreen at 560 pt with synthesised events through the real tracking loop, before:
    /// a click in the last action line came back `{323, 22}` and a double-click on `cutover` took
    /// `the`. After: `{322, 1}` and `cutover`, matching a stock `NSTextView` given the same events.
    @Test("moving a selection moves no text", arguments: clickTargets)
    func theLayoutDoesNotMoveWithTheSelection(_ place: String) {
        let harness = EditorHarness(writeUp)
        let probe = NSRange(location: 0, length: (harness.view.string as NSString).length)

        harness.view.setSelectedRange(NSRange(location: 0, length: 0))
        let settled = harness.view.markdownRect(for: probe)

        // Every state the tracking loop passes through on the way to a selection, in order.
        let at = harness.characterIndex(inside: place)
        for length in [0, 1, 20] {
            harness.view.setSelectedRange(NSRange(location: at, length: length))
            guard length > 0 else { continue }
            #expect(
                harness.view.markdownRect(for: probe) == settled,
                """
                Selecting \(length) characters from \(at) — inside "\(place)" — moved the \
                document from \(String(describing: settled)) to \
                \(String(describing: harness.view.markdownRect(for: probe))). A mouse still down \
                would read a different character out of the same point and keep extending.
                """
            )
        }
    }

    /// The reveal is held back for the duration of the gesture, not cancelled. By the time the
    /// mouse is up the caret's line shows its markers again, exactly as it did before.
    @Test func theRevealStillArrivesWhenTheMouseComesUp() {
        let harness = EditorHarness(writeUp)
        _ = harness.clickResolvesTwice(at: harness.point(inside: "cutover"))
        harness.coordinator.endMouseTracking()

        let marker = harness.view.string.range(of: "**cutover")!
        let at = (String(harness.view.string[harness.view.string.startIndex..<marker.lowerBound])
            as NSString).length
        let font = harness.view.textStorage?
            .attribute(.font, at: at, effectiveRange: nil) as? NSFont
        #expect(
            (font?.pointSize ?? 0) > 1,
            "the caret's line shows its markers at full size once the gesture is over"
        )
    }

    /// **A caret reveals, a selection does not.** Before, the reveal followed the *start* of the
    /// selection, so dragging across the action list left one row showing raw markers among rows
    /// that showed checkboxes — which reads as the rendering having failed rather than as a
    /// feature. The line you are editing is the line the insertion point is on, and a range is not
    /// an insertion point.
    @Test func aSelectionRevealsNothing() {
        let harness = EditorHarness(writeUp)
        let string = harness.view.string
        let marker = string.range(of: "**cutover")!
        let at = (String(string[string.startIndex..<marker.lowerBound]) as NSString).length

        harness.view.setSelectedRange(NSRange(location: at, length: 0))
        let caretFont = harness.view.textStorage?
            .attribute(.font, at: at, effectiveRange: nil) as? NSFont
        #expect((caretFont?.pointSize ?? 0) > 1, "a caret on the line reveals its markers")

        harness.view.setSelectedRange(NSRange(location: at, length: 40))
        let selectedFont = harness.view.textStorage?
            .attribute(.font, at: at, effectiveRange: nil) as? NSFont
        #expect(
            (selectedFont?.pointSize ?? 99) < 1,
            "a selection starting on the same line leaves the markers hidden"
        )
    }

    /// Clicking a checkbox ticks it, through the same edit path a keystroke takes, and leaves no
    /// selection and no half-finished gesture behind.
    @Test func clickingACheckboxTicksItAndNothingElse() throws {
        let harness = EditorHarness(writeUp)
        let boxes = harness.view.checkboxes()
        #expect(boxes.count == 3, "three task items, three boxes")
        let first = try #require(boxes.first)
        #expect(first.done == false)

        harness.clickCheckbox(first)
        #expect(harness.text.contains("- [x] Draft the rollout note"), "the box ticked")
        #expect(harness.view.selectedRange().length == 0, "and left a caret, not a selection")
        #expect(harness.view.isTrackingMouse == false, "and no gesture is still open")

        harness.clickCheckbox(try #require(harness.view.checkboxes().first))
        #expect(harness.text.contains("- [ ] Draft the rollout note"), "and it unticks again")
    }

    @Test func tickingABoxIsOneUndo() throws {
        let harness = EditorHarness(writeUp)
        harness.clickCheckbox(try #require(harness.view.checkboxes().first))
        #expect(harness.text.contains("- [x] Draft"))
        harness.view.undoManager?.undo()
        #expect(harness.view.string.contains("- [ ] Draft"), "one undo puts the box back")
    }

    /// Republishing the anchors is a read. It runs on a runloop turn of its own and could otherwise
    /// land in the middle of a gesture.
    @Test func republishingTheAnchorsNeverMovesTheSelection() {
        let harness = EditorHarness(writeUp)
        harness.view.setSelectedRange(NSRange(location: 40, length: 0))
        let caret = harness.view.selectedRange()
        harness.coordinator.publishRects()
        harness.coordinator.publishRects()
        #expect(harness.view.selectedRange() == caret, "publishing anchors moved the caret")
    }
}

/// The checkbox is the system control, and it is still there when the row is selected.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_LIVE_EDITOR"] == "1")) struct EditorCheckboxTests {
    /// The one thing that must never regress: this view is on TextKit 2. The overlay and
    /// `viewWillDraw()` are both new, and the last time drawing was touched here — an
    /// `override func draw(_:)` — it silently dropped the whole view to TextKit 1 and took the
    /// gutter, the document height and every anchor with it.
    @Test func theViewIsStillOnTextKit2AfterDrawing() {
        let harness = EditorHarness(writeUp)
        _ = harness.rendered()
        #expect(harness.view.textLayoutManager != nil, "TextKit 2, still")
        #expect(harness.view.markdownRect(for: NSRange(location: 5, length: 3)) != nil)
    }

    /// A checkbox is painted where the `[ ]` characters are — and it survives being selected.
    ///
    /// It did not. The boxes were painted in `drawBackground(in:)`, and the selection highlight is
    /// drawn over the background: measured offscreen, a selection dragged across the action list
    /// erased every checkbox it covered, the accent-coloured ticked one included, so the rows
    /// inside the selection showed a blank gap beside rows that showed a control. An overlay
    /// subview draws after the text, the way a real checkbox in a real window does.
    @Test func aCheckboxIsDrawnAndSurvivesASelection() throws {
        let harness = EditorHarness(writeUp)
        let boxes = harness.view.checkboxes()
        #expect(boxes.count == 3)

        let clean = try #require(harness.rendered())
        for box in boxes {
            #expect(harness.hasInk(in: box.rect, of: clean), "a box is painted at \(box.rect)")
        }

        // A selection across the whole action list, the way the screenshot had it.
        let string = harness.view.string
        let from = string.range(of: "Nobody")!.lowerBound
        let to = string.range(of: "war room")!.upperBound
        let lower = (String(string[string.startIndex..<from]) as NSString).length
        let upper = (String(string[string.startIndex..<to]) as NSString).length
        harness.view.setSelectedRange(NSRange(location: lower, length: upper - lower))

        let selected = try #require(harness.rendered())
        for box in harness.view.checkboxes() {
            #expect(
                harness.hasInk(in: box.rect, of: selected),
                "the checkbox at \(box.rect) went missing under the selection"
            )
        }
    }

    /// The box characters stay invisible under a selection too. AppKit adds `selectedTextColor` to
    /// everything selected by default, and that overrode the `NSColor.clear` the `[ ]` is drawn in
    /// — so the literal brackets came back on top of the checkbox, on the selected rows only.
    @Test func theBoxCharactersStayInvisibleWhenSelected() {
        let harness = EditorHarness(writeUp)
        let selected = harness.view.selectedTextAttributes
        #expect(selected[.foregroundColor] == nil, """
            A selection may tint the background; it may not repaint a glyph. Giving it a \
            foreground colour brings the `[ ]` back on top of every selected checkbox.
            """)
        #expect(selected[.backgroundColor] != nil, "and it does still highlight")
    }
}
