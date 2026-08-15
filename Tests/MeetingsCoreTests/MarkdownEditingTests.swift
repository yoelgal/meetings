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
    @Test func everyCommandNamesALabelAndAShorthand() {
        for command in MarkdownEditing.slashCommands {
            switch command.label {
            case .symbol(let name): #expect(!name.isEmpty)
            case .text(let text): #expect(!text.isEmpty)
            }
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

    /// The heading rows say **H1, H2, H3** — not three pictures of the letter A.
    ///
    /// `textformat.size.larger`, `textformat.size` and `textformat.size.smaller` draw as `A`, `AA`
    /// and a smaller `A`: at 18 pt in a menu row the first and third are the same glyph, and the
    /// turn-into group of the toolbar was three of them in a line. Reported twice.
    @Test func theHeadingCommandsAreLabelledWithTheirLevel() {
        let headings = MarkdownEditing.slashCommands.filter { $0.group == "Headings" }
        #expect(headings.map(\.label) == [.text("H1"), .text("H2"), .text("H3")], """
            A heading level has no legible symbol. Two characters name it exactly, and a symbol \
            that has to be told apart from its neighbour by size carries no information at all.
            """)
        // And the toolbar's turn-into group draws the same catalogue, so it cannot regress alone.
        let inTheToolbar = MarkdownEditing.blockCommands.filter { $0.group == "Headings" }
        #expect(inTheToolbar.map(\.label) == headings.map(\.label))
    }

    // MARK: - Where the toolbar goes

    /// The whole editor, unscrolled: the top of the document is the top of the viewport.
    private static let detailPane = CGRect(x: 0, y: 0, width: 520, height: 600)
    private static let toolbar = CGSize(width: 280, height: 30)
    /// Measured: 300 × 299.
    private static let menu = CGSize(width: 300, height: 299)

    /// The defect this function exists for. The toolbar is centred on the selection and is about
    /// 280 pt wide, so a selection starting at the text's left edge computed a negative origin —
    /// outside the editor, outside the document column, and past the left edge of the split view's
    /// detail pane, which clips. Nothing bounded it, so those points were simply not drawn.
    @Test func aFloatingSurfaceIsNeverPushedOutsideTheEditor() {
        // A selection of one word at the start of a line: centring alone would put it at −95.
        let atTheEdge = MarkdownEditing.floating(
            over: CGRect(x: 45, y: 120, width: 40, height: 18),
            size: Self.toolbar, in: Self.detailPane
        )
        #expect(atTheEdge.x == 0, "clamped to the editor's left edge rather than off it")

        // And the same at the other end.
        let atTheFarEdge = MarkdownEditing.floating(
            over: CGRect(x: 470, y: 120, width: 45, height: 18),
            size: Self.toolbar, in: Self.detailPane
        )
        #expect(atTheFarEdge.x == 240, "clamped so its right edge lands on the editor's")

        // A viewport narrower than the surface has no valid range at all, and the answer is the
        // left edge — not a negative x from clamping to a negative upper bound.
        let cramped = MarkdownEditing.floating(
            over: CGRect(x: 10, y: 120, width: 20, height: 18),
            size: Self.toolbar, in: CGRect(x: 0, y: 0, width: 200, height: 400)
        )
        #expect(cramped.x == 0)

        // The slash menu is 300 pt wide and the panel's editor is about 330 — the case that once
        // ran 224 pt outside the clip, because the clamp was given a constant 520 instead of the
        // width the editor was actually laid out at.
        let inThePanel = MarkdownEditing.floating(
            over: CGRect(x: 300, y: 300, width: 0, height: 18), size: Self.menu,
            in: CGRect(x: 0, y: 0, width: 330, height: 400)
        )
        #expect(inThePanel.x == 30, "clamped so its right edge lands on the panel editor's")
    }

    @Test func aFloatingSurfaceSitsOverTheTextAndFlipsWhenThereIsNoRoom() {
        let roomy = MarkdownEditing.floating(
            over: CGRect(x: 200, y: 120, width: 60, height: 18),
            size: Self.toolbar, in: Self.detailPane
        )
        #expect(roomy.below == false)
        #expect(roomy.y == 84, "sits above the selection, its own height plus the gap")
        #expect(roomy.x == 90, "and centred on it")

        // The first line of the document has nothing above it, and a toolbar off the top edge is a
        // toolbar you cannot press.
        let atTheTop = MarkdownEditing.floating(
            over: CGRect(x: 200, y: 6, width: 60, height: 18),
            size: Self.toolbar, in: Self.detailPane
        )
        #expect(atTheTop.below)
        #expect(atTheTop.y == 30, "under the selection instead")
    }

    /// **The defect the write-up reported twice.** Both surfaces live in the editor's own
    /// coordinates, and the editor is as tall as its document inside a page that scrolls — so
    /// "is there room above" answered against the top of the *document* is nearly always yes. The
    /// 299 pt menu was therefore drawn 305 pt above the caret, which on a scrolled page is above
    /// the viewport: the menu you just summoned by typing `/` is not on the screen at all.
    @Test func aScrolledPagePlacesBothSurfacesInsideWhatIsVisible() {
        // 1200 pt down a long document, showing 600 pt of it.
        let viewport = CGRect(x: 0, y: 1200, width: 520, height: 600)
        // The caret is 40 pt below the top of the viewport, so there is no room for the menu above.
        let caret = CGRect(x: 120, y: 1240, width: 0, height: 18)

        let opened = MarkdownEditing.floating(
            over: caret, size: Self.menu, in: viewport, prefer: .below
        )
        #expect(opened.below, "under the line being typed")
        #expect(opened.y == 1264)
        #expect(opened.y >= viewport.minY && opened.y + Self.menu.height <= viewport.maxY, """
            The menu has to be inside the part of the editor that is on screen. Placed against the \
            editor's frame it landed at y = 935 — 305 pt above the caret and off the top of the \
            viewport, which is the defect.
            """)

        // The 30 pt toolbar still fits above a line 40 pt into the viewport, and stays there.
        let over = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 1240, width: 60, height: 18),
            size: Self.toolbar, in: viewport
        )
        #expect(over.below == false)
        #expect(over.y == 1204)

        // On the first line *showing*, it does not: above the viewport is where the last of these
        // bugs put it, and under the selection is the answer.
        let onTheFirstVisibleLine = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 1204, width: 60, height: 18),
            size: Self.toolbar, in: viewport
        )
        #expect(onTheFirstVisibleLine.below)
        #expect(onTheFirstVisibleLine.y == 1228)
    }

    /// The menu opens under the caret whenever it fits, even with acres of room above it. A caret
    /// menu that opens upward is somebody else's menu.
    @Test func theMenuPrefersUnderTheCaretAndTheToolbarOverTheSelection() {
        let viewport = CGRect(x: 0, y: 0, width: 520, height: 900)
        let anchor = CGRect(x: 120, y: 400, width: 0, height: 18)

        let menu = MarkdownEditing.floating(over: anchor, size: Self.menu, in: viewport, prefer: .below)
        #expect(menu.below)
        #expect(menu.y == 424)

        let toolbar = MarkdownEditing.floating(over: anchor, size: Self.toolbar, in: viewport)
        #expect(toolbar.below == false)
        #expect(toolbar.y == 364)
    }

    /// A caret has no width, and a surface that refused to place itself over one would be a menu
    /// that never opened — which is the same class of failure as a toolbar that never appears.
    @Test func aZeroSizedAnchorStillGetsAPlacement() {
        let placement = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 200, width: 0, height: 18), size: Self.menu,
            in: Self.detailPane, prefer: .below
        )
        #expect(placement.below)
        #expect(placement.y == 224)
        #expect(placement.x == 0)
    }

    // MARK: - Placed against the caret, never against an edge

    /// **The defect the write-up reported a third time.** The menu drew at the top of the pane,
    /// about five hundred points above the `/` that opened it, over unrelated text.
    ///
    /// The arithmetic that did it: the placement was clamped into `visible`, and a clamp can only
    /// fire when the result is outside the viewport being clamped into — which is to say when that
    /// viewport disagrees with where the caret is. A viewport reading can be stale (the page scrolled
    /// since it was taken) or short (only part of the editor showing); the caret cannot. So a
    /// viewport that does not contain the caret must cost a side, not five hundred points.
    @Test func aViewportThatDisagreesWithTheCaretNeverThrowsTheMenuAcrossThePage() {
        // A caret 1075 pt down the document, and a viewport reading that ends 200 pt above it.
        let caret = CGRect(x: 120, y: 1075, width: 0, height: 18)
        let stale = CGRect(x: 0, y: 600, width: 520, height: 260)

        let menu = MarkdownEditing.floating(over: caret, size: Self.menu, in: stale, prefer: .below)
        #expect(menu.below == false, "no room under the caret in what it was told is visible")
        #expect(menu.y == 770, """
            The menu has to touch the caret: its own height and the gap above it, at y = 770. \
            Clamped into that viewport instead it landed at y = 600 — 475 pt above the caret and \
            at the top of the pane, which is the bug as reported.
            """)
        // The same viewport, the same caret, the toolbar: smaller, so it hid this for longer.
        let toolbar = MarkdownEditing.floating(over: caret, size: Self.toolbar, in: stale)
        #expect(toolbar.y == 1039, "30 pt and a gap above the line, not 600")
    }

    /// Whatever the viewport says, the surface touches the caret — one gap above it or one gap
    /// below it, and never anywhere else.
    ///
    /// The invariant behind the bug above, checked over every arrangement of the three that occur:
    /// a document short enough not to scroll, a scrolled page, and a viewport that has fallen out of
    /// step with the caret entirely.
    @Test func everyPlacementTouchesTheCaret() {
        for viewportY in stride(from: 0.0, through: 1200.0, by: 400.0) {
            for viewportHeight in [200.0, 500.0, 900.0] {
                for caretY in stride(from: 0.0, through: 1500.0, by: 250.0) {
                    let caret = CGRect(x: 120, y: caretY, width: 0, height: 18)
                    let viewport = CGRect(x: 0, y: viewportY, width: 520, height: viewportHeight)
                    for (size, side) in [(Self.menu, MarkdownEditing.Side.below),
                                         (Self.toolbar, MarkdownEditing.Side.above)] {
                        let placed = MarkdownEditing.floating(
                            over: caret, size: size, in: viewport, prefer: side
                        )
                        let touching = placed.below
                            ? caret.maxY + 6
                            : caret.minY - size.height - 6
                        #expect(placed.y == touching, """
                            At caret \(caretY) in viewport \(viewport) the surface landed at \
                            \(placed.y), \(abs(placed.y - touching)) pt away from the caret it \
                            belongs to.
                            """)
                    }
                }
            }
        }
    }

    /// The four cases the pane and the panel actually produce.
    @Test func theSideFollowsTheRoomInTheViewportRatherThanInTheDocument() {
        // 1. Near the top of a scrolled document: the menu goes under the caret, where it prefers.
        let scrolled = CGRect(x: 0, y: 1200, width: 520, height: 900)
        let nearTheTop = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 1240, width: 0, height: 18), size: Self.menu,
            in: scrolled, prefer: .below
        )
        #expect(nearTheTop.below)
        #expect(nearTheTop.y == 1264)
        #expect(nearTheTop.y + Self.menu.height <= scrolled.maxY, "and inside the viewport")

        // 2. Near the bottom of that viewport: it flips above rather than running off the end.
        let nearTheBottom = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 1900, width: 0, height: 18), size: Self.menu,
            in: scrolled, prefer: .below
        )
        #expect(nearTheBottom.below == false)
        #expect(nearTheBottom.y == 1595)
        #expect(nearTheBottom.y >= scrolled.minY, "and still inside it")

        // 3. A document short enough not to scroll — the case that always worked. The menu is 299
        // and the pane 600, so a caret on the first line still opens downward.
        let short = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 6, width: 0, height: 18), size: Self.menu,
            in: Self.detailPane, prefer: .below
        )
        #expect(short.below)
        #expect(short.y == 30)

        // 4. The floating notes panel: 470 pt tall, its editor laid out at about 296 pt wide and
        // seeing about 400 pt of page. The 299 pt menu only just fits either side of a caret there.
        let panel = CGRect(x: 0, y: 0, width: 296, height: 400)
        let high = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 60, width: 0, height: 18), size: Self.menu, in: panel,
            prefer: .below
        )
        #expect(high.below, "316 pt of room below the caret against 54 above it")
        #expect(high.y == 84)
        let low = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 330, width: 0, height: 18), size: Self.menu, in: panel,
            prefer: .below
        )
        #expect(low.below == false, "324 pt above the caret against 46 below it")
        #expect(low.y == 25)
        // A caret in the middle of that panel has room for it on neither side. It goes on the side
        // with more room, still touching the caret, and overflows the far edge of the panel — which
        // it may, because it is drawn in a window of its own rather than inside the panel. Pinned
        // to an edge instead, the menu would sit over the line that summoned it.
        let middle = MarkdownEditing.floating(
            over: CGRect(x: 120, y: 200, width: 0, height: 18), size: Self.menu, in: panel,
            prefer: .below
        )
        #expect(middle.below == false, "194 pt above the caret against 176 below it")
        #expect(middle.y == -105)
    }

    // MARK: - Which surface is up

    /// The viewport the decisions below are made in: a page scrolled to show 1200…1800.
    private static let scrolled = CGRect(x: 0, y: 1200, width: 520, height: 600)
    private static let caretOnScreen = CGRect(x: 120, y: 1400, width: 0, height: 18)

    /// **No anchor, no surface — ever.** The origin is the worst answer there is: a menu 1000 pt
    /// from the caret reads as a placement bug and costs a day to chase, where a menu that does not
    /// open is a bug you can find in a minute.
    @Test func nothingIsShownWithoutAnAnchorOrWithoutFocus() {
        #expect(MarkdownEditing.surface(
            anchor: nil, visible: Self.scrolled, hasQuery: true, selectionLength: 0,
            focused: true, dismissed: false
        ) == nil, "an unmeasurable caret means no menu, not a menu at the top of the document")

        #expect(MarkdownEditing.surface(
            anchor: Self.caretOnScreen, visible: Self.scrolled, hasQuery: true, selectionLength: 4,
            focused: false, dismissed: false
        ) == nil, """
            The editor is not the one being typed into. Both surfaces belong to a caret in this \
            text view, and a menu left up over an editor you have clicked out of is a menu \
            belonging to nothing.
            """)
    }

    /// One at a time, and each knows its own side. The menu belongs to a caret and the toolbar to a
    /// range, so the two cannot both be right.
    @Test func aQueryMeansTheMenuAndASelectionMeansTheToolbar() {
        let menu = MarkdownEditing.surface(
            anchor: Self.caretOnScreen, visible: Self.scrolled, hasQuery: true, selectionLength: 0,
            focused: true, dismissed: false
        )
        #expect(menu == .menu)
        #expect(menu?.prefer == .below, "a caret menu opens under the line being typed")

        let toolbar = MarkdownEditing.surface(
            anchor: Self.caretOnScreen, visible: Self.scrolled, hasQuery: false, selectionLength: 7,
            focused: true, dismissed: false
        )
        #expect(toolbar == .toolbar)
        #expect(toolbar?.prefer == .above, "and a toolbar sits over the selection the pointer is on")

        #expect(MarkdownEditing.surface(
            anchor: Self.caretOnScreen, visible: Self.scrolled, hasQuery: true, selectionLength: 7,
            focused: true, dismissed: false
        ) == .menu, "a query wins: a `/` typed into a selection has replaced it")

        #expect(MarkdownEditing.surface(
            anchor: Self.caretOnScreen, visible: Self.scrolled, hasQuery: false, selectionLength: 0,
            focused: true, dismissed: false
        ) == nil, "a caret with nothing typed at it has neither")

        #expect(MarkdownEditing.surface(
            anchor: Self.caretOnScreen, visible: Self.scrolled, hasQuery: false, selectionLength: 7,
            focused: true, dismissed: true
        ) == nil, "and Escape takes the toolbar down over a selection you are keeping")
    }

    /// A caret scrolled off the screen takes its surface with it.
    ///
    /// This used to be free: the surfaces were overlays and the page's scroll view clipped them.
    /// They are a window now — nothing clips a window — so scrolling the line out from under an
    /// open menu has to close it, or the menu is left floating over the transcript.
    @Test func aCaretScrolledOutOfTheViewportClosesItsSurface() {
        // Above the top of what is showing, and below the bottom of it.
        for offScreen in [CGRect(x: 120, y: 900, width: 0, height: 18),
                          CGRect(x: 120, y: 1850, width: 0, height: 18)] {
            #expect(MarkdownEditing.surface(
                anchor: offScreen, visible: Self.scrolled, hasQuery: true, selectionLength: 0,
                focused: true, dismissed: false
            ) == nil, "the line at \(offScreen.minY) is not on a page showing 1200…1800")
        }
        // A caret has no width, so the test has to be vertical overlap: `CGRect.intersects` is
        // false for every empty rect, and an editor whose menu never opened would be the result.
        #expect(MarkdownEditing.surface(
            anchor: CGRect(x: 120, y: 1790, width: 0, height: 18), visible: Self.scrolled,
            hasQuery: true, selectionLength: 0, focused: true, dismissed: false
        ) == .menu, "the last line showing still has its menu, even though it is a zero-width rect")
    }
}
