import AppKit

/// The task items' checkboxes, painted **above** the text rather than underneath it.
///
/// They started in ``MarkdownNSTextView/drawBackground(in:)``, which is the only drawing hook an
/// `NSTextView` can safely override — overriding `draw(_:)` drops the whole view to TextKit 1 on
/// macOS 26, taking the gutter, the document height and every anchor with it. But a background is
/// under everything, *including the selection highlight*, and the highlight is opaque: measured
/// offscreen at 560 pt, a selection dragged across the action list erased every checkbox it
/// covered — the accent-coloured ticked one included — so the rows inside a selection showed a
/// blank gap where the neighbouring rows showed a control. That is what made a perfectly ordinary
/// selection look like the rendering had failed.
///
/// A subview draws after its superview's content and after the text, so the control survives being
/// selected the way a real checkbox in a real window does. It is a plain `NSView`, so overriding
/// `draw(_:)` here costs nothing: there is no text layout on this view to downgrade.
///
/// It is invisible to the mouse. ``hitTest(_:)`` returns nil for every point, so a click lands on
/// the text view exactly as it did before this view existed and
/// ``MarkdownNSTextView/mouseDown(with:)`` still decides whether it hit a box.
final class MarkdownCheckboxOverlay: NSView {
    /// The same coordinate space the text view measures its checkbox rects in — top-down. Without
    /// this the boxes would be drawn mirrored about the middle of the document.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = superview as? MarkdownNSTextView else { return }
        for box in textView.checkboxes() where box.rect.intersects(dirtyRect) {
            MarkdownStyle.drawCheckbox(done: box.done, over: box.rect, in: self)
        }
    }
}
