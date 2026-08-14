import AppKit
import MeetingsCore
import SwiftUI

/// The write-up's text engine: AppKit's `NSTextView`, wrapped thinly.
///
/// **Why not SwiftUI's `TextEditor`.** It was, and the measurement that moved it is worth keeping.
/// `TextEditor(text: Binding<AttributedString>)` works in `AttributeScopes.SwiftUIAttributes`, and
/// that scope has no paragraph-style key and no indent key at all — font, colours, `kern`,
/// `tracking`, `baselineOffset`, and macOS 26's `alignment` and `lineHeight`, and nothing else. A
/// hanging indent is not expressible in it, and neither is asking where the selection is on screen:
/// `AttributedTextSelection` yields `AttributedString.Index`es and no geometry whatsoever. The
/// gutter needs the first, and the floating toolbar and the slash menu need the second.
///
/// What did **not** change is the thing that matters: the value of record is still the plain
/// `String` the CLI writes. Autosave, the two-writer conflict banner and the oversize guard sit
/// where they always did, above this view, working off that string.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    /// The selection as character offsets — the unit ``MarkdownEditing`` and ``MarkdownSyntax``
    /// speak, and never UTF-16, which is the one that lands a caret inside an emoji.
    @Binding var selection: Range<Int>
    /// Where the caret and the selection are on screen, in this view's own coordinates, for the
    /// slash menu and the toolbar to hang off. Nil when there is nothing laid out to point at.
    @Binding var caretRect: CGRect?
    @Binding var selectionRect: CGRect?
    let handle: MarkdownEditorHandle
    /// Keys the menu wants before the text view gets them. Returning true swallows the key.
    let intercept: (EditorKey) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MarkdownNSTextView {
        // A bare text view, and deliberately **not** `NSTextView.scrollableTextView()`. That factory
        // hands back an `NSScrollView`, and one of those inside the detail pane's own `ScrollView`
        // is two scrolling surfaces stacked: the trackpad has to guess which one a two-finger drag
        // meant, and the write-up scrolled independently of the page it sits on. There is one
        // scrolling surface now — the page — and this view simply grows to the height of its text.
        //
        // `NSTextView(frame:)` is TextKit 2, the same engine the factory would have configured;
        // nothing here touches `layoutManager`, which is what would downgrade it to TextKit 1.
        let textView = MarkdownNSTextView(frame: .zero)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        // The container follows the view's width, so setting the frame width in `sizeThatFits` is
        // what rewraps the text — and the height is unbounded, because the height is the answer.
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.size = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.drawsBackground = false
        // This is markdown *source*. Rich text would let a paste bring its own fonts in and let the
        // font panel apply styling the string cannot hold, and the substitutions would quietly turn
        // the quotes and dashes in somebody's notes into characters they did not type.
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = MarkdownStyle.bodyFont
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 6)
        // **A selection tints the background and does not repaint the text.** By default AppKit adds
        // `selectedTextColor` to every selected character, and that overrides the `NSColor.clear`
        // the three characters of a task item's box are drawn in — so the moment a selection
        // crossed the action list, the literal `[ ]` reappeared *on top of* the checkbox, on those
        // rows only, while the rows outside the selection still showed a control. That is the
        // rendering fault in the screenshot, and it is one attribute: the highlight, and nothing
        // that touches a glyph's colour.
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]

        textView.string = text
        // Clicking the checkbox a task item draws over its `[ ]` goes through the same edit path as
        // typing the character, so it is one ⌘Z and it provokes the autosave.
        textView.toggleTask = { [weak coordinator = context.coordinator] offset in
            coordinator?.toggleTask(at: offset)
        }
        context.coordinator.attach(textView)
        return textView
    }

    /// The height the document actually occupies at the width SwiftUI is offering — which is what
    /// makes the write-up a document that grows rather than a box with a magic number in it.
    ///
    /// Measured off `NSTextLayoutManager`, the same TextKit 2 engine the gutter and the caret rects
    /// come from, so there is one answer about where the text is rather than two. It cannot oscillate
    /// with SwiftUI's layout: the height is a pure function of the text and the proposed width, and
    /// nothing here invalidates the layout that asked.
    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: MarkdownNSTextView, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.markdownDocumentHeight(atWidth: width))
    }

    func updateNSView(_ textView: MarkdownNSTextView, context: Context) {
        context.coordinator.parent = self
        handle.coordinator = context.coordinator

        // The anchors again, after whatever this update was. They were published from the selection
        // delegate alone, which is one notification per *selection* change and none at all for a
        // layout change — so a pane that resized, a document that re-wrapped, or a selection made
        // before the text had been laid out left `selectionRect` pointing at where the text used to
        // be, or at nil, with nothing that would ever refresh it but moving the selection again.
        //
        // Next runloop turn, because writing SwiftUI state inside a view update is not allowed. It
        // cannot loop: an unchanged `CGRect` assigned to `@State` invalidates nothing.
        Task { @MainActor [coordinator = context.coordinator] in coordinator.publishRects() }

        // The guard that keeps undo alive. `text` changes on every keystroke *because the text view
        // told us it did*, and writing the whole string back for those would flatten the undo stack
        // into one indistinguishable blob every time. Only a genuinely foreign value — the CLI
        // writing the column, or the conflict banner resolving — gets through here.
        guard textView.string != text else { return }
        textView.string = text
        // The old undo entries describe a document that no longer exists. Keeping them would let
        // ⌘Z reinstate half of a version somebody else replaced.
        textView.undoManager?.removeAllActions()
        context.coordinator.adopt(textView)
    }

    /// The keys the slash menu takes before the text view sees them. `NSTextView` routes each of
    /// these through `doCommandBy`, which is a real interception point rather than a race with
    /// SwiftUI's key handling.
    enum EditorKey {
        case up, down, enter, escape
    }

    /// The floor, so an empty write-up is still a line you can click into rather than a zero-height
    /// view with nothing to aim at.
    static var emptyHeight: CGFloat { MarkdownStyle.bodyFont.boundingRectForFont.height * 1.15 + 12 }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        private(set) weak var textView: NSTextView?
        /// The document as of the last change, for diffing one keystroke out of it.
        private var last = ""
        /// True while we are writing our own follow-up, so it is not read back as a keystroke.
        private var applying = false

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            super.init()
        }

        func attach(_ textView: NSTextView) {
            self.textView = textView
            adopt(textView)
        }

        func adopt(_ textView: NSTextView) {
            last = textView.string
            restyle()
        }

        // MARK: - Text

        func textDidChange(_ notification: Notification) {
            guard !applying, let textView else { return }
            let now = textView.string
            let before = last
            last = now
            parent.text = now

            if let follow = MarkdownEditing.followUp(
                before: before, after: now, caret: characterOffset(of: textView.selectedRange().location)
            ) {
                apply(follow)
                return
            }
            restyle()
        }

        /// One place where a ``MarkdownEditing/Edit`` becomes characters, and the only place that
        /// changes text behind the user's back.
        ///
        /// Through `shouldChangeText` and `didChangeText` rather than straight into the storage, so
        /// AppKit registers it on the undo stack: continuing a list is one ⌘Z, and the keystroke
        /// that triggered it is the next.
        ///
        /// Measured on a text view in a responder chain: this pair round-trips through `undo()`
        /// exactly, and an attribute-only restyle between two of them leaves `canUndo` false — so
        /// the colours the gutter paints never land on the stack as steps of their own.
        func apply(_ edit: MarkdownEditing.Edit) {
            guard let textView, let storage = textView.textStorage else { return }
            let range = nsRange(edit.range, in: textView.string)
            guard textView.shouldChangeText(in: range, replacementString: edit.replacement) else { return }
            applying = true
            storage.replaceCharacters(in: range, with: edit.replacement)
            textView.didChangeText()
            applying = false

            let settled = textView.string
            last = settled
            parent.text = settled
            textView.setSelectedRange(nsRange(edit.selection, in: settled))
            restyle()
        }

        // MARK: - Selection

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let range = textView.selectedRange()
            let lower = characterOffset(of: range.location)
            parent.selection = lower..<(lower + characterCount(of: range))
            // **Not while the mouse is down.** `NSTextView.mouseDown` does not return until the
            // button comes up: it runs a tracking loop that maps the pointer to a character on
            // every event and extends the selection to it, and this notification is posted from
            // *inside* that loop. `restyle()` rewrites the attributes of the entire document, so
            // obeying every one of those notifications means a document-sized rewrite per mouse
            // event for the whole of a drag — and each one invalidates the layout the loop is
            // measuring against.
            //
            // This is not what made a click select a paragraph; the reveal rule in `restyle()` was,
            // and bisecting says so. It is the work that has no business happening mid-gesture, and
            // keeping it out is what stops the layout being rebuilt underneath a live drag.
            //
            // Deferred, not dropped: ``MarkdownNSTextView/mouseDown(with:)`` calls
            // ``endMouseTracking()`` the moment `super` returns, which is the moment the mouse came
            // up, so the reveal lands before the next frame either way.
            guard !isTracking else { return }
            restyle()
            publishRects()
        }

        /// True while the text view is inside its own mouse-tracking loop.
        private var isTracking: Bool {
            (textView as? MarkdownNSTextView)?.isTrackingMouse ?? false
        }

        /// The gesture is over: catch up on everything that was held back during it.
        func endMouseTracking() {
            restyle()
            publishRects()
        }

        func publishRects() {
            // Not mid-gesture. This is a read — it moves nothing — but it writes SwiftUI state, and
            // a SwiftUI update landing inside `NSTextView`'s tracking loop is a re-entrancy nobody
            // needs while a selection is being dragged. It runs again the moment the mouse comes up.
            guard let textView, !isTracking else { return }
            let range = textView.selectedRange()
            parent.caretRect = rect(for: NSRange(location: range.location, length: 0))
            parent.selectionRect = range.length > 0 ? rect(for: range) : nil
        }

        private func rect(for range: NSRange) -> CGRect? {
            textView?.markdownRect(for: range)
        }

        // MARK: - Keys the menu wants first

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let key: EditorKey? = switch selector {
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            case #selector(NSResponder.insertNewline(_:)): .enter
            case #selector(NSResponder.cancelOperation(_:)): .escape
            default: nil
            }
            guard let key else { return false }
            return parent.intercept(key)
        }

        // MARK: - Ticking a box

        /// A checkbox was clicked. It becomes the one-character edit ``MarkdownEditing`` defines and
        /// goes through ``apply(_:)`` — the same road every follow-up edit takes — so it lands on
        /// the undo stack and pushes the document up through the binding that autosaves it.
        func toggleTask(at offset: Int) {
            guard let textView,
                  let edit = MarkdownEditing.toggleTask(in: textView.string, at: offset)
            else { return }
            apply(edit)
        }

        // MARK: - Styling

        func restyle() {
            guard let textView, let storage = textView.textStorage else { return }
            storage.beginEditing()
            // Handed over as a UTF-16 offset rather than as a `String.Index`. Every bridge of the
            // storage's string is a separate `String` value, and an index taken from one of them
            // and compared against lines carved out of another is only accidentally right.
            //
            // **A caret reveals; a selection does not**, and this one line fixes two things.
            //
            // The one you can see: the reveal exists so the line you are *editing* shows the
            // characters you are editing, and a selection is not an edit. Following the selection's
            // start meant a row inside a highlight showed its raw markers while the rows either
            // side of it showed a checkbox, which reads as the rendering having failed.
            //
            // The one you could not: **this is what made a single click select a block of text.**
            // `NSTextView.mouseDown` runs until the mouse comes up, mapping the pointer to a
            // character on every event and extending the selection to it — and it passes through a
            // one-character range on the way, because the two ends of a real click round across a
            // glyph boundary differently. Recomputing the reveal from a selection that is moving
            // re-lays-out a line mid-gesture, the loop's next reading of the same screen point
            // lands on a different character, and the caret becomes a range that runs away.
            //
            // Bisected on this view at 560 pt, offscreen, with synthesised events through the real
            // tracking loop: with the reveal following the selection, a click in the last action
            // line came back `selectedRange() = {323, 22}` — twenty-two characters, to the end of
            // the document — and a double-click on `cutover` selected `the`, three words away.
            // With the reveal restricted to a collapsed caret, `{322, 1}` and `cutover`, both
            // matching a stock `NSTextView` handed the identical events. Reverting this line alone,
            // with every other change in this branch in place, brings both back.
            let selection = textView.selectedRange()
            MarkdownStyle.apply(
                to: storage, caret: selection.length == 0 ? selection.location : nil
            )
            storage.endEditing()
            // Attributes are not text, so none of the above touched the undo stack — but the caret
            // sitting just after a dimmed marker would otherwise inherit its colour and size onto
            // the next character typed.
            textView.typingAttributes = MarkdownStyle.bodyAttributes
        }

        // MARK: - Characters, not UTF-16

        func nsRange(_ characters: Range<Int>, in string: String) -> NSRange {
            let count = string.count
            let lower = string.index(string.startIndex, offsetBy: min(max(characters.lowerBound, 0), count))
            let upper = string.index(string.startIndex, offsetBy: min(max(characters.upperBound, 0), count))
            return NSRange(lower..<max(lower, upper), in: string)
        }

        private func characterOffset(of utf16: Int) -> Int {
            guard let textView,
                  let index = Range(NSRange(location: utf16, length: 0), in: textView.string)?.lowerBound
            else { return 0 }
            return textView.string.distance(from: textView.string.startIndex, to: index)
        }

        private func characterCount(of range: NSRange) -> Int {
            guard let textView, let found = Range(range, in: textView.string) else { return 0 }
            return textView.string.distance(from: found.lowerBound, to: found.upperBound)
        }
    }
}

