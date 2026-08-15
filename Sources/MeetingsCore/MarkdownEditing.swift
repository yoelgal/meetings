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
/// It stays in `MeetingsCore` rather than in the app for the reason it always did: "the menu never
/// opens mid-word" and "the toolbar is never drawn outside the column" are decisions, not layout,
/// and they are testable here without an executable target, a window, or a text view. `MeetingsApp`
/// does have a test target now (`MeetingsAppTests`, for the bridge onto the engine's text view),
/// but every suite in it that mounts an editor is gated behind `MEETINGS_LIVE_EDITOR`.
public enum MarkdownEditing {
    // MARK: - Where a floating surface goes

    /// Where the toolbar over a selection — or the menu under the caret — is drawn, in the editor's
    /// own coordinates.
    public struct Placement: Equatable, Sendable {
        public let x: CGFloat
        public let y: CGFloat
        /// True when it went underneath the anchor rather than over it.
        public let below: Bool

        public init(x: CGFloat, y: CGFloat, below: Bool) {
            self.x = x
            self.y = y
            self.below = below
        }
    }

    /// Which side of the anchor a surface belongs on when both sides fit.
    ///
    /// A toolbar belongs to a *selection*, which the pointer is on top of, so it goes above. A menu
    /// belongs to a *caret*, and every editor that opens one drops it under the line you are typing
    /// — a list that appears three hundred points above the caret reads as somebody else's menu.
    public enum Side: Sendable { case above, below }

    /// Which floating surface belongs on screen, if either.
    ///
    /// There is one of these at a time by construction: the menu belongs to a caret and the toolbar
    /// to a range, so the two cannot both be right.
    public enum Surface: Equatable, Sendable {
        case menu
        case toolbar

        /// The side each one asks ``MarkdownEditing/floating(over:size:in:prefer:gap:)`` for.
        public var prefer: Side {
            switch self {
            case .menu: .below
            case .toolbar: .above
            }
        }
    }

    /// Whether either surface is up, and which — the one gate behind both, so they cannot end up
    /// showing together or living by different rules.
    ///
    /// **No anchor, no surface, ever.** An unmeasurable caret used to be worth falling back to the
    /// origin for, and the origin is the worst answer there is: a menu 1000 pt from the caret reads
    /// as a placement bug and costs a day to chase, where a menu that does not open is a bug you can
    /// find in a minute.
    ///
    /// `visible` closes the surfaces when the line they belong to is scrolled off. They are drawn in
    /// a window of their own now, which no scroll view clips — so what used to be handled by
    /// clipping has to be a decision here instead. The test is vertical overlap rather than
    /// `intersects`: a caret has no width, and `CGRect.intersects` is false for every empty rect.
    public static func surface(
        anchor: CGRect?, visible: CGRect, hasQuery: Bool, selectionLength: Int,
        focused: Bool, dismissed: Bool
    ) -> Surface? {
        guard focused, let anchor, anchor.maxY > visible.minY, anchor.minY < visible.maxY else {
            return nil
        }
        if hasQuery { return .menu }
        guard selectionLength > 0, !dismissed else { return nil }
        return .toolbar
    }

