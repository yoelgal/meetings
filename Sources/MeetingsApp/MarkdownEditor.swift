import AppKit
import MarkdownEngine
import MeetingsCore
import SwiftUI

/// Markdown that renders while you type it, drawn by `nodes-app/swift-markdown-engine`.
///
/// **One editor, no toggle.** The hand-built `MarkdownTextView` this replaces failed in a new way
/// every time it was fixed, and the last one says why: its checkbox was a separate overlay view
/// computing its own positions, and it drifted — glyphs drew four hundred points below the text they
/// belonged to. The engine draws the checkbox *inside* the `NSTextLayoutFragment`, with the draw
/// site and the hit-test site calling one shared `TaskCheckboxGeometry`, "so their rects can't drift
/// apart". That is the property worth having, and everything hung off this view keeps it: the two
/// floating surfaces are anchored off `NSTextView.firstRect(forCharacterRange:actualRange:)`, which
/// is the rect AppKit hands an input method for its candidate window — the layout that is on the
/// screen, not a lazy estimate of it.
///
/// The value in and out is the same `String` the CLI writes, handed over through the binding
/// ``SharedFieldEditor`` owns. Autosave, the two-writer conflict banner and the oversize guard sit
/// above this view and never learn what is underneath.
struct LiveMarkdownEditor: View {
    @Binding var text: String
    /// The engine keys its per-document state (scroll offset, undo, wiki-link metadata) off this, so
    /// it is handed ``SharedFieldEditor/identity`` — the same string that resets the editor when the
    /// field or the meeting changes.
    let documentId: String

    /// Everything the chrome needs that the engine does not publish: the live `NSTextView`, the
    /// selection, the anchor rect, and the bus names this instance owns.
    @State private var bridge: MarkdownEditorBridge

    /// `bridge` is handed in only by the mount test, which has to be able to ask it what the probe
    /// found. Every caller in the app lets the editor own one.
    init(text: Binding<String>, documentId: String, bridge: MarkdownEditorBridge? = nil) {
        _text = text
        self.documentId = documentId
        _bridge = State(initialValue: bridge ?? MarkdownEditorBridge())
    }

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: bridge.configuration,
            fontName: MarkdownStyle.bodyFont.fontName,
            fontSize: MarkdownStyle.bodyFont.pointSize,
            documentId: documentId
        )
        // The seam onto AppKit. `NativeTextView` is `internal` and the wrapper publishes no general
        // selection-rect callback, so the text view is found by walking up from a sibling view — see
        // ``MarkdownEditorBridge/attach(probe:)``, and `Patches/` for the five-line upstream change
        // that would make this unnecessary.
        .background(MarkdownEditorProbeView(bridge: bridge))
        // Both float in the editor's own coordinate space, over the rect the text view measured.
        // Neither is a popover: a popover takes key window, and a menu you cannot keep typing into
        // while it filters is not a filter.
        .overlay(alignment: .topLeading) { menuOverlay }
        .overlay(alignment: .topLeading) { toolbarOverlay }
        // The formatting shortcuts are menu items rather than key handlers, because a focused
        // NSTextView owns its own key events and the main menu is the one thing that outranks it.
        // Published only while this editor holds focus, so ⌘B elsewhere still means nothing.
        .focusedValue(\.markdownFormatting, MarkdownFormatting(id: bridge.id) { bridge.run($0) })
    }

    // MARK: - The slash menu

    /// **No anchor, no menu.** The `let anchor` is a gate, not a convenience: an unmeasurable caret
    /// used to be worth falling back to the origin for, and the origin is the worst answer there is
    /// — a menu 1000 pt from the caret reads as a placement bug and costs a day to chase, where a
    /// menu that does not open is a bug you can find in a minute. ``MarkdownEditorBridge/anchorRect``
    /// returns nil rather than a guess for the same reason.
    @ViewBuilder private var menuOverlay: some View {
        if let query = bridge.openQuery, let anchor = bridge.anchor {
            SlashMenu(matches: query.matches, highlighted: bridge.highlightedRow) { command in
                bridge.choose(command)
            }
            .fixedSize()
            // Under the caret. The menu is 299 pt tall and belongs to the line being typed.
            .floating(over: anchor, in: bridge.visible, prefer: .below)
        }
    }

    // MARK: - The selection toolbar

    @ViewBuilder private var toolbarOverlay: some View {
        // Only over a real selection, and never at the same time as the menu — the menu belongs to
        // a caret and the toolbar to a range, so the two cannot both be right.
        if let anchor = bridge.anchor, bridge.selection.length > 0, bridge.openQuery == nil {
            SelectionToolbar(isBold: bridge.isBold, isItalic: bridge.isItalic) { action in
                bridge.run(action)
            }
            .fixedSize()
            // Over the selection, which the pointer is sitting on top of.
            .floating(over: anchor, in: bridge.visible, prefer: .above)
        }
    }
}

