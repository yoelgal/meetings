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

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

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
        context.coordinator.attach(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        handle.coordinator = context.coordinator

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
            // The reveal follows the caret, so the document restyles when it moves. This is a pure
            // colour change — the gutter is a paragraph property and does not move with the caret,
            // which is why the line no longer reflows as the caret enters it.
            restyle()
            publishRects()
        }

        private func publishRects() {
            guard let textView else { return }
            let range = textView.selectedRange()
            parent.caretRect = rect(for: NSRange(location: range.location, length: 0))
            parent.selectionRect = range.length > 0 ? rect(for: range) : nil
        }

        /// TextKit 2 throughout — `NSTextLayoutManager`, not the legacy `NSLayoutManager` path,
        /// which on macOS 26 would force the text view back onto the compatibility engine.
        private func rect(for range: NSRange) -> CGRect? {
            guard let textView,
                  let layout = textView.textLayoutManager,
                  let content = layout.textContentManager,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end),
                  let scroll = textView.enclosingScrollView
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
            found.origin.x += textView.textContainerOrigin.x
            found.origin.y += textView.textContainerOrigin.y
            return textView.convert(found, to: scroll)
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
/// still what the store holds; they are dimmed, not hidden. Revealing the caret's line is therefore
/// a pure colour change, and the line does not reflow as the caret arrives.
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

            // Then the markers over the top. Colour only — the block marker is already in the
            // gutter font and stays there, so revealing a line changes nothing about its layout.
            let marker: NSColor = revealed ? .labelColor : .tertiaryLabelColor
            for span in MarkdownSyntax.markers(line) {
                storage.addAttribute(.foregroundColor, value: marker, range: range(span))
            }
            // The block marker and the indentation in front of it are the gutter, and the gutter is
            // monospaced — the indent arithmetic above is in columns, and it only holds if what
            // sits in those columns is a column wide.
            if let block = MarkdownSyntax.blockMarker(line) {
                storage.addAttribute(.font, value: markerFont, range: range(0..<block.upperBound))
            }
        }
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
