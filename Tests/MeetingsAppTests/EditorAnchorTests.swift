import AppKit
import Foundation
import MeetingsCore
import SwiftUI
import Testing

@testable import MeetingsApp

/// A write-up long enough that the detail pane has to scroll it, with something recognisable near
/// the bottom to aim an anchor at. Forty wrapping paragraphs is about 2,300 pt at the reading
/// measure — a real meeting's write-up with its actions on the end.
let longWriteUp: String = {
    var lines: [String] = ["## Summary", ""]
    for index in 1...40 {
        lines.append(
            "Paragraph \(index): the team walked through the migration plan and agreed the "
                + "**cutover** window is the last week of the month, so the plan is one push."
        )
        lines.append("")
    }
    lines.append("## Actions")
    lines.append("")
    lines.append("- [ ] Draft the rollout note")
    lines.append("- [x] Book the war room")
    lines.append("- [ ] Tell support what changes")
    return lines.joined(separator: "\n")
}()

/// The editor mounted the way the app mounts it — through SwiftUI, in a window nobody can see.
///
/// Same rules as ``EditorHarness``, for the same reason: borderless, fully transparent, out of the
/// windows menu, parked off every screen and **never ordered anywhere**, ordered out on deinit.
/// `NSHostingView` lays out, draws and scrolls perfectly well in a window that was never put on
/// screen, so none of what this measures needs one.
///
/// It exists because ``EditorHarness`` builds the text view by hand, and half of what was suspected
/// here was SwiftUI's doing — the width it proposes, the frame it settles on, the coordinate space
/// the overlays are aligned in. This mounts the **real** ``SharedFieldEditor`` inside the **real**
/// shape of the detail pane, so those are measured rather than argued about.
@MainActor
final class HostedEditorHarness {
    let window: NSWindow
    let host: NSHostingView<AnyView>

    deinit { window.orderOut(nil) }

    /// One application for the process, never activated. Creating an `NSWindow` at all needs it.
    private static let application: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        return app
    }()

    /// The text view SwiftUI made, found in the hosted tree.
    var view: MarkdownNSTextView! { Self.find(in: host) }

    private static func find(in view: NSView) -> MarkdownNSTextView? {
        if let found = view as? MarkdownNSTextView { return found }
        for child in view.subviews {
            if let found = find(in: child) { return found }
        }
        return nil
    }

    /// - Parameter pane: the width the container gets. 700 pt is the narrow detail pane the defects
    ///   were reported from; 380 pt is the floating notes panel's default and 300 pt is one dragged
    ///   narrower still, which is where the editor is furthest from the column it is capped to.
    init(_ text: String, pane: CGFloat, height: CGFloat = 900) {
        _ = Self.application
        let root = AnyView(
            ScrollViewReader { _ in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("A meeting").font(.title2)
                            Text("14 Aug 2026 · 14:53 · 8 min").font(.caption)
                        }
                        SharedFieldEditor(
                            title: "Summary", value: text, identity: "summary:probe",
                            placeholder: "Write it up here.", oversizeHint: "",
                            save: { _ in }, titleShown: false
                        )
                        Text("Your notes")
                        Text("Transcript")
                    }
                    .frame(
                        maxWidth: SharedFieldEditor.column + 2 * SharedFieldEditor.editorInset,
                        alignment: .leading
                    )
                    .padding(detailInset)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(width: pane, height: height, alignment: .topLeading)
        )
        window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: pane, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.alphaValue = 0
        window.isExcludedFromWindowsMenu = true
        host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: pane, height: height)
        window.contentView?.addSubview(host)
        // Deliberately not ordered — not front, not back. See ``EditorHarness``.
        host.layoutSubtreeIfNeeded()
        host.layout()
    }

    /// Enough runloop turns for `.task`, `onChange` and the deferred `publishRects` to land.
    func settle() async {
        for _ in 0..<12 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            host.layout()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        host.layoutSubtreeIfNeeded()
    }
}

/// Where a range is, measured a second way, so the assertion is not the code checking itself.
///
/// `firstRect(forCharacterRange:actualRange:)` is `NSTextInputClient` — the call the input method
/// system makes to place a candidate window — and it shares nothing with
/// ``NSTextView/markdownRect(for:)`` but the layout underneath. It answers in *screen* coordinates,
/// so converting back through the window is an independent route to the same question.
///
/// It declines anything outside the window's own bounds, which is most of a long document — hence
/// the `guard` at each call site rather than an assertion that it always answers.
@MainActor
func independentRect(_ view: NSTextView, _ range: NSRange) -> CGRect? {
    var actual = NSRange()
    let onScreen = view.firstRect(forCharacterRange: range, actualRange: &actual)
    guard onScreen.width > 0 || onScreen.height > 0, let window = view.window else { return nil }
    return view.convert(window.convertFromScreen(onScreen), from: nil)
}