/// `NSTextView` with one behaviour of its own: **a task list item's `[ ]` is a real checkbox**.
///
/// The characters never move. `- [ ] ship it` is still those characters at those offsets, which is
/// the rule the whole editor is built on — what changes is that the three characters of the box are
/// drawn transparent (at their own width, so nothing reflows) and a checkbox is painted over the
/// space they occupy. Clicking inside that space is a one-character edit through
/// ``MarkdownEditing/toggleTask(in:at:)``, so it is undoable and it autosaves; clicking anywhere
/// else is an ordinary click in a text view.
///
/// An attachment would have been the other way to draw it, and it is the wrong one: an attachment
/// is a character, so drawing the box that way means either inserting U+FFFC — a character the store
/// would then hold — or attaching to characters the layout engine does not expect to carry one.
final class MarkdownNSTextView: NSTextView {
    /// Handed the character offset of the box that was clicked.
    var toggleTask: ((Int) -> Void)?

    /// One task list item's box: where it is, whether it is ticked, and the offset a toggle needs.
    struct Checkbox {
        let offset: Int
        let done: Bool
        let rect: CGRect
    }

    /// The checkboxes, on a view of their own that sits over the text. See
    /// ``MarkdownCheckboxOverlay`` for why they are not painted into the background any more.
    private let overlay = MarkdownCheckboxOverlay()

