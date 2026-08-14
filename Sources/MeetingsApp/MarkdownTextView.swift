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
            // The reveal follows the caret, so the document restyles when it moves. The gutter is a
            // paragraph property and does not move with the caret, so the document's left edge never
            // shifts; only the caret's own line changes width, as its inline markers come back.
            restyle()
            publishRects()
        }

        func publishRects() {
            guard let textView else { return }
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
            MarkdownStyle.apply(to: storage, caret: textView.selectedRange().location)
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

    /// **`drawBackground(in:)` and never `draw(_:)`.** Measured on macOS 26: overriding `draw(_:)`
    /// on an `NSTextView` silently drops it to **TextKit 1** — `textLayoutManager` comes back nil,
    /// and with it the gutter's measurements, the document height and the rects the slash menu and
    /// the toolbar hang off. Overriding this one does not; the text view stays on TextKit 2.
    ///
    /// It paints under the glyphs, which is exactly right here: the three characters of the box are
    /// transparent, so the checkbox shows through the space they hold. A selection dragged across it
    /// tints over the checkbox, the same way it tints over a word.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        for box in checkboxes() where box.rect.intersects(rect) {
            MarkdownStyle.drawCheckbox(done: box.done, in: box.rect)
        }
    }

    /// A click inside a box ticks it and goes no further — the text view never sees it, so it does
    /// not also start a selection drag from inside the marker.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Slop, because a checkbox is a small target and the three characters it is drawn over are
        // about twenty points wide. Not so much that clicking the word ticks it.
        if let hit = checkboxes().first(where: { $0.rect.insetBy(dx: -2, dy: -1).contains(point) }) {
            toggleTask?(hit.offset)
            return
        }
        super.mouseDown(with: event)
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

    /// The checkbox itself: SF Symbols, drawn into the space the `[ ]` characters occupy.
    static func drawCheckbox(done: Bool, in rect: CGRect) {
        let side = min(rect.height, rect.width) - 1
        guard side > 4 else { return }
        let box = CGRect(
            x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side
        )
        // An empty box has to be *visible*, which `tertiaryLabelColor` on a thin `square` outline is
        // not — rendered at 17 pt it is a light grey hairline on a white page and reads as nothing
        // at all, which is the same failure as the checklist that could not be ticked.
        let colour = done ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        NSImage(
            systemSymbolName: done ? "checkmark.square.fill" : "square",
            accessibilityDescription: done ? "Done" : "Not done"
        )?
        .withSymbolConfiguration(configuration)?
        .draw(in: box)
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
