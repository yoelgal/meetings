import Foundation
import Testing

@testable import MeetingsApp

/// The write-up's reading measure, asserted as the number it is.
///
/// `AppSourceGuardTests` used to pin this by looking for the string
/// `static var column: CGFloat { 40 * MarkdownStyle.bodyFont.pointSize }` in `PreNotesEditor.swift`.
/// That check fails on a line wrap and passes on `30 * MarkdownStyle.bodyFont.pointSize` reformatted
/// to the same shape — it was pinning the source, not the measure. This target links the app, so the
/// property is reachable and the measure can be asserted directly.
///
/// **No window, no view.** These are static values on a type.
@Suite @MainActor struct SharedFieldMeasureTests {
    /// 40rem of the app's own body text, so the measure tracks the system text size instead of being
    /// right at exactly one of them. At the default 13 pt body that is 520 pt, about 87 characters.
    @Test func theColumnIsFortyRemOfTheAppsOwnBodyText() {
        #expect(SharedFieldEditor.column == 40 * MarkdownStyle.bodyFont.pointSize)
        #expect(MarkdownStyle.bodyFont.pointSize > 0, "…and the rem has to be a real font size")
        // The wide-pane defect this exists for: the full detail column was 656 pt, about 110
        // characters, which is why the surface read as a text field rather than as a document.
        #expect(SharedFieldEditor.column < 600, "the measure is a reading column, not the pane's width")
    }
}