    /// The overlay is fitted and marked for redraw here, at the top of every draw cycle.
    ///
    /// **`viewWillDraw()` and never `draw(_:)`.** Measured on macOS 26: overriding `draw(_:)` on an
    /// `NSTextView` silently drops it to **TextKit 1** — `textLayoutManager` comes back nil, and
    /// with it the gutter's measurements, the document height and the rects the slash menu and the
    /// toolbar hang off. This one does not touch the drawing path at all; it runs before it, and
    /// `super` then carries the same call down into the subviews, so the overlay repaints in *this*
    /// pass rather than a frame late.
    ///
    /// Every pass, because a checkbox's position is a fact about the *layout* and the layout moves
    /// for reasons no notification covers — a rewrap when the pane narrows, a heading that grew, a
    /// line that wrapped. Repainting it costs three small rounded rectangles.
    override func viewWillDraw() {
        if overlay.superview !== self { addSubview(overlay) }
        if overlay.frame != bounds { overlay.frame = bounds }
        overlay.needsDisplay = true
        super.viewWillDraw()
    }

    /// True from the moment `mouseDown` hands over to `NSTextView` until the mouse comes up.
    ///
    /// `NSTextView.mouseDown` is not a notification that a button went down — it is the whole
    /// gesture, and it does not return until the button comes up again. Anything that changes the
    /// document's attributes while this is true is changing the layout out from under a loop that
    /// is mapping screen points onto characters, which is how a click becomes a range selection.
    private(set) var isTrackingMouse = false

