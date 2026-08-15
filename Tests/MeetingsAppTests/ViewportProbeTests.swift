import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MeetingsApp
import MeetingsCore

/// Where the slash menu lands **on a page that has been scrolled** — the one thing about this editor
/// that could only ever be checked with a screenshot, and the defect that was reported three times.
///
/// The last report: `/` typed two-thirds down a scrolled write-up drew the menu at the top of the
/// pane, some five hundred points above the caret, over unrelated text. The arithmetic behind it is
/// pinned in `MarkdownEditingTests`; what is pinned *here* is the other half — that the viewport
/// handed to that arithmetic is the slice of the page actually on screen, in the coordinates the
/// anchor is in, and that it follows the scroll.
///
/// **No window**, for the reason `EditorMountTests` gives: an `NSHostingView` is laid out off-screen
/// and nothing is ordered onto a screen. The page is scrolled by moving its clip view, which is what
/// a trackpad does to it.
///
/// That has a consequence worth naming: the shipping viewport is the **window's** content area
/// converted into the probe's space, and a harness with no window takes the `visibleRect` fallback
/// instead. What these tests still pin is everything downstream of it — that the slice follows the
/// scroll, that the caret is inside it, and that the placement it feeds lands on the line being
/// typed. Which of the two derivations the app reads on a real screen is checked by
/// `AppSourceGuardTests` and by looking at it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_LIVE_EDITOR"] == "1"))
@MainActor struct ViewportProbeTests {

    @MainActor private final class Document {
        var text: String
        init(_ text: String) { self.text = text }
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    }

