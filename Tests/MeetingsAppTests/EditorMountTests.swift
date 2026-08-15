import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MeetingsApp
import MeetingsCore

/// The parts of this editor that cannot be read off the source: that the probe placed behind the
/// engine's scroll view can actually **find** its `NSTextView`, and that a chosen menu row reaches
/// the document through the engine's bus.
///
/// If the walk fails there is no slash menu, no selection toolbar and no ⌘B — and none of it says
/// so. The engine's `NativeTextView` is `internal` and the wrapper publishes no handle on it, so the
/// app walks up from a sibling view; whether SwiftUI puts a `.background`'s `NSView` somewhere that
/// walk reaches is a fact about SwiftUI, not about this code.
///
/// **No window.** An `NSHostingView` is a view: laying one out builds the representables under it
/// without anything being ordered onto a screen. The activation policy is `.prohibited` for the same
/// reason `MEETINGS_LIVE_EDITOR` gates the suite at all — an ordinary `swift test` builds no AppKit
/// view hierarchy, because the last editor harness that did put a window in front of the operator.
///
/// The anchor **is** reachable here now. It used to go out to the screen and back through
/// `firstRect(forCharacterRange:)`, which needs a window and so could not be checked at all; it
/// comes off the engine's own layout manager and converts straight through the view tree, so
/// "the toolbar hangs off the line the selection is on" is a test rather than a screenshot.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_LIVE_EDITOR"] == "1"))
@MainActor struct EditorMountTests {

    @MainActor private final class Document {
        var text: String
        init(_ text: String) { self.text = text }
        var binding: Binding<String> { Binding(get: { self.text }, set: { self.text = $0 }) }
    }

    private struct Host: View {
        let bridge: MarkdownEditorBridge
        let document: Document

        var body: some View {
            LiveMarkdownEditor(text: document.binding, documentId: "mount-test", bridge: bridge)
                .frame(width: 520)
        }
    }