    /// A click inside a box ticks it and goes no further — the text view never sees it, so it does
    /// not also start a selection drag from inside the marker. Nothing has begun tracking on this
    /// path: `super` is what starts the tracking loop, and it is never reached.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Slop, because a checkbox is a small target and the three characters it is drawn over are
        // about twenty points wide. Not so much that clicking the word ticks it.
        if let hit = checkboxes().first(where: { $0.rect.insetBy(dx: -2, dy: -1).contains(point) }) {
            // The one thing `super` would have done that ticking still needs: focus. Without it a
            // box ticked in a write-up nobody had clicked into yet would be a change ⌘Z could not
            // reach, because the undo manager it landed on is this view's.
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
            toggleTask?(hit.offset)
            return
        }
        isTrackingMouse = true
        // Returns when the mouse comes up, having run the whole selection gesture in between.
        super.mouseDown(with: event)
        isTrackingMouse = false
        (delegate as? MarkdownTextView.Coordinator)?.endMouseTracking()
    }

    /// ponytail: the whole document is walked per draw and per click. That is the same order of work
    /// ``MarkdownStyle/apply(to:caret:)`` already does on every keystroke, and it is bounded by the
    /// editor's 200 KB guard; past that both want restricting to the laid-out viewport.
    func checkboxes() -> [Checkbox] {
        let text = string
        var found: [Checkbox] = []
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { offset += line.count + 1 }
            guard let item = MarkdownSyntax.taskItem(line) else { continue }
            let lower = text.index(line.startIndex, offsetBy: item.box.lowerBound)
            let upper = text.index(line.startIndex, offsetBy: item.box.upperBound)
            guard let rect = markdownRect(for: NSRange(lower..<upper, in: text)) else { continue }
            found.append(
                Checkbox(offset: offset + item.box.lowerBound, done: item.done, rect: rect)
            )
        }
        return found
    }
}

