import AppKit
import MeetingsCore
import SwiftUI
import Testing

@testable import MeetingsApp

/// A real `MarkdownNSTextView`, wired the way ``MarkdownTextView/makeNSView(context:)`` wires it,
/// in a window nobody can see.
///
/// **It never takes focus, never makes a sound, and is never ordered onto the screen.**
///
/// That last clause was learned the hard way. The window used to be `orderBack(nil)`ed, on the
/// reasoning that ordering *back* is not ordering *front* and therefore draws nothing. It is not:
/// `orderBack` puts a window on the screen like any other, merely behind its siblings, and a
/// `.titled` window sized to a full document is then a large panel sitting in the operator's way. It
/// appeared over his work twice. `.prohibited` did not save it either — an activation policy governs
/// *activation*, not visibility, so it stopped the focus being stolen and did nothing about the
/// window being drawn.
///
/// Nothing here needs an on-screen window. `makeFirstResponder` does not, TextKit 2 layout does not,
/// and `cacheDisplay(in:to:)` does not. So the window is borderless, fully transparent, out of the
/// windows menu, parked at (-10000, -10000), and never ordered anywhere.
///
/// The suites that use it are gated behind `MEETINGS_LIVE_EDITOR=1` as well, so an ordinary
/// `swift test` never constructs one at all — the same treatment `MEETINGS_LIVE_STREAM` and
/// `MEETINGS_LIVE_FIT` already get for tests that are not ordinary unit tests.
///
/// **No synthesised mouse events.** They were tried, and twice over they were the wrong tool:
/// `NSTextView.mouseDown` runs a nested `nextEventMatchingMask` loop that pumps the run loop, and
/// pumping the run loop underneath swift-testing ended the test *process* mid-suite with a zero
/// exit code — a suite that silently stops running is worse than no suite. And the events
/// themselves were not faithful: a stock `NSTextView`, no subclass and no styling, answered the
/// same synthesised down-and-up with a one-character selection where a hand gets a caret, because
/// the two ends of the gesture round across a glyph boundary differently.
///
/// What is driven instead is the pair of calls that loop makes — see ``clickResolvesTwice(at:)``.
@MainActor
final class EditorHarness {
    let window: NSWindow
    let view: MarkdownNSTextView
    let coordinator: MarkdownTextView.Coordinator
    private let store = Store()

    /// No path — success, failure or a thrown error — may leave a window behind.
    deinit { window.orderOut(nil) }

    /// The document as the bindings hold it — what autosave would write.
    var text: String { store.text }

    /// The anchors as the editor published them — what the slash menu and the toolbar hang off.
    var publishedCaretRect: CGRect? { store.caretRect }
    var publishedSelectionRect: CGRect? { store.selectionRect }

    @MainActor private final class Store {
        var text = ""
        var selection: Range<Int> = 0..<0
        var caretRect: CGRect?
        var selectionRect: CGRect?
    }

    static let width: CGFloat = 560

