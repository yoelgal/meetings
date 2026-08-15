import Foundation
import MeetingsCore
import Testing

@testable import MeetingsApp

/// The two invariants of the bridge onto `swift-markdown-engine` that are cheap to check and
/// expensive to lose.
///
/// **No window, no text view, no `NSApplication`.** Everything below is the configuration this app
/// hands the library, which is a value. Driving the editor itself needs a laid-out `NSTextView` in a
/// window, and this package does not open one under `swift test` — the last harness that did
/// appeared on the operator's screen while he was working.
@Suite struct MarkdownEditorBridgeTests {

    /// Every mounted editor gets its **own** notification names.
    ///
    /// The engine subscribes to the bus with `object: nil`, so a name shared between two editors is
    /// a request delivered to both. Two of them are on screen together whenever the floating notes
    /// panel is open over a written-up meeting, and with one shared name ⌘B in the panel would also
    /// embolden the write-up behind it.
    @MainActor @Test func twoEditorsNeverShareABusName() {
        let one = MarkdownEditorBridge()
        let two = MarkdownEditorBridge()
        let names = { (bridge: MarkdownEditorBridge) -> [Notification.Name?] in
            let bus = bridge.configuration.services.bus
            return [
                bus.applyBoldRequest, bus.applyItalicRequest, bus.applyHeadingRequest,
                bus.applyStrikethroughRequest, bus.applyInlineCodeRequest,
                bus.applyBlockquoteRequest, bus.applyUnorderedListRequest,
                bus.applyOrderedListRequest, bus.applyLinkRequest, bus.applyCodeBlockRequest,
                bus.applyHorizontalRuleRequest, bus.selectionBoldDidChange,
                bus.selectionItalicDidChange,
            ]
        }
        let first = names(one)
        #expect(!first.contains(nil), "every action the chrome offers has to have a name to post on")
        #expect(Set(first.compactMap { $0 }).count == first.count, "and no two verbs may share one")
        #expect(Set(first.compactMap { $0 }).isDisjoint(with: Set(names(two).compactMap { $0 })), """
            Two editors are sharing a bus name. The engine subscribes with `object: nil`, so a \
            format request meant for the notes panel would be applied to the write-up as well.
            """)
    }

    /// The editor grows to its document instead of scrolling inside the page that carries it.
    ///
    /// `.scrolls` is the library's default, and taking it would put a second scrolling surface under
    /// one trackpad gesture in all three homes of this editor — which is the defect the write-up was
    /// rebuilt to remove, not a preference.
    @MainActor @Test func theEditorIsTheHeightOfItsDocument() {
        let configuration = MarkdownEditorBridge().configuration
        #expect(configuration.heightBehavior == .fitsContent)
        #expect(configuration.readingWidth == nil, """
            The measure is SharedFieldEditor.column, applied by the frame outside the editor. A \
            reading column inside that frame is two answers to one question.
            """)
        #expect(configuration.scrollers.hasVerticalScroller == false)
    }

    /// Every row the menu draws can be applied. A command with no route to the engine is a menu item
    /// that does nothing, and the menu is the one surface where that is invisible until it is used.
    @Test func everySlashCommandNamesAnActionASymbolAndAShorthand() {
        for command in MarkdownEditing.slashCommands {
            #expect(!command.symbol.isEmpty, "\(command.id) has no symbol")
            #expect(command.shorthand == "/\(command.id)")
        }
        #expect(MarkdownEditing.slashCommands.contains { $0.action == .taskList }, """
            The action box is the one construct this app's CLI reads back out of the write-up. It \
            has no verb on the engine's bus, which is exactly why it must stay in the catalogue.
            """)
    }
}