extension NSTextView {
    /// Where a UTF-16 range sits on screen, in this view's own coordinates.
    ///
    /// TextKit 2 throughout — `NSTextLayoutManager`, not the legacy `NSLayoutManager` path, which on
    /// macOS 26 would force the text view back onto the compatibility engine.
    ///
    /// This view's own coordinates and not the scroll view's: there is no scroll view between the
    /// text and the representable any more, and converting into `enclosingScrollView` would now find
    /// the *page's* scroll view several levels up and hang the slash menu off the wrong origin.
    @MainActor func markdownRect(for range: NSRange) -> CGRect? {
        guard let layout = textLayoutManager,
              let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        // Layout is lazy, and a segment nobody has laid out yet has no frame to report.
        layout.ensureLayout(for: textRange)

        var union: CGRect?
        layout.enumerateTextSegments(
            in: textRange, type: range.length == 0 ? .standard : .selection
        ) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        guard var found = union else { return nil }
        found.origin.x += textContainerOrigin.x
        found.origin.y += textContainerOrigin.y
        return found
    }

    /// How tall this document is when laid out `width` points wide.
    ///
    /// Measured, not guessed: `usageBoundsForTextContainer` is what TextKit 2 actually filled, so it
    /// grows as lines are typed, shrinks as they are deleted, and gets taller when the pane narrows
    /// and the prose rewraps. Measured on this engine at a 520 pt measure: an empty document is 28 pt,
    /// ten lines are 172 pt and forty are 652 pt; the same forty-line document is 236 pt at 520 pt
    /// wide and 492 pt at 260 pt wide.
    ///
    /// Setting the frame width is what rewraps it — the container tracks the view — and it is the
    /// only side effect, on a view SwiftUI is about to set the frame of anyway.
    @MainActor func markdownDocumentHeight(atWidth width: CGFloat) -> CGFloat {
        guard let layout = textLayoutManager else { return MarkdownTextView.emptyHeight }
        if frame.width != width {
            setFrameSize(NSSize(width: width, height: frame.height))
        }
        // Layout is lazy, and un-laid-out text has no bounds to report.
        layout.ensureLayout(for: layout.documentRange)
        let used = layout.usageBoundsForTextContainer.height + textContainerInset.height * 2
        return max(ceil(used), MarkdownTextView.emptyHeight)
    }
}

/// The parent's way of changing the text without owning the text view. One object rather than a
/// pending-edit binding, because an edit is a command and not a piece of state.
@MainActor final class MarkdownEditorHandle {
    fileprivate weak var coordinator: MarkdownTextView.Coordinator?

    func apply(_ edit: MarkdownEditing.Edit) { coordinator?.apply(edit) }
}