    /// One application for the process, never activated. Creating an `NSWindow` at all needs it.
    private static let application: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        return app
    }()

    init(_ text: String) {
        _ = Self.application
        store.text = text
        let store = self.store
        let representable = MarkdownTextView(
            text: Binding(get: { store.text }, set: { store.text = $0 }),
            selection: Binding(get: { store.selection }, set: { store.selection = $0 }),
            caretRect: Binding(get: { store.caretRect }, set: { store.caretRect = $0 }),
            selectionRect: Binding(get: { store.selectionRect }, set: { store.selectionRect = $0 }),
            handle: MarkdownEditorHandle(),
            intercept: { _ in false }
        )
        coordinator = MarkdownTextView.Coordinator(representable)
        window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: Self.width + 60, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // Belt and braces behind "never ordered": a window that is never on screen does not need to
        // be invisible, but if some future call orders it anyway, it has nothing to draw and no way
        // into the windows menu.
        window.alphaValue = 0
        window.isExcludedFromWindowsMenu = true
        view = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 800))
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.size = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = coordinator
        view.allowsUndo = true
        view.drawsBackground = false
        view.isRichText = false
        view.font = MarkdownStyle.bodyFont
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 6)
        view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        view.string = text
        let coordinator = self.coordinator
        view.toggleTask = { [weak coordinator] offset in coordinator?.toggleTask(at: offset) }
        coordinator.attach(view)

        window.contentView?.addSubview(view)
        // Deliberately not ordered — not front, not back. See the type's documentation: `orderBack`
        // is still on screen, and it landed on the operator's display.
        let height = view.markdownDocumentHeight(atWidth: Self.width)
        view.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        _ = view.markdownDocumentHeight(atWidth: Self.width)
        window.makeFirstResponder(view)
    }

    // MARK: - Where things are

    /// A point a quarter of the way into the character at `offset`, in the view's own coordinates.
    func point(atCharacter offset: Int) -> CGPoint {
        let utf16 = (String(view.string.prefix(offset)) as NSString).length
        let length = min(1, (view.string as NSString).length - utf16)
        guard let rect = view.markdownRect(for: NSRange(location: utf16, length: length))
        else { return .zero }
        return CGPoint(x: rect.minX + rect.width * 0.25, y: rect.midY)
    }

    /// A point inside the first occurrence of `needle`.
    func point(inside needle: String, offsetBy into: Int = 2) -> CGPoint {
        point(atCharacter: characterIndex(inside: needle, offsetBy: into))
    }

    /// The UTF-16 offset a little way into the first occurrence of `needle`.
    func characterIndex(inside needle: String, offsetBy into: Int = 2) -> Int {
        guard let found = view.string.range(of: needle) else { return 0 }
        let prefix = String(view.string[view.string.startIndex..<found.lowerBound])
        return (prefix as NSString).length + into
    }

    // MARK: - The two halves of a click

    /// What one stationary click resolves to, at its two ends.
    ///
    /// `NSTextView.mouseDown` is the whole gesture: it maps the press to a character, sets the
    /// selection with `stillSelecting: true`, and then keeps mapping the *same* point to a
    /// character on every event until the button comes up, extending the selection to whatever it
    /// last read. A click a hand would call stationary therefore resolves the identical point at
    /// least twice, with the selection delegate having run in between — and it must get the same
    /// answer both times, or the caret it was going to drop becomes a range.
    ///
    /// This is that, without the nested event loop: resolve, notify, resolve again.
    func clickResolvesTwice(at point: CGPoint) -> (down: Int, up: Int) {
        let down = view.characterIndexForInsertion(at: point)
        // Exactly what the tracking loop does with the press, delegate notification and all.
        view.setSelectedRange(
            NSRange(location: down, length: 0), affinity: .downstream, stillSelecting: true
        )
        let up = view.characterIndexForInsertion(at: point)
        view.setSelectedRange(
            NSRange(location: min(down, up), length: abs(up - down)),
            affinity: .downstream, stillSelecting: false
        )
        return (down, up)
    }

    /// A click on a checkbox, through the view's real hit-test. This path returns before `super`,
    /// so no tracking loop is entered and no event queue is involved.
    func clickCheckbox(_ box: MarkdownNSTextView.Checkbox) {
        let inWindow = view.convert(CGPoint(x: box.rect.midX, y: box.rect.midY), to: nil)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        view.mouseDown(with: event)
    }

    // MARK: - What it looks like

    /// The view, drawn through AppKit's own cycle — `viewWillDraw`, the text, then the subviews.
    func rendered() -> NSBitmapImageRep? {
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Whether anything at all is painted in `rect` other than the background — which, over the
    /// three characters of a task item's box, means a checkbox.
    func hasInk(in rect: CGRect, of image: NSBitmapImageRep) -> Bool {
        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        var seen = Set<String>()
        for x in stride(from: rect.minX + 1, to: rect.maxX - 1, by: 1.0) {
            for y in stride(from: rect.minY + 1, to: rect.maxY - 1, by: 1.0) {
                guard let colour = image.colorAt(x: Int(x * scale), y: Int(y * scale)) else { continue }
                seen.insert(String(format: "%.2f-%.2f-%.2f", colour.redComponent,
                                   colour.greenComponent, colour.blueComponent))
            }
        }
        // One colour across the whole box means nothing was drawn into it.
        return seen.count > 1
    }
}
