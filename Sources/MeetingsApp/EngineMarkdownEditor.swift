import AppKit
import MarkdownEngine
import MeetingsCore
import SwiftUI

/// The same write-up, drawn by `nodes-app/swift-markdown-engine` instead of by ``MarkdownTextView``.
///
/// **A spike, mounted behind `MEETINGS_EDITOR=engine`.** It exists so the hand-built editor and the
/// library can be photographed side by side from one build; nothing reaches it unless the variable
/// is set, and the default is the shipping path.
///
/// What is deliberately *not* different: the value in and out is the same `String` the CLI writes,
/// handed over through the same binding ``SharedFieldEditor`` gives the native editor. Autosave, the
/// two-writer conflict banner and the oversize guard sit above this view and never learn which
/// engine is underneath — that is the whole point of putting the seam here rather than lower.
struct EngineMarkdownEditor: View {
    @Binding var text: String
    /// The engine keys its per-document state (scroll offset, undo, wiki-link metadata) off this, so
    /// it is handed ``SharedFieldEditor/identity`` — the same string that resets the native editor
    /// when the field or the meeting changes.
    let documentId: String

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: Self.configuration,
            fontName: MarkdownStyle.bodyFont.fontName,
            fontSize: MarkdownStyle.bodyFont.pointSize,
            documentId: documentId
        )
    }

    /// Themed to this app's tokens rather than left on the library's defaults, so a screenshot
    /// comparison is about the two editors and not about one of them being unstyled.
    ///
    /// The colours are the ones ``MarkdownStyle`` already paints with: `labelColor` for prose,
    /// `tertiaryLabelColor` for markers — the engine calls it `disabledText` — and
    /// `controlAccentColor` for links, which is what the native editor's `.link` span uses.
    /// `headingMarker` gets `tertiaryLabelColor` too: the library's default is a flat `.gray`, which
    /// does not track light and dark.
    static let theme = MarkdownEditorTheme(
        bodyText: .labelColor,
        mutedText: .secondaryLabelColor,
        disabledText: .tertiaryLabelColor,
        headingMarker: .tertiaryLabelColor,
        link: .controlAccentColor,
        incompleteLink: .secondaryLabelColor,
        findMatchHighlight: .findHighlightColor,
        findCurrentMatchHighlight: .selectedTextBackgroundColor,
        strikethroughColor: .secondaryLabelColor
    )

    /// `.fitsContent` is not a preference here, it is the contract: every home of this editor —
    /// the detail pane and the floating notes panel — is already inside a `ScrollView`, and an
    /// editor that scrolls internally puts two scrolling surfaces under one trackpad gesture.
    /// `.scrolls` is the library's default, so leaving it alone would reintroduce exactly the
    /// defect ``MarkdownTextView`` was rebuilt to remove.
    ///
    /// The scrollers are hidden for the same reason, and the text insets match the native editor's
    /// `textContainerInset` so the first baseline lands in the same place in both.
    ///
    /// `readingWidth` stays nil: the measure is ``SharedFieldEditor/column``, applied by the frame
    /// outside this view, and letting the engine centre a column of its own inside that frame would
    /// be two answers to one question.
    static let configuration = MarkdownEditorConfiguration(
        theme: theme,
        scrollers: .hidden,
        textInsets: TextInsets(horizontal: 0, vertical: 6),
        heightBehavior: .fitsContent
    )
}