    /// Touching `anchor` — always — on whichever side of it the visible viewport has room for.
    ///
    /// `visible` is the editor's visible slice in the editor's own coordinates: the clip view of the
    /// page that scrolls, in the space the anchor is already in. It decides **which side** the
    /// surface goes on. It does not decide *where*: the surface is drawn against the caret, one
    /// `gap` from it, and nothing moves it further away.
    ///
    /// **That is the defect this was rewritten for, twice.** The first version asked "is there room
    /// above" against the top of the *document*, which on a page that scrolls is nearly always yes,
    /// so the 300 × 299 menu was drawn 305 pt above the caret and off the top of the screen. The
    /// second version bounded it by clamping the result into `visible` — and a clamp can only ever
    /// fire when the placement is outside the viewport, which is to say when the viewport being
    /// clamped into disagrees with where the caret is. It fired: the menu was reported pinned to the
    /// top of the pane, about five hundred points above the `/` that opened it, over unrelated text.
    /// A viewport reading can go stale or come back short; a caret cannot. So the caret is what the
    /// surface is placed against, and the viewport only chooses a side.
    ///
    /// When neither side has room — the floating notes panel, which is shorter than the menu — the
    /// side with *more* room wins and the surface overflows the far edge, where the scroll view
    /// clips it. Overflowing means the rows nearest the caret are the ones you can see. Pinning to
    /// an edge instead means a menu somewhere else on the screen, covering the line it belongs to.
    ///
    /// The horizontal clamp has always been here and stays: the toolbar is about 280 pt wide and a
    /// selection starting at the left edge of the text — where a drag usually starts — centres to
    /// roughly −95, outside the column and past the edge of a pane that clips. It is a clamp against
    /// a width, not against a scroll offset, so it has none of the above's failure mode.
    ///
    /// A pure function over four rectangles so it can be tested, which is the whole reason it is
    /// here rather than inline in an `alignmentGuide` closure where nothing could reach it. A
    /// zero-height or zero-width anchor is still a position — a caret has no width, and a surface
    /// that refused to place itself over one would be a menu that never opened.
    public static func floating(
        over anchor: CGRect, size: CGSize, in visible: CGRect,
        prefer: Side = .above, gap: CGFloat = 6
    ) -> Placement {
        let x = clamp(anchor.midX - size.width / 2, visible.minX, visible.maxX - size.width)
        // Room measured from the caret to the edges of the *viewport* — the question the last two
        // versions of this answered against the document.
        let roomAbove = anchor.minY - gap - visible.minY
        let roomBelow = visible.maxY - anchor.maxY - gap
        let goBelow: Bool
        switch (roomBelow >= size.height, roomAbove >= size.height) {
        case (true, true): goBelow = prefer == .below
        case (true, false): goBelow = true
        case (false, true): goBelow = false
        case (false, false): goBelow = roomBelow >= roomAbove
        }
        return Placement(
            x: x,
            y: goBelow ? anchor.maxY + gap : anchor.minY - size.height - gap,
            below: goBelow
        )
    }

    /// `max(hi, lo)` on the upper bound as well, because a viewport smaller than the surface has no
    /// valid range at all and `min(v, hi)` against a `hi` below `lo` would push it off the near edge.
    private static func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(value, lo), max(hi, lo))
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

    /// What a row or a toolbar button draws to say which command it is.
    ///
    /// Text, not only a symbol, because SF Symbols has no legible glyph for a heading level:
    /// `textformat.size.larger`, `.size` and `.size.smaller` all draw as an `A`, so Heading 1 and
    /// Heading 3 arrived on screen as the same picture carrying no information — reported twice.
    /// "H1" is what the construct is called, and two characters say it exactly.
    public enum Label: Equatable, Sendable {
        case symbol(String)
        case text(String)

        /// The SF Symbol name, or nil for a text label. Nil is not a fallback: a caller that draws
        /// text draws text.
        public var symbolName: String? {
            if case .symbol(let name) = self { return name }
            return nil
        }
    }

    /// One item of the menu `/` opens.
    public struct SlashCommand: Equatable, Sendable, Identifiable {
        public let id: String
        public let group: String
        public let title: String
        public let label: Label
        public let action: Action

        public init(id: String, group: String, title: String, label: Label, action: Action) {
            self.id = id
            self.group = group
            self.title = title
            self.label = label
            self.action = action
        }

        public var shorthand: String { "/\(id)" }
    }

    /// The menu, in the order it is drawn. Block-level only: a slash command fires at a caret with
    /// nothing selected, so bold would have nothing to embolden — inline formatting is the
    /// keyboard shortcuts, the selection toolbar and the as-you-type styling, and it is not here.
    ///
    /// Every symbol name below is one that resolves on macOS 26 — checked by loading each through
    /// `NSImage(systemSymbolName:)`, because a name that does not exist draws a blank box and the
    /// menu is the one surface where that is invisible until somebody opens it. The headings carry
    /// text instead, for the reason on ``Label``.
    public static let slashCommands: [SlashCommand] = [
        .init(id: "h1", group: "Headings", title: "Heading 1",
              label: .text("H1"), action: .heading(1)),
        .init(id: "h2", group: "Headings", title: "Heading 2",
              label: .text("H2"), action: .heading(2)),
        .init(id: "h3", group: "Headings", title: "Heading 3",
              label: .text("H3"), action: .heading(3)),
        .init(id: "bullet", group: "Lists", title: "Bulleted list",
              label: .symbol("list.bullet"), action: .bulletList),
        .init(id: "number", group: "Lists", title: "Numbered list",
              label: .symbol("list.number"), action: .orderedList),
        .init(id: "todo", group: "Lists", title: "Action",
              label: .symbol("checklist"), action: .taskList),
        .init(id: "quote", group: "Blocks", title: "Quote",
              label: .symbol("text.quote"), action: .blockquote),
        .init(id: "code", group: "Blocks", title: "Code",
              label: .symbol("curlybraces"), action: .codeBlock),
        .init(id: "divider", group: "Blocks", title: "Divider",
              label: .symbol("minus"), action: .horizontalRule),
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