/// The UTF-16 range of the first occurrence of `needle`.
@MainActor
func utf16Range(of needle: String, in view: NSTextView) -> NSRange? {
    guard let found = view.string.range(of: needle) else { return nil }
    let prefix = String(view.string[view.string.startIndex..<found.lowerBound])
    return NSRange(location: (prefix as NSString).length, length: (needle as NSString).length)
}

/// **An anchor says where the text is, not where a half-finished layout guesses it is.**
///
/// This is the slash menu opening far above the caret and the selection toolbar drawing up by the
/// metadata chips, stated as an invariant.
///
/// TextKit 2 lays out lazily *and estimates what it has not laid out yet*, and a fragment's frame is
/// measured from the top of the document down through everything above it. So a rect asked for with
/// only its own range laid out is measured through an estimate — and the estimate is always short,
/// because it is one line where the real text wraps to two. ``NSTextView/markdownRect(for:)`` used
/// to `ensureLayout` the range it was asked about and nothing else, while
/// ``NSTextView/markdownDocumentHeight(atWidth:)`` has always laid out the whole document. That is
/// the whole of it: the height was measured against the real layout and the anchors against a guess,
/// which is exactly why the write-up was the right height and the surfaces over it were not.
///
/// **Serialized**, and behind `MEETINGS_LIVE_EDITOR=1`, for the reasons ``EditorHarness`` gives.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_LIVE_EDITOR"] == "1"))
struct EditorAnchorTests {
    /// The anchor the slash menu hangs off, one keystroke after the `/` that opens it.
    ///
    /// Measured on a 2,378 pt document, typing `/he` at the end: the published caret came back at
    /// **y = 2303.18** where the text is at **y = 2352.77** — 49.6 pt too high off a single
    /// keystroke's worth of invalidated layout, and growing with how much is still an estimate.
    @Test func theCaretAnchorIsWhereTheCaretIs() throws {
        let harness = EditorHarness(longWriteUp + "\n\n")
        let view = harness.view
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        for character in "/he" {
            view.insertText(String(character), replacementRange: view.selectedRange())
        }
        harness.coordinator.publishRects()

        let caret = NSRange(location: view.selectedRange().location, length: 0)
        // The truth: the same question, of a document that is entirely laid out.
        view.textLayoutManager.map { $0.ensureLayout(for: $0.documentRange) }
        let truth = try #require(view.markdownRect(for: caret))
        let published = try #require(harness.publishedCaretRect)
        #expect(abs(published.minY - truth.minY) < 0.5, """
            The slash menu hangs off this. It was published \(truth.minY - published.minY) pt above \
            the caret it belongs under.
            """)
    }

    /// The same, for the anchor the selection toolbar hangs off. Measured over `Paragraph 20` of the
    /// long write-up: published **y = 1080.00** — a suspiciously round number, which is what an
    /// estimate looks like — against **y = 1087.90**, where the words are.
    @Test func theSelectionAnchorIsWhereTheSelectionIs() throws {
        let harness = EditorHarness(longWriteUp)
        let view = harness.view
        let selection = try #require(utf16Range(of: "Paragraph 20:", in: view))
        view.setSelectedRange(selection)
        harness.coordinator.endMouseTracking()

        view.textLayoutManager.map { $0.ensureLayout(for: $0.documentRange) }
        let truth = try #require(view.markdownRect(for: selection))
        let published = try #require(harness.publishedSelectionRect)
        #expect(abs(published.minY - truth.minY) < 0.5, """
            The selection toolbar hangs off this. It was published \
            \(truth.minY - published.minY) pt above the words it belongs over.
            """)
    }

    /// The invariant underneath both: **how much of the document happens to be laid out must not
    /// change where the text is said to be.**
    ///
    /// Measured before the fix, with the layout invalidated: the last action line reported
    /// y = 2290.59 against its real y = 2316.18 — 25.6 pt of accumulated estimate on a 2,328 pt
    /// document, and every rect below it inherits it.
    @Test func theAnchorDoesNotDependOnHowMuchIsLaidOut() throws {
        let harness = EditorHarness(longWriteUp)
        let view = harness.view
        let layout = try #require(view.textLayoutManager)
        let target = try #require(utf16Range(of: "Tell support", in: view))

        layout.ensureLayout(for: layout.documentRange)
        let settled = try #require(view.markdownRect(for: target))

        layout.invalidateLayout(for: layout.documentRange)
        let cold = try #require(view.markdownRect(for: target))

        #expect(abs(cold.minY - settled.minY) < 0.5,
                "an anchor read off a cold layout is \(settled.minY - cold.minY) pt out")
    }

    /// Both anchors against an independent measurement, in the shapes this editor is actually
    /// mounted in: the detail pane and the notes panel, a document that fits and one that scrolls.
    ///
    /// This is the check that the rect is in the *view's* coordinate space and not the text
    /// container's — `textContainerOrigin` is added on the way out, and the two agree to the last
    /// bit in every one of these, which is how that suspicion was ruled out rather than argued with.
    @Test("the anchor is in the view's own space", arguments: [CGFloat(700), 380])
    func theAnchorIsInTheViewsSpace(pane: CGFloat) async throws {
        for document in [writeUp, longWriteUp] {
            let harness = HostedEditorHarness(document, pane: pane)
            await harness.settle()
            let view = try #require(harness.view)
            for needle in ["## Summary", "Book the war", "Tell support"] {
                guard let target = utf16Range(of: needle, in: view),
                      let theirs = independentRect(view, target)
                else { continue }
                let ours = try #require(view.markdownRect(for: target))
                #expect(abs(ours.minY - theirs.minY) < 0.5)
                #expect(abs(ours.minX - theirs.minX) < 0.5)
            }
        }
    }

    /// **The editor is exactly as tall as its document, at the width it is laid out at.**
    ///
    /// The reported gap — nine hundred points of empty editor before the collapsed sections — is
    /// this failing. It does not fail here: measured through the real detail pane, the frame SwiftUI
    /// settles on and the height the document occupies at that frame's width agree to within a
    /// point in every container and both documents.
    @Test("the height is the height at the width it is laid out at",
          arguments: [CGFloat(700), 380, 300])
    func theHeightMatchesTheLayout(pane: CGFloat) async throws {
        for document in [writeUp, longWriteUp] {
            let harness = HostedEditorHarness(document, pane: pane)
            await harness.settle()
            let view = try #require(harness.view)
            let laidOut = view.markdownDocumentHeight(atWidth: view.frame.width)
            #expect(abs(view.frame.height - laidOut) <= 1, """
                the editor is framed \(view.frame.height) pt tall for \(laidOut) pt of document at \
                \(view.frame.width) pt wide
                """)
        }
    }

    /// A height measured at one width and laid out at another is the classic version of that same
    /// gap, so it is pinned separately: the answer has to be a pure function of the text and the
    /// width, whatever the view was doing beforehand.
    ///
    /// Measured: 2341 pt at 520 pt wide and 3805 pt at 340 pt, whether the view has just come from
    /// the other width or has never been laid out at all.
    @Test func theHeightIsAPureFunctionOfTheWidth() {
        let fresh520 = EditorHarness(longWriteUp).view.markdownDocumentHeight(atWidth: 520)
        let fresh340 = EditorHarness(longWriteUp).view.markdownDocumentHeight(atWidth: 340)
        #expect(fresh340 > fresh520, "narrower wraps more, so it is taller")

        let view = EditorHarness(longWriteUp).view
        #expect(view.markdownDocumentHeight(atWidth: 340) == fresh340)
        #expect(view.markdownDocumentHeight(atWidth: 520) == fresh520)
        #expect(view.markdownDocumentHeight(atWidth: 340) == fresh340)
    }

    /// **The clamp is the editor's real measure, not the column the detail pane happens to use.**
    ///
    /// `.frame(maxWidth:)` is a cap, so the two other mounts of this editor — the pre-meeting notes
    /// pane and the floating notes panel — lay it out narrower than the column. Measured: a 700 pt
    /// detail pane gives the editor 520 pt, a 380 pt notes panel 296 pt and a 300 pt one 216 pt.
    /// The slash menu is 300 × 299 and the toolbar 277 × 30, so clamped against a hardcoded 520 the
    /// menu was free to sit at x = 220 inside a 296 pt editor and run 224 pt out through the
    /// panel's clip.
    @Test("the surfaces stay inside the editor", arguments: [CGFloat(700), 380, 300])
    func theSurfacesStayInsideTheEditor(pane: CGFloat) async throws {
        let harness = HostedEditorHarness(writeUp, pane: pane)
        await harness.settle()
        let measure = try #require(harness.view).frame.width
        if pane < SharedFieldEditor.column {
            #expect(measure < SharedFieldEditor.column, """
                a \(pane) pt pane lays the editor out at \(measure) pt, not at the \
                \(SharedFieldEditor.column) pt column — which is the whole reason the clamp cannot \
                be that constant
                """)
        }
        let anchor = CGRect(x: measure - 40, y: 400, width: 30, height: 18)

        for surface in [CGSize(width: 300, height: 299), CGSize(width: 277, height: 30)] {
            let placed = MarkdownEditing.floating(over: anchor, size: surface, in: measure)
            #expect(placed.x >= 0)
            #expect(placed.x + surface.width <= max(measure, surface.width) + 0.5, """
                a \(surface.width) pt surface placed at x = \(placed.x) runs \
                \(placed.x + surface.width - measure) pt past the \(measure) pt editor
                """)
        }
    }
}