/// Which font each of ``MarkdownSyntax``'s answers is drawn in, and where the gutter puts its
/// markers. The split is deliberate: what counts as a heading is logic and lives in MeetingsCore
/// with tests behind it, and this is the half that is a typeface.
///
/// **The gutter is a paragraph style.** `firstLineHeadIndent` places the marker so that it *ends*
/// on the body edge, and `headIndent` puts every wrapped continuation line on that same edge. A
/// line with no marker gets `firstLineHeadIndent` equal to the body edge too, which is what makes
/// prose and list items share one left edge — the whole point of the design, and the one thing a
/// character-level attribute could never do.
///
/// Measured off a laid-out `NSTextLayoutManager` at a six-column gutter: `## Decisions`, a plain
/// paragraph, `- ship it` and `- [ ] task` all put their first prose character at x = 45.8, while
/// their markers begin at 25.4, 45.8, 32.2 and 5.0 respectively — each one ending on the body edge.
/// The wrapped second line of the plain paragraph also lands at 45.8 rather than at 0.
///
/// **Nothing is ever removed from the string.** The markers are all still there, still selectable,
/// still what the store holds. Block markers are dimmed in the gutter; inline markers are drawn at a
/// hair size and fully transparent, which is hiding them without a second text model to keep in step.
/// The caret's line brings its inline markers back at full size, so the line it is on does reflow —
/// that is the trade the design takes, and it is confined to the one line you are editing.
@MainActor enum MarkdownStyle {
    static let bodyFont = NSFont.preferredFont(forTextStyle: .body)

    /// Markers are monospaced so the gutter can be measured in columns rather than re-measured for
    /// every line, and small so they read as scaffolding rather than as text.
    static let markerFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// Six columns: exactly `- [ ] `, the widest marker anybody actually types. **Fixed, not
    /// per-document.** A gutter sized to the widest marker present would move every line in the
    /// document sideways the moment somebody typed the first action into it, which is a jump under
    /// the cursor for a change made three paragraphs away.
    static let gutterColumns = 6

    /// A monospaced font's advance, measured once. `- [ ] ` is six of these wide by construction.
    static let column = NSAttributedString(string: "0", attributes: [.font: markerFont]).size().width

    /// What an inline marker is drawn in when the caret is not on its line: small enough to take no
    /// visible width, and never zero — `NSFont.systemFont(ofSize: 0)` means *the default size*, which
    /// would draw the markers at full size and look like the hiding had simply failed.
    static let hiddenFont = NSFont.systemFont(ofSize: 0.01)

    static var gutter: CGFloat { column * CGFloat(gutterColumns) }