/// The body font, and the only thing left of the styling this app used to do itself: the engine owns
/// every other typeface decision now, and a second opinion about what a heading looks like is the
/// class of bug that put markers and text in different places.
@MainActor enum MarkdownStyle {
    static let bodyFont = NSFont.preferredFont(forTextStyle: .body)
}

extension View {
    /// Places a floating surface over `anchor` in the editor's own coordinate space, through the one
    /// decision in ``MarkdownEditing/floating(over:size:in:gap:)`` — so the toolbar and the slash
    /// menu cannot drift apart about what "over the text" means, and neither can be pushed off an
    /// edge where the split view's pane, or the notes panel, clips it.
    ///
    /// Alignment guides rather than an offset: the guide closure is handed the surface's own
    /// dimensions, which is exactly what the placement needs and what a `.offset` would not have.
    func floating(
        over anchor: CGRect, in visible: CGRect, prefer: MarkdownEditing.Side
    ) -> some View {
        // Inlined twice rather than lifted into a local helper: a local function here picks up the
        // view's main-actor isolation, and an alignment guide closure is not isolated.
        alignmentGuide(.leading) { size in
            -MarkdownEditing.floating(
                over: anchor, size: CGSize(width: size.width, height: size.height),
                in: visible, prefer: prefer
            ).x
        }
        .alignmentGuide(.top) { size in
            -MarkdownEditing.floating(
                over: anchor, size: CGSize(width: size.width, height: size.height),
                in: visible, prefer: prefer
            ).y
        }
    }
}

// MARK: - The seam onto the engine's text view

/// A zero-cost sibling of the engine's scroll view, and the coordinate space both floating surfaces
/// are placed in.
///
/// `isFlipped`, so its origin is the top-left one SwiftUI's `.topLeading` overlay alignment uses and
/// a converted rect needs no arithmetic of its own. It draws nothing and it is transparent to the
/// pointer.
final class MarkdownEditorProbe: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct MarkdownEditorProbeView: NSViewRepresentable {
    let bridge: MarkdownEditorBridge

    func makeNSView(context: Context) -> MarkdownEditorProbe { MarkdownEditorProbe() }

    func updateNSView(_ nsView: MarkdownEditorProbe, context: Context) {
        bridge.attach(probe: nsView)
    }
}