    /// The detail pane's shape: one page-level `ScrollView`, a header above the write-up, the editor
    /// at the reading column with its inset, and sections under it.
    private struct DetailHost: View {
        let bridge: MarkdownEditorBridge
        let document: Document
        var column = SharedFieldEditor.column

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("A meeting title").font(.largeTitle)
                    Text("chips").frame(height: 60)
                    Text("a card").frame(height: 120)
                    LiveMarkdownEditor(text: document.binding, documentId: "viewport", bridge: bridge)
                        .frame(maxWidth: column)
                        .padding(SharedFieldEditor.editorInset)
                        .frame(minHeight: 220, alignment: .top)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("sections").frame(height: 300)
                }
                .frame(maxWidth: column + 2 * SharedFieldEditor.editorInset, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// A page of prose with an empty line to type the `/` on — the reproduction's own shape.
    private static let text: String = {
        var lines: [String] = []
        for index in 0..<80 {
            lines.append("Paragraph \(index) with enough prose on it that the column wraps it once.")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }()

    /// The location of the nth empty line, which is where a slash command gets typed.
    private static func emptyLine(_ nth: Int, in text: String) -> Int {
        let ns = text as NSString
        var found = 0
        var location = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) {
            line, range, _, stop in
            if line?.isEmpty == true {
                found += 1
                if found == nth { location = range.location; stop.pointee = true }
            }
        }
        return location
    }

    private static func probe(in view: NSView) -> MarkdownEditorProbe? {
        for sub in view.subviews {
            if let probe = sub as? MarkdownEditorProbe { return probe }
            if let found = probe(in: sub) { return found }
        }
        return nil
    }

    /// Mounts a page, waits for the probe to find the text view, and hands back everything the
    /// caller has to hold on to — the bridge keeps the probe and the text view weakly.
    private func mounted(
        width: CGFloat, height: CGFloat, column: CGFloat = SharedFieldEditor.column
    ) async throws -> (MarkdownEditorBridge, MarkdownEditorProbe, NSTextView, NSScrollView, NSView, Document) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let bridge = MarkdownEditorBridge()
        let document = Document(Self.text)
        let host = NSHostingView(
            rootView: DetailHost(bridge: bridge, document: document, column: column)
        )
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<40 where !bridge.isAttached {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let probe = try #require(Self.probe(in: host))
        let tv = try #require(bridge.textView)
        let page = try #require(probe.enclosingScrollView, """
            The probe found no scroll view above it, so the viewport can only be guessed at. \
            SwiftUI's ScrollView is NSScrollView-backed on macOS and this is the assumption the \
            placement rests on — if it has stopped being true, the fallback is `visibleRect` and \
            the numbers below say whether it is telling the truth.
            """)
        return (bridge, probe, tv, page, host, document)
    }

    /// Scrolls the page so `anchor` sits two-thirds of the way down what is showing.
    private func scroll(_ page: NSScrollView, toShow anchor: CGRect, from probe: NSView) {
        let inDocument = probe.convert(anchor, to: page.documentView)
        let top = inDocument.midY - page.contentView.bounds.height * 2 / 3
        page.contentView.scroll(to: NSPoint(x: 0, y: max(0, top)))
        page.reflectScrolledClipView(page.contentView)
    }

    /// The viewport is the page's visible slice, and it **follows the scroll** — with no keystroke
    /// to prompt it.
    ///
    /// A viewport read once and kept is the failure this defect kept coming back as: the placement
    /// is only as honest as the rectangle it is told is on screen.
    @Test func theViewportIsThePagesVisibleSliceAndFollowsTheScroll() async throws {
        let (bridge, probe, _, page, host, _) = try await mounted(width: 840, height: 1000)
        #expect(bridge.visible.height < probe.bounds.height, """
            The editor is \(probe.bounds.height) pt tall and the window shows 1000 of it; a \
            viewport of \(bridge.visible) is the whole document, which is the rectangle that made \
            the menu open upward off the top of the screen.
            """)

        page.contentView.scroll(to: NSPoint(x: 0, y: 900))
        page.reflectScrolledClipView(page.contentView)
        try await Task.sleep(for: .milliseconds(120))
        let slice = probe.convert(page.contentView.bounds, from: page.contentView)
            .intersection(probe.bounds)
        #expect(bridge.visible == slice, """
            After scrolling, the editor thinks \(bridge.visible) is on screen while the page's own \
            clip view says \(slice). Nothing was typed, which is the point: a page scrolled under \
            an open menu moves the menu with it.
            """)
        withExtendedLifetime(host) {}
    }

    /// **The reproduction.** `/` on an empty line two-thirds down a scrolled write-up, in a pane
    /// about 840 pt wide, puts the menu on the line being typed — not at the top of the pane.
    @Test func theMenuOpensAtTheCaretTwoThirdsDownAScrolledPage() async throws {
        let (bridge, probe, tv, page, host, _) = try await mounted(width: 840, height: 1000)
        let caret = Self.emptyLine(55, in: Self.text)
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        try await Task.sleep(for: .milliseconds(150))
        scroll(page, toShow: try #require(bridge.anchor), from: probe)
        try await Task.sleep(for: .milliseconds(100))

        tv.insertText("/", replacementRange: tv.selectedRange())
        tv.setSelectedRange(NSRange(location: caret + 1, length: 0))
        try await Task.sleep(for: .milliseconds(200))

        #expect(bridge.openQuery?.matches.count == MarkdownEditing.slashCommands.count)
        let anchor = try #require(bridge.anchor)
        let viewport = bridge.visible
        #expect(viewport.contains(CGPoint(x: anchor.midX, y: anchor.midY)), """
            The caret at \(anchor) is not inside the viewport \(viewport) the placement is given, \
            which is the disagreement that used to throw the menu across the page.
            """)

        let menu = MarkdownEditing.floating(
            over: anchor, size: CGSize(width: 300, height: 299), in: viewport, prefer: .below
        )
        #expect(menu.below)
        #expect(menu.y == anchor.maxY + 6, """
            The menu landed at \(menu.y) with the caret at \(anchor.minY): \
            \(menu.y - anchor.minY) pt away. It was measured at the top of the pane, ~500 pt above \
            the caret, which is what this asserts can no longer happen.
            """)
        #expect(menu.y + 299 <= viewport.maxY, "and inside what is showing")

        // The toolbar over a selection on the same line, at the same scroll position. It is smaller,
        // so the identical flaw hid in it for longer.
        tv.setSelectedRange(NSRange(location: caret - 20, length: 10))
        try await Task.sleep(for: .milliseconds(150))
        let selection = try #require(bridge.anchor)
        let toolbar = MarkdownEditing.floating(
            over: selection, size: CGSize(width: 280, height: 30), in: bridge.visible
        )
        #expect(toolbar.y == selection.minY - 36, "one toolbar and a gap over the selection")
        #expect(toolbar.y >= bridge.visible.minY && toolbar.y + 30 <= bridge.visible.maxY)
        withExtendedLifetime(host) {}
    }

    /// The floating notes panel is a second editor, about 296 pt of column in a 470 pt window, and
    /// its scroll container is its own. Verified rather than assumed: the menu is 299 pt tall, so
    /// this is the surface where "which side has room" is decided by a few points either way.
    @Test func theNotesPanelSizedEditorPlacesItsMenuAgainstTheCaretToo() async throws {
        let (bridge, probe, tv, page, host, _) = try await mounted(width: 380, height: 470, column: 296)
        let caret = Self.emptyLine(40, in: Self.text)
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        try await Task.sleep(for: .milliseconds(150))
        scroll(page, toShow: try #require(bridge.anchor), from: probe)
        try await Task.sleep(for: .milliseconds(100))
        tv.insertText("/", replacementRange: tv.selectedRange())
        tv.setSelectedRange(NSRange(location: caret + 1, length: 0))
        try await Task.sleep(for: .milliseconds(200))

        let anchor = try #require(bridge.anchor)
        #expect(bridge.visible.height <= 470, "the panel's slice, not the panel's document")
        #expect(bridge.visible.width <= 296, "and the column it was laid out at")
        let menu = MarkdownEditing.floating(
            over: anchor, size: CGSize(width: 300, height: 299), in: bridge.visible, prefer: .below
        )
        let touching = menu.below ? anchor.maxY + 6 : anchor.minY - 299 - 6
        #expect(menu.y == touching, """
            In a panel this short the menu cannot always fit either side of the caret — but it \
            still has to touch it. It landed at \(menu.y), \(abs(menu.y - touching)) pt from where \
            the caret is.
            """)
        #expect(menu.x >= bridge.visible.minX, "and no further left than the panel's own column")
        withExtendedLifetime(host) {}
    }
}
