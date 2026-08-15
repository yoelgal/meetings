import Foundation
import Testing

@testable import MeetingsApp
import MeetingsCore

/// The one piece of arithmetic between the editor's coordinates and the display's.
///
/// The floating surfaces are a child window now, framed in **screen** coordinates, so nothing about
/// where they land goes through SwiftUI's layout — which is the whole point, because that is the
/// part that could not be made to work. What is left to get wrong is the flip: the probe counts y
/// downward from its own top edge, a window counts it upward from the bottom of the main display,
/// and getting that backwards puts the menu the same distance on the wrong side of the caret.
///
/// **No window, no view, no `NSApplication`.** Everything here is `CGRect` arithmetic over the
/// numbers AppKit hands back from `convert(_:to: nil)` and `convertToScreen(_:)` — the two calls
/// themselves are AppKit's business. An ordinary `swift test` constructs nothing.
@Suite struct EditorSurfaceGeometryTests {
    /// A 2230 pt editor whose top edge is 400 pt above the bottom of the display: the traced shape
    /// of the real one, whose document is far taller than the window showing it.
    private static let probeOnScreen = CGRect(x: 124, y: -1830, width: 308, height: 2230)
    private static let menu = CGSize(width: 300, height: 299)

    /// Down the probe is up the screen.
    @Test func theSurfaceIsFlippedOutOfTheProbesSpaceOntoTheDisplay() {
        // The traced placement: 1854 pt down a 2230 pt editor, which is where the menu was computed
        // and where it did not draw.
        let placed = MarkdownEditing.Placement(x: 3, y: 1854, below: false)
        let frame = EditorSurface.frame(placed, size: Self.menu, probe: Self.probeOnScreen)

        #expect(frame.minX == 127, "the probe's left edge plus the placement's own x")
        #expect(frame.maxY == Self.probeOnScreen.maxY - 1854, """
            The top of the menu is 1854 pt below the top of the editor, measured on the screen. \
            Flipped the wrong way it lands \(2 * (Self.probeOnScreen.maxY - 1854) - frame.maxY) — \
            the same distance the other side of the caret, which is the whole bug class this \
            rewrite exists for.
            """)
        #expect(frame.height == Self.menu.height && frame.width == Self.menu.width)
    }

    /// The two sides of the caret come out the two sides on screen, which is the assertion that
    /// fails first if the flip is ever dropped.
    @Test func aSurfaceBelowTheCaretIsLowerOnTheScreenThanOneAbove() {
        // A caret in the middle of the viewport, which is the only place both sides fit a 299 pt
        // menu at all: 394 pt above the line, 318 below it.
        let caret = CGRect(x: 3, y: 1400, width: 0, height: 18)
        let viewport = CGRect(x: 0, y: 1000, width: 308, height: 742)

        let below = MarkdownEditing.floating(over: caret, size: Self.menu, in: viewport, prefer: .below)
        let above = MarkdownEditing.floating(over: caret, size: Self.menu, in: viewport, prefer: .above)
        #expect(below.below && !above.below, "both sides fit in a 742 pt viewport")

        let underneath = EditorSurface.frame(below, size: Self.menu, probe: Self.probeOnScreen)
        let over = EditorSurface.frame(above, size: Self.menu, probe: Self.probeOnScreen)
        #expect(underneath.maxY < over.minY, """
            The menu placed under the caret is drawn at \(underneath) and the one placed over it at \
            \(over). On a screen, under means a smaller y.
            """)

        // And it touches the caret from below: the top of the menu is one gap under the line.
        let caretOnScreen = Self.probeOnScreen.maxY - caret.maxY
        #expect(underneath.maxY == caretOnScreen - 6)
    }

    /// The horizontal clamp survives the conversion: it is applied in the editor's own column, and
    /// the column's offset on the display is added afterwards rather than clamped against.
    @Test func aSurfaceWiderThanTheColumnStaysInsideItOnScreen() {
        // The notes panel's editor: 308 pt of column against a 300 pt menu, caret at its right edge.
        let viewport = CGRect(x: 0, y: 1000, width: 308, height: 742)
        let placed = MarkdownEditing.floating(
            over: CGRect(x: 300, y: 1200, width: 0, height: 18), size: Self.menu,
            in: viewport, prefer: .below
        )
        let frame = EditorSurface.frame(placed, size: Self.menu, probe: Self.probeOnScreen)
        #expect(frame.minX >= Self.probeOnScreen.minX)
        #expect(frame.maxX <= Self.probeOnScreen.minX + viewport.maxX, """
            The menu runs to \(frame.maxX) with the editor's column ending at \
            \(Self.probeOnScreen.minX + viewport.maxX) — outside the panel it belongs to.
            """)
    }
}