/// The half of the editor the library does not ship: which `NSTextView` is on screen, where the
/// selection is, what rect to hang a floating surface off, and how a menu row becomes an edit.
///
/// **Every edit here goes through the engine's `MarkdownEditorBus`** — the NotificationCenter bridge
/// whose names the embedder supplies. Nothing in this file decides what Heading 2 does to a line;
/// the engine does, against the storage it is already holding, which is the whole reason the
/// hand-built transforms were deleted rather than kept alongside it.
///
/// The names are **unique to this instance**, because the engine subscribes with `object: nil`: with
/// one shared name, ⌘B in the floating notes panel would also embolden the write-up behind it.
@MainActor @Observable final class MarkdownEditorBridge {
    /// Unique per mounted editor. Also the identity the Format menu's focused value is keyed on.
    let id = Int.random(in: Int.min...Int.max)

    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var isBold = false
    private(set) var isItalic = false
    /// Where the floating surfaces hang, in the probe's coordinates. Nil before the first layout.
    private(set) var anchor: CGRect?
    /// The part of the editor that is **on screen**, in the probe's own coordinates — never the
    /// editor's frame and never a constant.
    ///
    /// This editor is as tall as its document inside a page that scrolls, so its frame is one to
    /// two thousand points of which a few hundred are visible; placing a surface against the frame
    /// put the slash menu three hundred points above the caret and off the top of the viewport.
    /// The width matters for the same reason it always did — the notes panel lays this editor out
    /// at about 330 pt where the detail pane gives it 520.
    ///
    /// Read on every selection, text and frame change — and on every scroll, because SwiftUI's
    /// `ScrollView` **is** `NSScrollView`-backed here and its clip view says so on
    /// `boundsDidChange`. Measured on macOS 26: the page under the write-up is a
    /// `SwiftUI.HostingScrollView` and the probe's `enclosingScrollView` finds it.
    private(set) var visible: CGRect = CGRect(x: 0, y: 0, width: SharedFieldEditor.column, height: 400)
    /// Which row of the slash menu Return would take.
    private(set) var highlighted = 0
    /// Whether the walk below has found the engine's text view. Without it there is no menu, no
    /// toolbar and no ⌘B — and the failure is silent, so the mount test asks.
    var isAttached: Bool { textView != nil }

    /// The engine's own text view, once the walk below has found it. Internal rather than private so
    /// the mount test can drive the real thing instead of a stand-in.
    @ObservationIgnored private(set) weak var textView: NSTextView?
    @ObservationIgnored private weak var probe: MarkdownEditorProbe?
    /// The clip view of the page this editor is on, once there is one to watch scrolling on.
    @ObservationIgnored private weak var scrolling: NSClipView?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var keyMonitor: Any?
    /// Escape closes the menu without moving the caret, which would otherwise re-open it on the very
    /// next keystroke. Cleared when the caret leaves the query.
    @ObservationIgnored private var dismissed: String?

    /// The `/query` the caret is in, with the rows it matches. Nil when there is no menu.
    ///
    /// A struct rather than a tuple so it is `Equatable`: everything published here is assigned only
    /// on a real change, because an `@Observable` property fires its observers on every *set* and
    /// this is recomputed on every keystroke.
    struct SlashQuery: Equatable {
        let range: NSRange
        let text: String
        let matches: [MarkdownEditing.SlashCommand]
    }

    private(set) var openQuery: SlashQuery?

    /// The highlight, clamped to the list as it stands. Typing narrows the menu under the
    /// selection — arrowing to the ninth item and then filtering to one would otherwise leave
    /// Return pointing at a row that is no longer there.
    var highlightedRow: Int {
        guard let openQuery else { return 0 }
        return min(max(highlighted, 0), openQuery.matches.count - 1)
    }

    // MARK: - Configuration

    /// Themed to this app's tokens rather than left on the library's defaults.
    ///
    /// The colours are the ones the app already paints with: `labelColor` for prose,
    /// `tertiaryLabelColor` for markers — the engine calls it `disabledText` — and
    /// `controlAccentColor` for links. `headingMarker` gets `tertiaryLabelColor` too: the library's
    /// default is a flat `.gray`, which does not track light and dark.
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