    static var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle(for: "")]
    }

    /// ponytail: the whole document restyles on every keystroke. That is fine up to the oversize
    /// guard's 200 KB — past a few thousand lines this wants restricting to the paragraphs the
    /// change touched, which is a range diff rather than a rewrite.
    static func apply(to storage: NSTextStorage, caret utf16: Int?) {
        let text = storage.string
        let whole = NSRange(location: 0, length: (text as NSString).length)
        // Resolved against *this* string value, so it is comparable with the lines carved out of it
        // below. An emoji makes the UTF-16 offset and the character offset disagree, and this is
        // the one conversion that reconciles them.
        let caret = utf16
            .flatMap { Range(NSRange(location: min($0, whole.length), length: 0), in: text) }?
            .lowerBound
        // Everything back to prose first, so a line that *stops* being a heading — the `#` deleted —
        // goes back down instead of keeping the size it was given a keystroke ago.
        storage.setAttributes(bodyAttributes, range: whole)

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let revealed = caret.map { line.startIndex <= $0 && $0 <= line.endIndex } ?? false
            storage.addAttribute(
                .paragraphStyle, value: paragraphStyle(for: line),
                range: NSRange(line.startIndex..<line.endIndex, in: text)
            )
            guard !line.isEmpty else { continue }

            /// A character range inside the line, as the UTF-16 range the storage wants. Doing this
            /// conversion once, here, is what keeps an emoji from shifting every offset after it.
            func range(_ span: Range<Int>) -> NSRange {
                let lower = text.index(line.startIndex, offsetBy: span.lowerBound)
                let upper = text.index(line.startIndex, offsetBy: span.upperBound)
                return NSRange(lower..<upper, in: text)
            }

            let kind = MarkdownSyntax.line(line)
            let lineRange = NSRange(line.startIndex..<line.endIndex, in: text)
            storage.addAttribute(.font, value: font(for: kind), range: lineRange)
            if kind == .quote {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
            }

            // Runs first, in the order MarkdownSyntax hands them over: a nested run reads the font
            // its parent just set and adds to it, which is how `***both***` ends up both.
            for span in MarkdownSyntax.inline(line) {
                let at = range(span.range)
                guard at.length > 0 else { continue }
                let current = storage.attribute(.font, at: at.location, effectiveRange: nil) as? NSFont
                    ?? font(for: kind)
                switch span.style {
                case .strong: storage.addAttribute(.font, value: adding(.boldFontMask, to: current), range: at)
                case .emphasis: storage.addAttribute(.font, value: adding(.italicFontMask, to: current), range: at)
                case .code:
                    storage.addAttribute(
                        .font,
                        value: NSFont.monospacedSystemFont(ofSize: current.pointSize * 0.95, weight: .regular),
                        range: at
                    )
                case .strike:
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: at)
                case .link:
                    storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: at)
                }
            }

            // Then the markers over the top, and the two kinds are treated differently.
            //
            // **Block markers stay visible and dim in the gutter.** That is the whole idea: you can
            // still see that a line is a heading, and the marker never interrupts the reading edge
            // because it is not on it.
            //
            // **Inline markers are hidden, not dimmed** — bold text simply looks bold. Dimmed `**`
            // still occupies its two characters of space, so a document was still visibly full of
            // punctuation. Hidden here means drawn at 0.01 pt and fully transparent: the characters
            // are all still in the string, still selectable, still what the store holds, and the
            // drawn line is within 0.01 pt per marker of the width it would have if they had been
            // deleted (measured: `make it **bold** now` draws 102.38 pt hidden against 102.36 pt
            // with the four characters actually removed, and 126.58 pt when merely coloured clear).
            //
            // The caret's line reveals them at full size, so editing is honest — and the caret can
            // therefore never sit inside a hair-sized run, because a line with the caret on it is
            // never hidden.
            let marker: NSColor = revealed ? .labelColor : .tertiaryLabelColor
            let blockEnd = MarkdownSyntax.blockMarker(line)?.upperBound ?? 0
            for span in MarkdownSyntax.markers(line) {
                // `markers` merges ranges that touch, so `- **bold**` hands over one span covering
                // the bullet and the opening `**`. The gutter ends at `blockEnd`, and the split is
                // there.
                if span.lowerBound < blockEnd {
                    storage.addAttribute(
                        .foregroundColor, value: marker,
                        range: range(span.lowerBound..<min(span.upperBound, blockEnd))
                    )
                }
                guard span.upperBound > blockEnd else { continue }
                let inline = range(max(span.lowerBound, blockEnd)..<span.upperBound)
                if revealed {
                    storage.addAttribute(.foregroundColor, value: marker, range: inline)
                } else {
                    storage.addAttribute(.font, value: hiddenFont, range: inline)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: inline)
                }
            }
            // The block marker and the indentation in front of it are the gutter, and the gutter is
            // monospaced — the indent arithmetic above is in columns, and it only holds if what
            // sits in those columns is a column wide.
            if let block = MarkdownSyntax.blockMarker(line) {
                storage.addAttribute(.font, value: markerFont, range: range(0..<block.upperBound))
            }

            // A task list item's box is drawn as a checkbox rather than as `[ ]`.
            //
            // The three characters stay exactly where they are, at exactly the width they had —
            // only their colour goes, so the space they occupy is the space the checkbox is painted
            // into and no offset in the document moves. Unlike an inline marker, this does *not*
            // come back on the caret's line: a control that appears and disappears as the caret
            // passes is not a control.
            guard let task = MarkdownSyntax.taskItem(line) else { continue }
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range(task.box))
            // Ticked reads as done, the same treatment the checklist gave it.
            guard task.done, task.textStart < line.count else { continue }
            let body = range(task.textStart..<line.count)
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: body)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: body)
        }
    }

    /// The system checkbox — the control itself, asked to draw, rather than a picture of one.
    ///
    /// This was an SF Symbol (`square` / `checkmark.square.fill`) and it read as what it was: a
    /// glyph. A symbol square is a font character with a stroke weight that follows the text, no
    /// fill, no inner shadow and no accent colour of its own, so next to real prose it looked
    /// drawn rather than clickable — and the ticked state was an accent-coloured *letter* rather
    /// than the filled, checked control macOS puts everywhere else.
    ///
    /// `NSButtonCell` set to `.switch` **is** the checkbox: it is the cell
    /// `NSButton(checkboxWithTitle:target:action:)` is built out of, and `draw(withFrame:in:)` asks
    /// AppKit to render it exactly as it renders one in a dialog. Every one of the things that
    /// makes it look native therefore comes from the system and not from here — the control shape
    /// and its corner radius, the border and inner shadow of the empty box, the user's accent
    /// colour when ticked, the check glyph, and light and dark mode, which arrives via the
    /// `NSAppearance` that is already current on the view being drawn into.
    ///
    /// It carries no accessibility label of its own, and it should not: the `[ ]` characters are
    /// still in the string at their own offsets, so VoiceOver reads `- [x] book the war room` off
    /// the text the way it reads every other line. A second label would be a second answer.
    ///
    /// **A cell rather than an `NSTextAttachment` hosting a real `NSButton`.** An attachment is a
    /// *character*: drawing the box that way means either inserting U+FFFC into the document — a
    /// character the store would then hold and the CLI would write into somebody's markdown file —
    /// or hanging an attachment on characters the layout engine does not expect to carry one. Both
    /// break the rule the whole editor rests on, which is that the drawn document and the stored
    /// string have the same characters at the same offsets. A cell is not in the text model at
    /// all. It draws, and that is the entire extent of its involvement.
    ///
    /// One cell, reused for every box, because a cell carries no state between draws beyond the
    /// `state` set here — the same reason AppKit's own table views draw a column with one.
    private static let checkboxCell: NSButtonCell = {
        let cell = NSButtonCell()
        cell.setButtonType(.switch)
        cell.title = ""
        cell.imagePosition = .imageOnly
        // The control size whose box is closest to the text it sits beside: measured against
        // `bodyFont` at the system default of 13 pt, `.small` draws a 12 pt box against a 13 pt
        // cap-and-ascender run, which is the proportion a checkbox has next to its own label in a
        // dialog. `.regular`'s 14 pt box next to 13 pt prose reads a size too big.
        cell.controlSize = bodyFont.pointSize >= 15 ? .regular : .small
        return cell
    }()

    /// Painted over the space the `[ ]` characters hold, sitting on the text's baseline.
    ///
    /// The cell is drawn at its own `cellSize` and never scaled: a control stretched to fill a
    /// glyph box is a blurred control, and the system draws these at fixed sizes for a reason.
    static func drawCheckbox(done: Bool, over rect: CGRect, in view: NSView) {
        let cell = checkboxCell
        cell.state = done ? .on : .off
        let size = cell.cellSize
        guard size.width > 0, size.height > 0, rect.width > 0 else { return }
        // Left-aligned in the space the three characters occupy rather than centred in it: the box
        // then lines up with the `-` of a plain bullet on the line above, which is what makes the
        // gutter read as one column instead of two.
        //
        // Vertically it is centred between the baseline and the cap height — where the eye puts
        // the middle of a line of text — and not on the middle of the line fragment, which sits
        // low because the fragment carries the descender and the 1.15 line height underneath.
        //
        // The fragment is taller than the type by its leading, and the baseline is that much above
        // the fragment's bottom, less the descender's own depth. `descender` is negative, so adding
        // it moves up.
        let leading = max(rect.height - (bodyFont.ascender - bodyFont.descender), 0)
        let baseline = rect.maxY - leading / 2 + bodyFont.descender
        let middle = baseline - bodyFont.capHeight / 2
        cell.draw(
            withFrame: CGRect(
                x: rect.minX, y: middle - size.height / 2, width: size.width, height: size.height
            ),
            in: view
        )
    }

    static func paragraphStyle(for line: some StringProtocol) -> NSParagraphStyle {
        let indent = MarkdownSyntax.gutterIndent(line, gutter: gutterColumns)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = CGFloat(indent.first) * column
        style.headIndent = CGFloat(indent.body) * column
        style.lineHeightMultiple = 1.15
        return style
    }

    static func font(for line: MarkdownSyntax.Line) -> NSFont {
        switch line {
        case .heading(let level): headingFont(level)
        case .bullet, .quote, .body: bodyFont
        }
    }

    /// `##` is what an agent writes far more often than `#`, so it has to be a heading you can see —
    /// the same sizing ``MarkdownText`` renders a finished document at, so the write-up does not
    /// change shape between the editor and the exported markdown.
    static func headingFont(_ level: Int) -> NSFont {
        let style: NSFont.TextStyle = switch level {
        case ...1: .title2
        case 2: .title3
        default: .headline
        }
        return .systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: .semibold)
    }

    private static func adding(_ trait: NSFontTraitMask, to font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: trait)
    }
}
