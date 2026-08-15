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
/// floating surfaces are anchored off the engine's own `NSTextLayoutManager` segments — the layout
/// that is drawn, not a lazy estimate of it — and drawn in a window of their own, so nothing about
/// where they land is a second opinion about where the text is.
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
        // **Neither surface is here.** They are drawn in a child window — see
        // ``EditorSurfacePanel``, which the bridge raises and lowers off the same state this view
        // reads. As overlays they were placed correctly and drawn at the top of the document
        // anyway: a SwiftUI overlay inside scrolling content does not draw where it is told, and a
        // popover is not the alternative, because a popover takes key window and a menu you cannot
        // keep typing into while it filters is not a filter.
        //
        // The formatting shortcuts are menu items rather than key handlers, because a focused
        // NSTextView owns its own key events and the main menu is the one thing that outranks it.
        // Published only while this editor holds focus, so ⌘B elsewhere still means nothing.
        .focusedValue(\.markdownFormatting, MarkdownFormatting(id: bridge.id) { bridge.run($0) })
    }
}

/// The body font, and the only thing left of the styling this app used to do itself: the engine owns
/// every other typeface decision now, and a second opinion about what a heading looks like is the
/// class of bug that put markers and text in different places.
@MainActor enum MarkdownStyle {
    static let bodyFont = NSFont.preferredFont(forTextStyle: .body)
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
    /// The window this editor is in, once there is one to watch moving and resizing.
    @ObservationIgnored private weak var host: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var keyMonitor: Any?
    /// Escape closes the menu without moving the caret, which would otherwise re-open it on the very
    /// next keystroke. Cleared when the caret leaves the query.
    @ObservationIgnored private var dismissed: String?
    /// The same, for the toolbar: the selection Escape dismissed it over. Cleared the moment the
    /// selection changes, so the next drag brings it back.
    @ObservationIgnored private var dismissedSelection: NSRange?
    /// The child window both surfaces are drawn in — built on first use, so an editor that never
    /// opens one never makes a window at all. That is what keeps `swift test` windowless.
    @ObservationIgnored private var surfaces: EditorSurfacePanel?

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
        // And the surfaces' window, which belongs to this editor and to nothing else — an editor
        // unmounted with its menu open would otherwise leave a panel on screen owned by nobody.
        surfaces?.close()
    }

    // MARK: - What the chrome reads

    /// Assign-on-change throughout: `@Observable` notifies on every set, and this runs on every
    /// keystroke, so an unconditional write here is a SwiftUI invalidation per character typed.
    private func refresh() {
        guard let tv = textView, let probe else { return }
        followScrolling(of: probe)
        followWindow(of: probe)
        let onScreen = Self.viewport(of: probe)
        if visible != onScreen { visible = onScreen }
        let selected = tv.selectedRange()
        if selection != selected {
            selection = selected
            dismissedSelection = nil
        }
        let rect = Self.anchorRect(for: selected, in: tv, probe: probe)
        if anchor != rect { anchor = rect }
        let found = query(in: tv, selection: selected)
        if openQuery != found { openQuery = found }
        syncSurface()
    }

    // MARK: - The floating surfaces

    /// Whether this editor is the one being typed into. Both surfaces belong to a caret in *this*
    /// text view, so a click into anything else takes them down with it — and there is no
    /// notification for a change of first responder, which is why every trigger that could have
    /// caused one comes back through `refresh`.
    ///
    /// **Key window as well as first responder.** Resigning key does not change first responder, so
    /// without this a menu opened here would still be on screen — floating in front of Zoom, since
    /// it is a window of its own now — after switching to another app. The notes panel is
    /// non-activating but still becomes key when typed into, which is what makes this the same
    /// question in both homes.
    var focused: Bool {
        guard let textView, let window = textView.window else { return false }
        return window.isKeyWindow && window.firstResponder === textView
    }

    /// Which surface is up, if either — asked of ``MarkdownEditing/surface(anchor:visible:hasQuery:selectionLength:focused:dismissed:)``
    /// so the decision is a value with tests behind it rather than two `if`s in two views.
    var surface: MarkdownEditing.Surface? {
        MarkdownEditing.surface(
            anchor: anchor, visible: visible, hasQuery: openQuery != nil,
            selectionLength: selection.length, focused: focused,
            dismissed: dismissedSelection == selection
        )
    }

    /// Raises, moves or lowers the panel — the single point where state becomes a window on screen.
    ///
    /// Called from `refresh`, which already runs on every selection, text, frame, scroll, window
    /// move and focus change, and from the two places that change `openQuery` without one.
    private func syncSurface() {
        guard let probe, let anchor, let surface, probe.window != nil else {
            surfaces?.hide()
            return
        }
        let panel = surfaces ?? EditorSurfacePanel()
        surfaces = panel
        panel.show(surface, over: anchor, in: visible, from: probe, bridge: self)
    }

    /// The slice of the editor that is on screen, in the probe's own coordinates — the space the
    /// anchor is in.
    ///
    /// **The window's own content area, converted once. Nothing else.** Three derivations from the
    /// scroll view were tried and all three lie inside SwiftUI's. Traced from the running app with
    /// the page scrolled 1661 pt and the caret at y = 2182 in the probe:
    ///
    ///     probe.convert(clip.bounds, from: clip)          →  (0, -228, 308x794)
    ///     scroll.documentVisibleRect (from documentView)  →  (0, -226, 308x794)   reported -53
    ///     probe.visibleRect                               →  (0, -225, 308x794)
    ///     probe.convert(probe.bounds, to: nil)            →  (-1661, h2230)   ← the truth
    ///
    /// `HostingScrollView` reporting an offset of −53 for a page scrolled 1661 is the whole story:
    /// SwiftUI does not drive its scroll view the way a hand-built `NSScrollView` is driven, and
    /// every derivation from it described a page that was not on screen. The window's content view
    /// *is* the visible region by definition, and one conversion puts it in the space the anchor
    /// already lives in. `visibleRect` stays behind it for an editor with no window at all — the
    /// mount tests have none, and they must never make one.
    ///
    /// **Clipped to the editor across, not down.** The width is intersected with the editor's own
    /// bounds, because the horizontal clamp exists to keep a surface inside the column rather than
    /// out in the window beside it. The height is deliberately *not*: capping it at the bottom of
    /// the document made "is there room below the caret" a question about the document, and at the
    /// end of a write-up the answer is structurally no — which flipped every menu up the page.
    ///
    /// A hierarchy not laid out yet reports an empty rect, and an empty viewport would put both
    /// surfaces on a point.
    private static func viewport(of probe: MarkdownEditorProbe) -> CGRect {
        let seen = probe.window.map { probe.convert($0.contentLayoutRect, from: nil) }
            ?? probe.visibleRect
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

    /// The surfaces are a window now, positioned in screen coordinates, so everything that moves the
    /// editor's window has to move them: a drag of the title bar, a resize, and going full screen.
    ///
    /// The two key notifications are here because **focus** decides whether they are up at all, and
    /// AppKit posts nothing when first responder changes inside a window — resigning key is the one
    /// moment it can be caught for free. Registered once, on the same "later than `attach`" schedule
    /// as the clip view above: a view has no window until SwiftUI has put it in one.
    private func followWindow(of probe: MarkdownEditorProbe) {
        guard let window = probe.window, window !== host else { return }
        host = window
        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
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
        guard let tv = textView, tv.window?.firstResponder === tv else { return false }
        guard let open = openQuery else {
            // Escape takes the toolbar down too, and only while it is actually up — a surface you
            // cannot dismiss over a selection you want to keep is a bar sitting on your text.
            guard keyCode == 53, surface == .toolbar else { return false }
            dismissedSelection = selection
            syncSurface()
            return true
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
            syncSurface()
        default: return false
        }
        return true
    }

    // MARK: - Applying a command

    func choose(_ command: MarkdownEditing.SlashCommand) {
        let range = openQuery?.range
        openQuery = nil
        highlighted = 0
        // Before the edit, not after: the menu is closed the instant a row is chosen, rather than
        // whenever the text change that follows comes back around through `refresh`.
        syncSurface()
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
