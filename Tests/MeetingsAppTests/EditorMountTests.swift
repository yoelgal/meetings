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
/// What this therefore *cannot* reach is the anchor rect: `firstRect(forCharacterRange:)` is in
/// screen coordinates and there is no screen. Where the menu lands needs the running app.
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
        #expect(bridge.width > 0, "and it has to know the width it was laid out at, for the clamp")
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
}