    /// Builds the editor and waits for the probe to find the text view.
    ///
    /// The hosting view comes back with everything else and every caller keeps it: the bridge holds
    /// the probe and the text view **weakly**, so a host that goes out of scope takes the probe with
    /// it and the bridge quietly stops answering — which is the right ownership in the app and a
    /// trap in a test.
    private func mounted(_ text: String) async throws
        -> (MarkdownEditorBridge, Document, NSTextView, NSView) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let bridge = MarkdownEditorBridge()
        let document = Document(text)
        let host = NSHostingView(rootView: Host(bridge: bridge, document: document))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 600)
        host.layoutSubtreeIfNeeded()
        // Measured on macOS 26 with this arrangement: SwiftUI puts the `.background`'s NSView and
        // the wrapper's NSView side by side under the hosting view —
        //
        //     NSHostingView<Host>
        //       AppKitPlatformViewHost<…MarkdownEditorProbeView>  →  MarkdownEditorProbe
        //       AppKitPlatformViewHost<…NativeTextViewWrapper>    →  ClampedScrollView
        //                                                              NSClipView
        //                                                                NativeTextViewContainer
        //                                                                  NativeTextView
        //
        // — but *not* on the same pass: the probe's first `updateNSView` runs before the sibling
        // exists, which is why the attach retries at all. One turn of the run loop is enough.
        for _ in 0..<25 where !bridge.isAttached {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        let tv = try #require(bridge.textView, """
            The probe never found the engine's NSTextView. Every surface this app adds on top of \
            the library — the slash menu, the selection toolbar, ⌘B — is dead without it, and \
            nothing on screen would say so.
            """)
        return (bridge, document, tv, host)
    }

    @Test func theProbeFindsTheEnginesTextView() async throws {
        let (bridge, _, _, host) = try await mounted("# Standup\n\nA line of prose.\n\n- [ ] tick me\n")
        #expect(bridge.isAttached)
        #expect(bridge.visible.width > 0, "and it has to know the slice it is showing, for the clamp")
        #expect(bridge.visible.height > 0)
        withExtendedLifetime(host) {}
    }

    /// Typing `/h` opens the menu on the two things the engine cannot tell us: that the query is
    /// found in the **displayed** text, and that it narrows.
    @Test func typingASlashOpensTheMenuOverTheEnginesOwnText() async throws {
        let (bridge, _, tv, host) = try await mounted("")
        tv.insertText("/h", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        #expect(bridge.openQuery?.matches.map(\.id) == ["h1", "h2", "h3"])

        tv.insertText("2", replacementRange: tv.selectedRange())
        // Driving the view without focus, the caret does not always end up past a programmatic
        // insert — put it where a typed character would leave it.
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        #expect(tv.string == "/h2")
        #expect(bridge.openQuery?.matches.map(\.id) == ["h2"])
        withExtendedLifetime(host) {}
    }

    /// The whole round trip: the query is swallowed, the verb goes out on the bus, the engine
    /// applies it to its own storage, and the binding the store reads comes back with the result.
    @Test func choosingARowSwallowsTheQueryAndTheEngineAppliesTheVerb() async throws {
        let (bridge, document, tv, host) = try await mounted("")
        tv.insertText("/h2", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        let h2 = try #require(bridge.openQuery?.matches.first)
        bridge.choose(h2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(tv.string == "## ", "the `/h2` went, and the engine put a heading marker in its place")
        #expect(document.text == "## ", "and the binding the store autosaves from has it too")
        withExtendedLifetime(host) {}
    }

    /// `/todo` is the one command the engine's bus has no verb for, and the one this app's CLI reads
    /// back out of the write-up. It asks for a bullet and types the box into the line that made.
    @Test func theActionCommandProducesATaskItemTheCLICanRead() async throws {
        let (bridge, document, tv, host) = try await mounted("")
        tv.insertText("/todo", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        let todo = try #require(bridge.openQuery?.matches.first)
        #expect(todo.action == .taskList)
        bridge.choose(todo)
        try await Task.sleep(for: .milliseconds(50))
        #expect(tv.string == "- [ ] ")
        #expect(MarkdownActions.taskItem(document.text) != nil, """
            The store has to hold a line `meetings actions list` recognises — the box is the \
            contract between the write-up and the CLI, not decoration.
            """)
        withExtendedLifetime(host) {}
    }

    // MARK: - Where the surfaces hang

    /// The anchor lands on the line the selection is on, a long way down a document.
    ///
    /// Both surfaces are placed against this rect, and the last two times this was wrong they were
    /// wrong together: an estimate that ran ~50 pt short and got worse further down, then a clamp
    /// against the editor's frame that put the menu 300 pt above the caret. This checks the first
    /// half — that the rect is the line's real one — against the engine's own layout manager.
    @Test func theAnchorLandsOnTheLineTheSelectionIsOn() async throws {
        let paragraphs = (0..<60).map {
            "Paragraph \($0) with enough prose on it that the column has to wrap it at least once."
        }
        let (bridge, _, tv, host) = try await mounted(paragraphs.joined(separator: "\n\n"))
        let target = NSRange(location: 3000, length: 9)
        tv.setSelectedRange(target)
        try await Task.sleep(for: .milliseconds(120))

        let anchor = try #require(bridge.anchor, """
            No anchor, so neither surface can be placed. It needs no window now — a nil here is \
            the walk failing or the layout manager refusing the range, not a missing screen.
            """)
        // What the engine's own layout says, measured independently of the bridge.
        let layout = try #require(tv.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let start = try #require(content.location(layout.documentRange.location, offsetBy: target.location))
        let end = try #require(content.location(start, offsetBy: target.length))
        let span = try #require(NSTextRange(location: start, end: end))
        var drawn = CGRect.null
        layout.enumerateTextSegments(in: span, type: .standard, options: []) { _, segment, _, _ in
            drawn = drawn.isNull ? segment : drawn.union(segment)
            return true
        }
        #expect(!drawn.isNull)
        #expect(abs(anchor.minY - (drawn.minY + tv.textContainerOrigin.y)) < 0.5, """
            The anchor is \(anchor.minY) where the text is drawn at \
            \(drawn.minY + tv.textContainerOrigin.y). That gap is the class of bug that put both \
            floating surfaces above the line they belong to, and it grows with the document.
            """)
        #expect(abs(anchor.minX - (drawn.minX + tv.textContainerOrigin.x)) < 0.5)
        #expect(anchor.height > 0)
        withExtendedLifetime(host) {}
    }

    // MARK: - The end of the document

    /// The anchor resolves for a caret **at the end of the document**, including on a trailing empty
    /// line — the region TextKit 2 gets wrong often enough that the engine carries two workarounds
    /// for it (`FB15131180`, `FB22524198`).
    ///
    /// Measured, and it resolves: 1 segment, on the caret's own line, at every one of these. The
    /// anchor was the suspect for "the menu opens at the top of the summary" and it is not the
    /// cause — this test is here so the next person does not have to measure it again.
    @Test func theAnchorResolvesForEveryCaretAtTheEndOfTheDocument() async throws {
        let body = (0..<40).map { "Paragraph \($0) with enough prose that the column wraps it once." }
            .joined(separator: "\n\n")
        // The four positions: the last character, the end with no trailing newline, an empty final
        // line, an empty line mid-document, and a document that is one empty line.
        let cases: [(String, String, (NSString) -> Int)] = [
            ("the last character", body, { $0.length - 1 }),
            ("the end, no trailing newline", body, { $0.length }),
            ("after a trailing newline", body + "\n", { $0.length }),
            ("an empty line mid-document", "alpha\n\nbeta\n", { _ in 6 }),
            ("a document that is one empty line", "", { _ in 0 }),
        ]
        for (what, text, caret) in cases {
            let (bridge, _, tv, host) = try await mounted(text)
            try await Task.sleep(for: .milliseconds(80))
            let at = caret(tv.string as NSString)
            tv.setSelectedRange(NSRange(location: at, length: 0))
            try await Task.sleep(for: .milliseconds(120))

            let anchor = try #require(bridge.anchor, """
                No anchor with the caret at \(what). Both floating surfaces are gated on it, so the \
                slash menu would not open at all.
                """)
            #expect(anchor.height > 0, "a caret has no width, but it has a line height — \(what)")
            #expect(anchor.minY.isFinite && anchor.minX.isFinite)
            // On the caret's own line, not at the editor's origin: the extra line fragment of a
            // document that has any text in it is never at y = 0.
            if !text.isEmpty {
                #expect(anchor.minY > 0, """
                    The anchor for \(what) came back at the editor's origin (\(anchor)). That is \
                    what a failed measurement looks like, and it puts the menu at the top of the \
                    summary.
                    """)
            }
            withExtendedLifetime(host) {}
        }
    }

    /// **The reported defect.** A caret on the last line of the write-up, with the page scrolled so
    /// the tail of it sits near the top of the viewport, opens its menu *on screen*.
    ///
    /// `visible` used to be the clip view intersected with the editor's own bounds, which made
    /// `visible.maxY` the bottom of the **document**. At the end of a document there is nothing
    /// below the last line, so "room below the caret" was always zero — and with the page scrolled
    /// down there is little room above either, so the menu was drawn 305 pt above the caret and off
    /// the top of the page. What is left on screen is a sliver at the top of the summary, which is
    /// exactly how it was reported.
    ///
    /// Nothing below the last line is a fact about the editor, not about the screen: these surfaces
    /// are clipped by the *page's* scroll view, and a menu under the final line is drawn over
    /// whatever the page has below the write-up.
    @Test func theMenuOpensOnScreenWithTheCaretOnTheLastLine() async throws {
        let (bridge, probe, page, tv, host) = try await onAPage()
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        try await Task.sleep(for: .milliseconds(250))
        // Scrolled so the last line sits 40 pt below the top of the page: the write-up is all but
        // scrolled past, and the line being typed on is the last of it still showing.
        let line = try #require(bridge.anchor)
        scroll(page, probe, putting: line.minY, belowTheTopBy: 40)
        try await Task.sleep(for: .milliseconds(250))

        tv.insertText("/", replacementRange: tv.selectedRange())
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        try await Task.sleep(for: .milliseconds(250))

        #expect(bridge.openQuery != nil, "the slash has to have opened a menu at all")
        let anchor = try #require(bridge.anchor)
        let onScreen = probe.convert(page.contentView.bounds, from: page.contentView)
        // 300 × 299 is the slash menu — see `SlashMenu`, which is `.frame(width: 300)`.
        let placed = MarkdownEditing.floating(
            over: anchor, size: CGSize(width: 300, height: 299), in: bridge.visible, prefer: .below
        )
        #expect(placed.y >= onScreen.minY, """
            The menu is placed at \(placed.y) with the page showing \(onScreen.minY)…\
            \(onScreen.maxY). It is \(onScreen.minY - placed.y) pt off the top of the page — a \
            sliver of menu at the top of the summary, over the line you are not typing on.
            """)
        #expect(placed.y + 299 <= onScreen.maxY, "and it fits under the caret rather than overflowing")
        #expect(placed.below, "there is a screenful of page below the write-up; that is where it goes")
        withExtendedLifetime(host) {}
    }

    /// The selection toolbar shares the fault, because it reads the same `visible`.
    ///
    /// It is 36 pt rather than 299, so it survives a viewport the menu cannot — but with the tail of
    /// the write-up in a band shorter than the toolbar itself, "room below" being zero pushed it off
    /// the top of the page in the same way.
    @Test func theToolbarOpensOnScreenOverASelectionEndingAtTheLastCharacter() async throws {
        // No trailing newline: the last line of text *is* the last line of the document, which is
        // what "a selection ending at the last character" means.
        let (bridge, probe, page, tv, host) = try await onAPage(trailingBlankLine: false)
        let end = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: end - 6, length: 6))
        try await Task.sleep(for: .milliseconds(250))
        // Scrolled so the selected line sits 20 pt below the top of the page — a band of write-up
        // shorter than the toolbar, which is the geometry that used to push it off the top. Driven
        // off the measured anchor rather than a guess at the line height.
        let line = try #require(bridge.anchor)
        scroll(page, probe, putting: line.minY, belowTheTopBy: 20)
        try await Task.sleep(for: .milliseconds(250))

        #expect(bridge.selection.length == 6, "the toolbar is gated on a real selection")
        let anchor = try #require(bridge.anchor)
        let onScreen = probe.convert(page.contentView.bounds, from: page.contentView)
        let placed = MarkdownEditing.floating(
            over: anchor, size: CGSize(width: 280, height: 36), in: bridge.visible, prefer: .above
        )
        #expect(placed.y >= onScreen.minY, """
            The toolbar is placed at \(placed.y) with the page showing \(onScreen.minY)…\
            \(onScreen.maxY) — off the top of the page, over text the selection is not on.
            """)
        #expect(placed.y + 36 <= onScreen.maxY)
        withExtendedLifetime(host) {}
    }

    // MARK: - A page that scrolls

    /// The editor as the app mounts it: inside a `ScrollView`, with a screenful of page below it —
    /// the transcript sections, on the real screen. Without something under the write-up there is no
    /// difference between "the bottom of the document" and "the bottom of the screen", which is the
    /// whole distinction the two tests above turn on.
    private struct ScrollingPage: View {
        let bridge: MarkdownEditorBridge
        let document: Document

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Meeting title").frame(height: 60)
                    LiveMarkdownEditor(text: document.binding, documentId: "page-test", bridge: bridge)
                        .frame(maxWidth: 520)
                    Text("Transcript").frame(height: 600)
                }
                .padding(20)
            }
        }
    }

    private func onAPage(trailingBlankLine: Bool = true) async throws
        -> (MarkdownEditorBridge, MarkdownEditorProbe, NSScrollView, NSTextView, NSView) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let bridge = MarkdownEditorBridge()
        let text = (0..<50).map { "Paragraph \($0) with enough prose that the column wraps it once." }
            .joined(separator: "\n\n") + (trailingBlankLine ? "\n\n" : "")
        let host = NSHostingView(rootView: ScrollingPage(bridge: bridge, document: Document(text)))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 700)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<50 where !bridge.isAttached {
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        let tv = try #require(bridge.textView, "the probe never found the engine's NSTextView")
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()

        var probe: MarkdownEditorProbe?
        var page: NSScrollView?
        walk(host) { view in
            if let found = view as? MarkdownEditorProbe { probe = found }
            // The page's scroll view, not the engine's: the engine's holds the text view.
            if page == nil, let found = view as? NSScrollView, !(found.documentView is NSTextView) {
                page = found
            }
        }
        return (bridge, try #require(probe), try #require(page), tv, host)
    }

    private func walk(_ view: NSView, _ into: (NSView) -> Void) {
        into(view)
        for sub in view.subviews { walk(sub, into) }
    }

    /// Scrolls the page down until `y` — a position in the editor's own coordinates, measured off
    /// the anchor rather than guessed from a line height — sits `gap` points below the top of the
    /// viewport. "Scrolled down to the bottom", with the line being typed on the last band of
    /// write-up still on screen.
    private func scroll(
        _ page: NSScrollView, _ probe: MarkdownEditorProbe, putting y: CGFloat, belowTheTopBy gap: CGFloat
    ) {
        let top = page.contentView.convert(probe.bounds, from: probe).origin.y
        page.contentView.scroll(to: NSPoint(x: 0, y: top + y - gap))
        page.reflectScrolledClipView(page.contentView)
    }

    /// `~~struck~~` is drawn struck through.
    ///
    /// The engine parses pure markdown and ships strikethrough as an **opt-in extension**; with the
    /// library's empty default the tildes stayed literal text, so the write-up rendered nothing and
    /// the toolbar offered a mark the document could not show. This asserts the attribute is on the
    /// storage the engine is drawing from, which is the only place the answer lives.
    @Test func strikethroughIsRenderedRatherThanLeftAsTildes() async throws {
        let (_, _, tv, host) = try await mounted("plain ~~struck~~ text\n")
        try await Task.sleep(for: .milliseconds(120))
        let storage = try #require(tv.textStorage)
        var struck: [NSRange] = []
        storage.enumerateAttribute(
            .strikethroughStyle, in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            if value != nil { struck.append(range) }
        }
        #expect(struck.contains { NSEqualRanges($0, NSRange(location: 8, length: 6)) }, """
            `struck` carries no strikethrough. StrikethroughExtension is not registered in the \
            editor's configuration, so the engine is treating `~~` as ordinary characters — which \
            is exactly what "strikethroughs are not rendering" looks like. Found: \(struck).
            """)
        withExtendedLifetime(host) {}
    }

    /// The link button leaves the caret where the URL goes.
    ///
    /// The engine wraps the selection as `[text]()` and parks the caret **past** the closing paren,
    /// so the one thing left to type cannot be typed and the link stays targetless — which the
    /// theme draws in `incompleteLink` grey.
    @Test func theLinkButtonLeavesTheCaretInsideTheEmptyTarget() async throws {
        let (bridge, _, tv, host) = try await mounted("click here\n")
        tv.setSelectedRange(NSRange(location: 0, length: 5))
        try await Task.sleep(for: .milliseconds(40))
        bridge.run(.link)
        try await Task.sleep(for: .milliseconds(80))
        #expect(tv.string == "[click]() here\n")
        #expect(tv.selectedRange() == NSRange(location: 8, length: 0), """
            The caret is at \(tv.selectedRange().location); the target goes at 8, between the \
            parens. Anywhere else and the button hands you a link you cannot finish.
            """)
        withExtendedLifetime(host) {}
    }

    /// Bold from the toolbar wraps the selection *and* lights the button, which is the engine's own
    /// answer coming back on this editor's own bus name.
    @Test func boldFromTheToolbarWrapsTheSelectionAndLightsTheButton() async throws {
        let (bridge, document, tv, host) = try await mounted("hello world\n")
        tv.setSelectedRange(NSRange(location: 6, length: 5))
        try await Task.sleep(for: .milliseconds(60))
        #expect(bridge.isBold == false)
        bridge.run(.bold)
        try await Task.sleep(for: .milliseconds(80))
        #expect(tv.string == "hello **world**\n")
        #expect(document.text == "hello **world**\n")
        #expect(bridge.isBold, "and the button has to say so, or ⌘B and the toolbar disagree")
        withExtendedLifetime(host) {}
    }
}