    /// `.fitsContent` is not a preference, it is the contract: every home of this editor — the
    /// detail pane, the recording pane and the floating notes panel — is already inside a
    /// `ScrollView`, and an editor that scrolls internally puts two scrolling surfaces under one
    /// trackpad gesture. `.scrolls` is the library's default, so leaving it alone would reintroduce
    /// exactly the defect this editor was rebuilt to remove.
    ///
    /// `readingWidth` stays nil: the measure is ``SharedFieldEditor/column``, applied by the frame
    /// outside this view, and letting the engine centre a column of its own inside that frame would
    /// be two answers to one question.
    var configuration: MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(
            theme: Self.theme,
            services: MarkdownEditorServices(bus: bus),
            scrollers: .hidden,
            textInsets: TextInsets(horizontal: 0, vertical: 6),
            heightBehavior: .fitsContent,
            // `~~struck~~` is **opt-in**. The engine parses pure markdown and ships strikethrough as
            // an extension registered by the embedder; with the library's empty default the text
            // stayed literal — no line through it, and the toolbar's own Strikethrough button
            // offered a mark the document would not render. `theme.strikethroughColor` was already
            // set here, which is how it read as configured when nothing was.
            extensions: [StrikethroughExtension()]
        )
    }

    private func name(_ verb: String) -> Notification.Name {
        Notification.Name("meetings.editor.\(id).\(verb)")
    }

    private var bus: MarkdownEditorBus {
        MarkdownEditorBus(
            applyBoldRequest: name("bold"),
            applyItalicRequest: name("italic"),
            applyHeadingRequest: name("heading"),
            applyStrikethroughRequest: name("strikethrough"),
            applyInlineCodeRequest: name("inlineCode"),
            applyBlockquoteRequest: name("blockquote"),
            applyUnorderedListRequest: name("unorderedList"),
            applyOrderedListRequest: name("orderedList"),
            applyLinkRequest: name("link"),
            applyCodeBlockRequest: name("codeBlock"),
            applyHorizontalRuleRequest: name("horizontalRule"),
            selectionBoldDidChange: name("isBold"),
            selectionItalicDidChange: name("isItalic")
        )
    }

    // MARK: - Finding the text view

    /// Walk up from the probe until a subtree containing an `NSTextView` is found, and take the
    /// nearest one.
    ///
    /// **Introspection, and deliberately the nearest match rather than the first in the window.**
    /// The engine's `NSViewType` is a public `NSScrollView` but its `NativeTextView` is `internal`,
    /// so there is no supported handle on it. Going up one level at a time means two editors mounted
    /// at once — the write-up behind the floating notes panel — each find their own.
    func attach(probe: MarkdownEditorProbe) {
        self.probe = probe
        // Nothing observable is written on the already-attached path: this runs inside SwiftUI's own
        // update, and publishing from there is how a view invalidates itself in a loop. Selection,
        // text and frame changes all arrive on their own notifications instead.
        guard textView == nil else { return }
        guard let found = Self.nearestTextView(from: probe) else {
            // Measured: the probe's first `updateNSView` runs *before* SwiftUI has added the
            // wrapper's own view as its sibling, so the first walk always comes back empty and one
            // turn of the run loop is enough. It keeps retrying rather than giving up — the probe is
            // weak, so the retry ends when the editor is unmounted — and waits 20 ms between
            // attempts so a hierarchy that never produces a text view cannot spin a core.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak probe] in
                guard let self, let probe, self.textView == nil else { return }
                self.attach(probe: probe)
            }
            return
        }
        textView = found
        observe(found, probe: probe)
        // Out of the update pass, for the reason above.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private static func nearestTextView(from probe: NSView) -> NSTextView? {
        var node = probe.superview
        while let current = node {
            if let found = firstTextView(in: current) { return found }
            node = current.superview
        }
        return nil
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        for sub in view.subviews {
            if let tv = sub as? NSTextView { return tv }
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }

    private func observe(_ tv: NSTextView, probe: MarkdownEditorProbe) {
        let center = NotificationCenter.default
        probe.postsFrameChangedNotifications = true
        for (name, object) in [
            (NSTextView.didChangeSelectionNotification, tv as Any),
            (NSText.didChangeNotification, tv as Any),
            (NSView.frameDidChangeNotification, probe as Any),
        ] {
            observers.append(
                center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
        // The engine's own answer to "is the selection bold", posted on every selection change. The
        // toolbar reads it rather than re-deriving it, so a button cannot say "on" while ⌘B turns it
        // on again.
        observers.append(
            center.addObserver(forName: name("isBold"), object: nil, queue: .main) { [weak self] note in
                let on = note.userInfo?["isBold"] as? Bool ?? false
                MainActor.assumeIsolated { self?.isBold = on }
            }
        )
        observers.append(
            center.addObserver(forName: name("isItalic"), object: nil, queue: .main) { [weak self] note in
                let on = note.userInfo?["isItalic"] as? Bool ?? false
                MainActor.assumeIsolated { self?.isItalic = on }
            }
        )
        installKeyMonitor()
    }

    /// `isolated`, because both of these are AppKit registrations that have to come off on the main
    /// thread — and a key monitor left installed after the editor has gone is an app that swallows
    /// Return.
    isolated deinit {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver(_:))
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - What the chrome reads

    /// Assign-on-change throughout: `@Observable` notifies on every set, and this runs on every
    /// keystroke, so an unconditional write here is a SwiftUI invalidation per character typed.
    private func refresh() {
        guard let tv = textView, let probe else { return }
        followScrolling(of: probe)
        let onScreen = Self.viewport(of: probe)
        if visible != onScreen { visible = onScreen }
        let selected = tv.selectedRange()
        if selection != selected { selection = selected }
        let rect = Self.anchorRect(for: selected, in: tv, probe: probe)
        if anchor != rect { anchor = rect }
        let found = query(in: tv, selection: selected)
        if openQuery != found { openQuery = found }
    }

    /// The slice of the editor that is on screen, in the probe's own coordinates — the space the
    /// anchor is in.
    ///
    /// **The clip view of the page is the authority.** SwiftUI's `ScrollView` is `NSScrollView`-
    /// backed on macOS, and `contentView.bounds` *is* the visible slice in document coordinates; it
    /// is also the rect the scroll notification carries, so what is placed and what is observed
    /// cannot disagree. `probe.visibleRect.intersection(probe.bounds)` is the fallback for an editor
    /// with no scroll view above it at all — the mount test has none — and it is a fallback rather
    /// than the source because it answers "clipped by every ancestor", a longer question than the
    /// one being asked.
    ///
    /// **Clipped to the editor across, not down.** The width is intersected with the editor's own
    /// bounds, because the horizontal clamp exists to keep a surface inside the column rather than
    /// out in the window beside it. The *height* is the clip view's, untouched — and that is the
    /// defect this line used to carry.
    ///
    /// Intersecting the height with `probe.bounds` made `visible.maxY` the bottom of the **editor**,
    /// so "is there room below the caret" was asked of the document rather than of the screen. At
    /// the end of a document there is by definition nothing below the last line, so the answer was
    /// always no — for every caret at the end of every write-up, which is where a menu is opened
    /// most. With the page scrolled so the tail of the summary sits near the top of the viewport,
    /// room *above* is small too, both sides fail, and the menu is drawn 305 pt above the caret and
    /// off the top of the page: "the shortcuts menu appears right at the top of the summary".
    ///
    /// Nothing below the last line is a fact about the editor, not about the screen. These surfaces
    /// float over the page and are clipped by *its* scroll view, so a menu hanging under the final
    /// line is drawn over whatever the page has below the write-up, which is exactly where it
    /// belongs.
    ///
    /// A hierarchy not laid out yet reports an empty rect, and an empty viewport would put both
    /// surfaces on a point.
    private static func viewport(of probe: MarkdownEditorProbe) -> CGRect {
        let seen = probe.enclosingScrollView.map { probe.convert($0.contentView.bounds, from: $0.contentView) }
            ?? probe.visibleRect.intersection(probe.bounds)
        let minX = max(seen.minX, probe.bounds.minX)
        let maxX = min(seen.maxX, probe.bounds.maxX)
        guard seen.height > 0, maxX > minX else { return probe.bounds }
        return CGRect(x: minX, y: seen.minY, width: maxX - minX, height: seen.height)
    }

    /// Recompute when the page scrolls. The clip view only exists once SwiftUI has put the probe
    /// inside it, which is later than `attach`, so this is asked on every refresh and registers
    /// once — a scrolled page with a menu already open used to keep the viewport it was opened at.
    private func followScrolling(of probe: MarkdownEditorProbe) {
        guard let clip = probe.enclosingScrollView?.contentView, clip !== scrolling else { return }
        scrolling = clip
        clip.postsBoundsChangedNotifications = true
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        )
    }

    /// The rect a floating surface hangs off, **measured against the layout that is on screen** and
    /// converted straight through the view tree.
    ///
    /// The segments come from the engine's own `NSTextLayoutManager`, which is the layout that is
    /// drawn — not a re-derivation of it — and `probe.convert(_:from:)` walks the real views, so the
    /// engine's reading-column centring, its scroll-away header band and any scroll offset between
    /// the text view and the probe are all carried by AppKit rather than re-computed here.
    ///
    /// It used to go out to the screen and back in through `firstRect(forCharacterRange:)`. Three
    /// conversions instead of one, and two of them through a window — which meant no window, no
    /// anchor: the mount test could not reach this at all, and the floating notes panel puts a
    /// second editor in a second window, which is exactly where that shape breaks. This needs
    /// neither, so where the menu lands is a test rather than a screenshot.
    ///
    /// A multi-line selection unions its lines, so `minY` is the top of the first one and `maxY` the
    /// bottom of the last — which is what a surface placed above or below the whole selection wants.
    private static func anchorRect(
        for range: NSRange, in tv: NSTextView, probe: MarkdownEditorProbe
    ) -> CGRect? {
        guard let layout = tv.textLayoutManager,
              let content = layout.textContentManager,
              let start = content.location(layout.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let span = NSTextRange(location: start, end: end)
        else { return nil }
        var measured = CGRect.null
        layout.enumerateTextSegments(in: span, type: .standard, options: []) { _, segment, _, _ in
            measured = measured.isNull ? segment : measured.union(segment)
            return true
        }
        // Nil, never a rect nobody measured. Every caller is gated on this being non-nil and hides
        // its surface when it is not — see ``LiveMarkdownEditor/menuOverlay``.
        guard !measured.isNull, measured.height > 0, measured.origin.y.isFinite else { return nil }
        // Segments are in the text container's space; the origin is the inset the engine was
        // configured with.
        measured.origin.x += tv.textContainerOrigin.x
        measured.origin.y += tv.textContainerOrigin.y
        return probe.convert(measured, from: tv)
    }

    private func query(in tv: NSTextView, selection: NSRange) -> SlashQuery? {
        guard selection.length == 0 else { return nil }
        let string = tv.string
        guard let caretIndex = Range(NSRange(location: selection.location, length: 0), in: string)?.lowerBound,
              let span = MarkdownEditing.slashQuery(
                  in: string, caret: string.distance(from: string.startIndex, to: caretIndex)
              )
        else {
            dismissed = nil
            return nil
        }
        let lower = string.index(string.startIndex, offsetBy: span.lowerBound)
        let text = String(string[lower..<caretIndex])
        guard text != dismissed else { return nil }
        dismissed = nil
        let matches = MarkdownEditing.slashMatches(text)
        guard !matches.isEmpty else { return nil }
        return SlashQuery(range: NSRange(lower..<caretIndex, in: string), text: text, matches: matches)
    }

    // MARK: - The menu's keys

    /// ↑, ↓, Return and Escape, taken **before** the text view sees them.
    ///
    /// A local event monitor runs ahead of the responder chain, which is the only place a focused
    /// `NSTextView` can be beaten to Return without a delegate hook — and the engine's own
    /// `doCommandBy` interception is gated on its wiki-link preview, not open to embedders. The
    /// monitor is inert unless this editor is focused with its menu open.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            // `Bool` out, not the event: `NSEvent` is not `Sendable`, so it cannot cross an
            // `assumeIsolated` boundary. Swallowed here means "return nil" to AppKit.
            let swallowed = MainActor.assumeIsolated { self?.menuKey(keyCode) ?? false }
            return swallowed ? nil : event
        }
    }

    private func menuKey(_ keyCode: UInt16) -> Bool {
        guard let tv = textView, tv.window?.firstResponder === tv, let open = openQuery else {
            return false
        }
        switch keyCode {
        case 126: highlighted = max(highlightedRow - 1, 0)
        case 125: highlighted = min(highlightedRow + 1, open.matches.count - 1)
        case 36, 76:
            guard let command = open.matches[safe: highlightedRow] else { return false }
            choose(command)
        case 53:
            dismissed = open.text
            openQuery = nil
        default: return false
        }
        return true
    }

    // MARK: - Applying a command

    func choose(_ command: MarkdownEditing.SlashCommand) {
        let range = openQuery?.range
        openQuery = nil
        highlighted = 0
        run(command.action, swallowing: range)
    }

    /// Every formatting request in the app funnels through here: the slash menu, the selection
    /// toolbar and the Format menu's ⌘-shortcuts.
    ///
    /// `swallowing` is the `/query` that summoned the menu — deleted through `shouldChangeText` /
    /// `didChangeText` so it lands on the engine's undo stack and provokes the same autosave typing
    /// it would have.
    func run(_ action: MarkdownEditing.Action, swallowing range: NSRange? = nil) {
        guard let tv = textView else { return }
        // A SwiftUI Button in the overlay can take first responder off the text view on the way in,
        // and every action below works on `tv.selectedRange()`.
        tv.window?.makeFirstResponder(tv)
        if let range, tv.shouldChangeText(in: range, replacementString: "") {
            tv.replaceCharacters(in: range, with: "")
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location, length: 0))
        }
        let center = NotificationCenter.default
        switch action {
        case .bold: center.post(name: name("bold"), object: nil)
        case .italic: center.post(name: name("italic"), object: nil)
        case .strikethrough: center.post(name: name("strikethrough"), object: nil)
        case .inlineCode: center.post(name: name("inlineCode"), object: nil)
        case .link:
            // The engine wraps a selection as `[text]()` and leaves the caret *past* the closing
            // paren, so the one thing left to type — the target — cannot be typed, and a link with
            // no target is drawn in the theme's `incompleteLink` grey. Put the caret between the
            // parens. Over a caret rather than a selection the engine already lands inside the
            // brackets, which is where the label goes, so that path is left alone.
            let wrapping = tv.selectedRange().length > 0
            center.post(name: name("link"), object: nil, userInfo: ["url": ""])
            if wrapping {
                OperationQueue.main.addOperation { [weak self] in
                    MainActor.assumeIsolated { self?.caretInsideEmptyTarget() }
                }
            }
        case .heading(let level):
            center.post(name: name("heading"), object: nil, userInfo: ["level": level])
        case .bulletList: center.post(name: name("unorderedList"), object: nil)
        case .orderedList: center.post(name: name("orderedList"), object: nil)
        case .blockquote: center.post(name: name("blockquote"), object: nil)
        case .codeBlock: center.post(name: name("codeBlock"), object: nil)
        case .horizontalRule: center.post(name: name("horizontalRule"), object: nil)
        case .taskList:
            // The one command the bus has no verb for. Ask for the bullet, then type the box into
            // the line the engine just made — `applyList` leaves the selection on that line's
            // content, so its `location` is exactly where `[ ] ` belongs.
            //
            // `OperationQueue.main`, not `DispatchQueue.main`: the engine subscribes to the bus with
            // that queue, so an operation enqueued after the post is guaranteed to run after the
            // bullet lands rather than racing it.
            center.post(name: name("unorderedList"), object: nil)
            OperationQueue.main.addOperation { [weak self] in
                MainActor.assumeIsolated { self?.typeTaskBox() }
            }
        }
    }

    /// Steps the caret back inside the `()` the engine just left it behind. Guarded on the two
    /// characters actually being there, so a bus handler that ever changes its mind about where the
    /// caret lands moves nothing rather than moving the wrong thing.
    private func caretInsideEmptyTarget() {
        guard let tv = textView else { return }
        let caret = tv.selectedRange()
        let text = tv.string as NSString
        guard caret.length == 0, caret.location >= 2, caret.location <= text.length,
              text.substring(with: NSRange(location: caret.location - 2, length: 2)) == "()"
        else { return }
        tv.setSelectedRange(NSRange(location: caret.location - 1, length: 0))
    }

    private func typeTaskBox() {
        guard let tv = textView else { return }
        let caret = NSRange(location: tv.selectedRange().location, length: 0)
        guard tv.shouldChangeText(in: caret, replacementString: "[ ] ") else { return }
        tv.replaceCharacters(in: caret, with: "[ ] ")
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: caret.location + 4, length: 0))
    }
}

extension Collection {
    /// The element at `offset`, or nil. Keyboard navigation indexes a list that shrinks under it as
    /// the query narrows, and a trap there is a crash on a keystroke.
    subscript(safe offset: Int) -> Element? {
        guard offset >= 0, offset < count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }
}
