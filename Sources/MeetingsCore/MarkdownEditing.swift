import Foundation

/// What the editor's *chrome* offers — the catalogue behind the slash menu and the selection
/// toolbar, and where a floating surface goes.
///
/// **The typing rules are not here any more.** List continuation, the `[] ` shorthand, marker
/// backspace, inline toggling and the block transforms all moved into `swift-markdown-engine`, which
/// owns the text view and applies them against the storage it is already holding. What is left is
/// the half the engine ships nothing for: which commands the menu lists, and the arithmetic that
/// keeps a floating surface inside the editor.
///
/// It stays in `MeetingsCore` rather than in the app for the reason it always did — `MeetingsApp` is
/// an executable target with no tests behind it, and "the menu never opens mid-word" and "the
/// toolbar is never drawn outside the column" are decisions, not layout.
public enum MarkdownEditing {
    // MARK: - Where a floating surface goes

    /// Where the toolbar over a selection — or the menu under the caret — is drawn, in the editor's
    /// own coordinates.
    public struct Placement: Equatable, Sendable {
        public let x: CGFloat
        public let y: CGFloat
        /// True when there was no room above the anchor and it went underneath instead.
        public let below: Bool

        public init(x: CGFloat, y: CGFloat, below: Bool) {
            self.x = x
            self.y = y
            self.below = below
        }
    }

    /// Centred over `anchor`, above it when there is room and below it when there is not, and
    /// **never outside the editor**.
    ///
    /// The clamp is the part that was missing, and it is not a nicety. The toolbar is about 280 pt
    /// wide and it was centred on the selection with nothing bounding the result, so a selection
    /// that starts at the left edge of the text — which is where a drag usually starts — put its
    /// origin at roughly −95, outside the document column and past the left edge of the split
    /// view's detail pane. An `NSSplitView` pane clips, so those points were not merely off the
    /// measure, they were not drawn.
    ///
    /// `width` is the **editor's own laid-out width**, never a constant: the floating notes panel
    /// lays this editor out at about 296 pt while the detail pane gives it 520, and a menu clamped
    /// against the wider number runs 224 pt outside the panel's clip.
    ///
    /// It is a pure function over four numbers so that it can be tested, which is the whole reason
    /// it is here rather than inline in an `alignmentGuide` closure where nothing could reach it.
    /// A zero-height or zero-width anchor is still a position — a caret has no width, and a surface
    /// that refused to place itself over one would be a menu that never opened.
    public static func floating(
        over anchor: CGRect, size: CGSize, in width: CGFloat, gap: CGFloat = 6
    ) -> Placement {
        let centred = anchor.midX - size.width / 2
        // `max(…, 0)` on the upper bound as well, because an editor narrower than the surface has
        // no valid range at all and `min(x, negative)` would push it off the *left* instead.
        let x = min(max(centred, 0), max(width - size.width, 0))
        let above = anchor.minY - size.height - gap
        guard above >= 0 else {
            return Placement(x: x, y: anchor.maxY + gap, below: true)
        }
        return Placement(x: x, y: above, below: false)
    }

    // MARK: - What a command asks the editor for

    /// One formatting request, in the vocabulary the *editor* understands rather than in markdown
    /// characters.
    ///
    /// It used to be a string to splice in (`"## "`) and a rule for what it replaced. It is a verb
    /// now because the thing applying it is the engine, through its `MarkdownEditorBus`: the app
    /// turns each case into the notification name the engine is listening on, and the engine decides
    /// what Heading 2 does to the line the caret is on. Naming the verb here rather than the
    /// notification keeps `MeetingsCore` free of the editor library — the CLI links this module.
    public enum Action: Hashable, Sendable {
        case bold
        case italic
        case strikethrough
        case inlineCode
        case link
        case heading(Int)
        case bulletList
        case orderedList
        /// `- [ ] `. The one command with no verb on the bus — see the app's `MarkdownEditorBridge`,
        /// which asks for a bullet and then types the box.
        case taskList
        case blockquote
        case codeBlock
        case horizontalRule
    }

    // MARK: - The slash menu

    /// One item of the menu `/` opens.
    public struct SlashCommand: Equatable, Sendable, Identifiable {
        public let id: String
        public let group: String
        public let title: String
        public let symbol: String
        public let action: Action

        public init(id: String, group: String, title: String, symbol: String, action: Action) {
            self.id = id
            self.group = group
            self.title = title
            self.symbol = symbol
            self.action = action
        }

        public var shorthand: String { "/\(id)" }
    }

    /// The menu, in the order it is drawn. Block-level only: a slash command fires at a caret with
    /// nothing selected, so bold would have nothing to embolden — inline formatting is the
    /// keyboard shortcuts, the selection toolbar and the as-you-type styling, and it is not here.
    ///
    /// Every symbol name below is one that resolves on macOS 26. A name that does not exist draws a
    /// blank box, and the menu is the one surface where that is invisible until somebody opens it.
    public static let slashCommands: [SlashCommand] = [
        .init(id: "h1", group: "Headings", title: "Heading 1",
              symbol: "textformat.size.larger", action: .heading(1)),
        .init(id: "h2", group: "Headings", title: "Heading 2",
              symbol: "textformat.size", action: .heading(2)),
        .init(id: "h3", group: "Headings", title: "Heading 3",
              symbol: "textformat.size.smaller", action: .heading(3)),
        .init(id: "bullet", group: "Lists", title: "Bulleted list",
              symbol: "list.bullet", action: .bulletList),
        .init(id: "number", group: "Lists", title: "Numbered list",
              symbol: "list.number", action: .orderedList),
        .init(id: "todo", group: "Lists", title: "Action",
              symbol: "checklist", action: .taskList),
        .init(id: "quote", group: "Blocks", title: "Quote",
              symbol: "text.quote", action: .blockquote),
        .init(id: "code", group: "Blocks", title: "Code",
              symbol: "curlybraces", action: .codeBlock),
        .init(id: "divider", group: "Blocks", title: "Divider",
              symbol: "minus", action: .horizontalRule),
    ]

    /// The subset a formatting toolbar offers as "turn into". Same commands, same verbs — a second
    /// surface over one catalogue rather than a parallel one.
    public static let blockCommands: [SlashCommand] = slashCommands.filter {
        ["h1", "h2", "h3", "bullet", "todo"].contains($0.id)
    }

    /// The range of the `/query` the caret is sitting in, or nil when it is not in one.
    ///
    /// The slash has to start a word — at the beginning of a line or after whitespace — so
    /// `http://x` and `and/or` never summon a menu mid-sentence.
    public static func slashQuery(in text: String, caret: Int) -> Range<Int>? {
        let characters = Array(text)
        guard caret <= characters.count else { return nil }
        var start = caret
        while start > 0 {
            let character = characters[start - 1]
            if character == "/" {
                start -= 1
                break
            }
            guard character.isLetter || character.isNumber else { return nil }
            start -= 1
            if start == 0 { return nil }
        }
        guard start < caret, characters[start] == "/" else { return nil }
        guard start == 0 || characters[start - 1].isWhitespace else { return nil }
        return start..<caret
    }

    /// The commands a query matches, in menu order. An empty query is every command — `/` on its
    /// own is somebody who wants to see the list.
    public static func slashMatches(_ query: some StringProtocol) -> [SlashCommand] {
        let needle = query.drop { $0 == "/" }.lowercased()
        guard !needle.isEmpty else { return slashCommands }
        return slashCommands.filter { command in
            command.id.hasPrefix(needle)
                || command.title.lowercased().split(separator: " ").contains { $0.hasPrefix(needle) }
        }
    }
}
