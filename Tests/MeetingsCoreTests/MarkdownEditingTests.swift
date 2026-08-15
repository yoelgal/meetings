import Foundation
import Testing

@testable import MeetingsCore

/// What the editor's *chrome* decides: when the slash menu opens, what it lists, and where a
/// floating surface lands.
///
/// The typing rules that used to fill this file — list continuation, the `[] ` shorthand, marker
/// backspace, inline toggling, the block transforms — belong to `swift-markdown-engine` now, and
/// their tests went with them rather than staying here to assert a second opinion about text the
/// engine is the one holding.
@Suite struct MarkdownEditingTests {

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

    /// A blank box in a menu is invisible until somebody opens it, and by then it has shipped.
    @Test func everyCommandNamesASymbolAndAShorthand() {
        for command in MarkdownEditing.slashCommands {
            #expect(!command.symbol.isEmpty)
            #expect(command.shorthand == "/\(command.id)")
            #expect(["Headings", "Lists", "Blocks"].contains(command.group))
        }
        // The turn-into group can only offer constructs that *are* a line's marker — a divider or a
        // fenced block turned "into" a selection is not a thing the toolbar can mean.
        for command in MarkdownEditing.blockCommands {
            switch command.action {
            case .heading, .bulletList, .orderedList, .taskList: break
            default: Issue.record("\(command.id) is not a line-marker construct")
            }
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
        // edge — not a negative x from clamping to a negative upper bound. This is the notes panel:
        // it lays the editor out at about 296 pt, against the 520 the detail pane gives it.
        let cramped = MarkdownEditing.floating(
            over: CGRect(x: 10, y: 120, width: 20, height: 18), size: toolbar, in: 200
        )
        #expect(cramped.x == 0)

        // The slash menu is 300 pt wide and the panel's editor is about 296 — the case that once
        // ran 224 pt outside the clip, because the clamp was given a constant 520 instead of the
        // width the editor was actually laid out at.
        let inThePanel = MarkdownEditing.floating(
            over: CGRect(x: 250, y: 300, width: 0, height: 18),
            size: CGSize(width: 300, height: 220), in: 296
        )
        #expect(inThePanel.x == 0, "a menu wider than the panel starts at its left edge")
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
