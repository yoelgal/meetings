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
        #expect(MarkdownSyntax.taskItem(document.text) != nil, """
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
