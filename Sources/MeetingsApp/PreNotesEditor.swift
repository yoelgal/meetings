import MeetingsCore
import SwiftUI

/// The `scheduled` detail: attendees, the big Start button, and a markdown editor for pre-meeting
/// notes that autosaves.
struct ScheduledDetailView: View {
    let model: AppModel
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DetailHeader(title: meeting.title, subtitle: subtitle)
            HStack(spacing: 10) {
                Button {
                    Task { await model.startRecording(meetingID: meeting.id) }
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                // The link the meeting is on, when it came from the calendar and is still in the
                // look-ahead window. Losing it would mean leaving this pane to find the invitation
                // in Calendar, which is where somebody about to join a call actually is.
                if let link = model.calendarEvent(for: meeting)?.videoLink {
                    Link(destination: link) {
                        Label(link.host() ?? link.absoluteString, systemImage: "video")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)

            // On its own line, and it can be opened. Squeezed beside the Start button it was one
            // truncated line: a nine-person meeting showed five names and lost four with nothing on
            // screen saying so. the attendee list is detail-view content.
            if !meeting.attendees.isEmpty {
                AttendeeSummary(attendees: meeting.attendees)
            }
            // The editor takes the rest of the pane. It is the only thing on this screen you can
            // actually do before the meeting starts, and wave 2 gave it a 220 pt box with six
            // hundred points of empty pane underneath.
            if model.notesPanelHolds(meeting, .preNotes) {
                DetachedNotesNotice(what: "These pre-meeting notes") {
                    model.setNotesPanel(.preNotes, open: false)
                }
            } else {
                PreNotesEditor(meeting: meeting) { text in
                    model.savePreNotes(meetingID: meeting.id, text: text)
                } popOut: {
                    model.setNotesPanel(.preNotes, open: true)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(detailInset)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var subtitle: String {
        guard let start = meeting.scheduledStart else { return "Not scheduled" }
        var parts = [Format.detailDate(start), Format.timeOfDay(start)]
        if let length = Format.duration(from: start, to: meeting.scheduledEnd) {
            parts.append(length)
        }
        return parts.joined(separator: " · ")
    }
}

/// Who is coming, on one line until you ask for the rest. Nobody is ever silently dropped: past
/// the inline limit the line says how many it is not showing and the control next to it shows them.
struct AttendeeSummary: View {
    let attendees: [Attendee]

    @State private var expanded = false

    /// Four names is about what fits on one line of a detail column at its 380 pt minimum.
    private static let inlineLimit = 4

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.2")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(names)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if attendees.count > Self.inlineLimit {
                Button(expanded ? "Show fewer" : "Show all \(attendees.count)") {
                    withAnimation { expanded.toggle() }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            Spacer(minLength: 0)
        }
    }

    private var names: String {
        let all = attendees.map(\.displayName)
        guard !expanded, all.count > Self.inlineLimit else { return all.joined(separator: ", ") }
        let shown = all.prefix(Self.inlineLimit).joined(separator: ", ")
        return "\(shown), and \(all.count - Self.inlineLimit) more"
    }
}

/// The pre-notes field, which is ``SharedFieldEditor`` with the pre-notes wording on it. Kept as its
/// own type so the three call sites that already say `PreNotesEditor(meeting:save:)` stay as they
/// are.
struct PreNotesEditor: View {
    let meeting: Meeting
    let save: (String) -> Void
    /// Nil inside the floating panel — the content is already out, and it has its own control for
    /// putting it back.
    var popOut: (() -> Void)?

    var body: some View {
        SharedFieldEditor(
            title: "Pre-meeting notes",
            value: meeting.preNotes,
            identity: "prenotes:\(meeting.id)",
            placeholder: "What do you want out of this meeting? Markdown works here.",
            oversizeHint: "Read and change these notes with meetings prenotes get and meetings prenotes set --file.",
            draft: Appearance.preNotesDraft,
            save: save,
            popOut: popOut
        )
    }
}

/// A markdown editor over a column the CLI also writes, that autosaves and never loses either
/// writer's work.
///
/// The hard case: the CLI appends while this editor is open. **Untouched
/// field: reload silently.** That is the common case — you wrote your notes, an agent added the
/// agenda it pulled off the calendar, and the text should just appear. **Touched field: never
/// clobber either side.** A banner shows what changed and offers the three answers that actually
/// exist — keep mine, take theirs, keep both — because silently winning in either direction throws
/// away work somebody deliberately wrote.
///
/// The decision itself is ``SharedFieldEdit`` in `MeetingsCore`, where it can be tested. This view is
/// the part of it that is layout. Pre-notes and the summary are the same problem — a field with two
/// writers — so they are one editor rather than two that drift.
struct SharedFieldEditor: View {
    let title: String
    /// What the store currently holds for this field.
    let value: String
    /// Changing it resets the editor. A different meeting, or a different field of the same
    /// meeting, is a new document and nothing about the last one's edit state carries over.
    let identity: String
    let placeholder: String
    /// The second sentence of the oversize notice, naming the commands that can still reach this
    /// particular field.
    let oversizeHint: String
    /// Screenshot seam only — see `Appearance.preNotesDraft`.
    var draft: String?
    let save: (String) -> Void
    /// Nil inside the floating panel — the content is already out, and it has its own control for
    /// putting it back.
    var popOut: (() -> Void)?

    @State private var text = ""
    /// The last value this editor and the store agreed on. Everything is judged against it: an
    /// incoming value equal to it is our own echo, and anything else is somebody else's write.
    @State private var baseline = ""
    /// Typed since the last save landed. This is what "untouched" means.
    @State private var touched = false
    /// A conflicting external value waiting on the user. Non-nil means the banner is up.
    @State private var external: String?
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?
    /// Holds an injected draft unsaved so the *touched* branch of `receive` can be photographed; a
    /// real edit autosaves after 600 ms.
    @State private var autosaveSuspended = false

    /// About 40rem. A measure this wide is what a document is read at; the pane can be twice it on
    /// a large display and the extra goes into margin rather than into 140-character lines.
    static let column: CGFloat = 640

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionHeader(title: title, trailing: status)
                if let popOut { PopOutButton(action: popOut) }
            }

            if let external {
                ExternalChangeBanner(
                    mine: text,
                    theirs: external,
                    keepMine: { resolve(with: text) },
                    useTheirs: { resolve(with: external, mineWins: false) },
                    keepBoth: { resolve(with: SharedFieldEdit.merge(mine: text, theirs: external)) }
                )
            }

            if tooLargeToEdit {
                oversize
            } else {
            LiveMarkdownEditor(text: $text)
                // No fill, no border, no corner radius. The write-up is the document this screen
                // exists for, and a box around it made it read as one field on a form — the
                // markers now sit in a gutter of their own, which is the structure a container was
                // standing in for.
                .frame(maxWidth: Self.column)
                // Attached *inside* the padding, so top-leading here is the text view's own origin
                // and the only thing left to line up is its internal inset. Overlaying outside the
                // padding instead meant two hand-tuned numbers guessing at that origin, and they
                // guessed wrong: the caret sat above and left of the placeholder it belongs in
                // front of. The font has to match for the same reason — a different font puts the
                // first baseline in a different place, and so does the gutter the first line is
                // indented by.
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            // Matches the font an unstyled line is drawn at, for the reason above.
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, MarkdownStyle.gutter)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
                .padding(10)
                .frame(minHeight: 220, maxHeight: .infinity)
                .frame(maxWidth: .infinity, alignment: .center)
                .onChange(of: text) { _, new in
                    guard new != baseline else { return }
                    touched = true
                    scheduleSave()
                }
            }
        }
        .task(id: identity) {
            guard !tooLargeToEdit else { return }
            adopt(value)
            // Screenshot seam, inert unless the environment variable is set — see `Appearance`.
            if let draft {
                autosaveSuspended = true
                text = draft
                touched = true
            }
        }
        .onChange(of: value) { _, incoming in
            guard !tooLargeToEdit else { return }
            receive(incoming)
        }
        .onDisappear { if !tooLargeToEdit { flush() } }
    }

    private var status: String {
        if tooLargeToEdit { return "Read-only" }
        if external != nil { return "Updated externally" }
        if saving { return "Saving…" }
        return touched ? "Unsaved" : "Saved"
    }

    // MARK: - A document too big for a text view

    /// The most this will load into a `TextEditor`. About 35,000 words — an order of magnitude more
    /// than anybody types into a box before a meeting, and comfortably inside what `NSTextView`
    /// lays out without a stall.
    ///
    /// `meetings prenotes set <ref> --file <anything>` takes one command, and an agent pointed at
    /// the wrong file will hand this pane a 10 MB document. It did not fail loudly: the editor
    /// showed its **empty-state placeholder** and the word "Saved", over one core at 100% and RSS
    /// climbing past 400 MB. Empty and "Saved" is the single most dangerous thing this field can
    /// say, because the obvious next move — type a character — would have autosaved a few words
    /// over ten megabytes of somebody's notes.
    ///
    /// So past the limit the field is not an editor at all. Nothing is loaded, nothing is watched,
    /// and `flush()` cannot fire, which is what makes the notes safe rather than merely visible.
    private var tooLargeToEdit: Bool { value.utf8.count > Self.editLimit }

    static let editLimit = 200_000

    private var oversize: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "\(value.utf8.count.formatted(.byteCount(style: .file))) is too large to edit here. \(oversizeHint)",
                systemImage: "lock.doc"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            ScrollView { MarkdownText(source: value) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Two writers, one field

    private func adopt(_ value: String) {
        saveTask?.cancel()
        text = value
        baseline = value
        touched = false
        external = nil
        saving = false
    }

    /// The store's value changed under us.
    private func receive(_ incoming: String) {
        switch SharedFieldEdit.receive(
            incoming: incoming, baseline: baseline, text: text, touched: touched
        ) {
        case .echo: break
        case .reload: adopt(incoming)
        case .conflict: external = incoming
        }
    }

    private func resolve(with value: String, mineWins: Bool = true) {
        saveTask?.cancel()
        text = value
        external = nil
        touched = false
        if mineWins {
            // Their write is already in the store; ours has to be put back over it.
            baseline = value
            saving = true
            save(value)
            saving = false
        } else {
            baseline = value
        }
    }

    // MARK: - Autosave

    /// Debounced. Every keystroke writing to SQLite would be fine for the database and awful for
    /// the other process, which refetches on every commit we post.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func flush() {
        saveTask?.cancel()
        if touched { commit() }
    }

    private func commit() {
        guard !autosaveSuspended else { return }
        guard text != baseline else {
            touched = false
            return
        }
        // Baseline moves *before* the write, so the notification our own save provokes is
        // recognised as an echo rather than mistaken for somebody else's edit.
        baseline = text
        touched = false
        saving = true
        save(text)
        saving = false
    }
}

/// Markdown that renders while you type it: a heading is heading-sized the moment its `##` lands,
/// bold is bold, a bullet reads as a list — and the characters that say so are still there, still
/// selectable, still what the store holds.
///
/// This is a text editor rather than a preview, and the difference matters. Nothing is a mode, so
/// there is no edit/preview toggle to be on the wrong side of, and no second representation to
/// convert back from — the value in and out is the same `String` the CLI writes, which is why the
/// conflict handling, autosave and oversize guard around it did not have to change at all.
///
/// **No library, and no text engine of our own.** The engine is `NSTextView`, which is where the
/// caret, the undo stack and the hanging indent already live — see ``MarkdownTextView`` for why
/// SwiftUI's `TextEditor` could not carry the gutter. Everything here is the markdown decision
/// (``MarkdownSyntax`` and ``MarkdownEditing``, in MeetingsCore where they are tested), a font for
/// each answer, and two floating surfaces hung off rects the text view measured.
///
/// Markers are styled *with* the text they mark rather than hidden. Hiding them means the document
/// on screen has different offsets from the document in the store, which is a second text model to
/// keep in step, and it is the thing that makes a caret land a character off.
struct LiveMarkdownEditor: View {
    @Binding var text: String

    /// The selection as character offsets, published by the text view. Everything on this screen
    /// that has to know where the caret is — the slash menu, the toolbar's pressed buttons — reads
    /// it from here rather than asking AppKit again and getting a different unit.
    @State private var selection = 0..<0
    @State private var caretRect: CGRect?
    @State private var selectionRect: CGRect?
    @State private var handle = MarkdownEditorHandle()
    /// Which row of the slash menu Return would take.
    @State private var highlighted = 0
    /// Escape closes the menu without moving the caret, which would otherwise re-open it on the
    /// very next keystroke. Cleared when the caret leaves the query.
    @State private var dismissedQuery: Range<Int>?

    var body: some View {
        MarkdownTextView(
            text: $text,
            selection: $selection,
            caretRect: $caretRect,
            selectionRect: $selectionRect,
            handle: handle,
            intercept: intercept
        )
        // Both float in the editor's own coordinate space, over the rect the text view measured.
        // Neither is a popover: a popover takes key window, and a menu you cannot keep typing into
        // while it filters is not a filter.
        .overlay(alignment: .topLeading) { menuOverlay }
        .overlay(alignment: .topLeading) { toolbarOverlay }
        // The formatting shortcuts are menu items rather than key handlers, because a focused
        // NSTextView owns its own key events and the main menu is the one thing that outranks it.
        // Published only while this editor holds focus, so ⌘B elsewhere still means nothing.
        .focusedValue(\.markdownFormatting, MarkdownFormatting(id: text.count) { toggle($0) })
    }

    // MARK: - The slash menu

    private var slashQuery: Range<Int>? {
        guard selection.isEmpty else { return nil }
        return MarkdownEditing.slashQuery(in: text, caret: selection.lowerBound)
    }

    private var menu: (range: Range<Int>, matches: [MarkdownEditing.SlashCommand])? {
        guard let range = slashQuery, range != dismissedQuery else { return nil }
        let matches = MarkdownEditing.slashMatches(String(Array(text)[range]))
        return matches.isEmpty ? nil : (range, matches)
    }

    /// The highlight, clamped to the list as it stands. Typing narrows the menu under the
    /// selection — arrowing to the ninth item and then filtering to one would otherwise leave
    /// Return pointing at a row that is no longer there.
    private var highlightedRow: Int {
        guard let menu else { return 0 }
        return min(max(highlighted, 0), menu.matches.count - 1)
    }

    @ViewBuilder private var menuOverlay: some View {
        if let menu, let anchor = caretRect {
            SlashMenu(matches: menu.matches, highlighted: highlightedRow) { command in
                choose(command, over: menu.range)
            }
            .fixedSize()
            .alignmentGuide(.leading) { _ in -anchor.minX }
            .alignmentGuide(.top) { _ in -anchor.maxY - 4 }
        }
    }

    /// Deterministic, because `NSTextView` routes every one of these through `doCommandBy` and we
    /// answer there. The previous build hoped a SwiftUI `onKeyPress` would win the race against a
    /// focused text view for Return and the arrows; this does not have to hope.
    private func intercept(_ key: MarkdownTextView.EditorKey) -> Bool {
        guard let menu else { return false }
        switch key {
        case .up:
            highlighted = max(highlightedRow - 1, 0)
        case .down:
            highlighted = min(highlightedRow + 1, menu.matches.count - 1)
        case .enter:
            guard let command = menu.matches[safe: highlightedRow] else { return false }
            choose(command, over: menu.range)
        case .escape:
            dismissedQuery = menu.range
        }
        return true
    }

    private func choose(_ command: MarkdownEditing.SlashCommand, over range: Range<Int>) {
        handle.apply(MarkdownEditing.insert(command, over: range, in: text))
        highlighted = 0
    }

    // MARK: - The selection toolbar

    @ViewBuilder private var toolbarOverlay: some View {
        // Only over a real selection, and never at the same time as the menu — the menu belongs to
        // a caret and the toolbar to a range, so the two cannot both be right.
        if let anchor = selectionRect, !selection.isEmpty, menu == nil {
            SelectionToolbar(text: text, selection: selection) { mark in
                toggle(mark)
            } turnInto: { command in
                handle.apply(MarkdownEditing.applyBlock(command, in: text, replacing: selection))
            }
            .fixedSize()
            .alignmentGuide(.leading) { $0.width / 2 - anchor.midX }
            // Above the selection, and below it when the selection is near the top of the pane and
            // there is no room — a toolbar off the top edge is a toolbar you cannot press.
            .alignmentGuide(.top) { anchor.minY < $0.height + 8 ? -anchor.maxY - 6 : $0.height + 6 - anchor.minY }
        }
    }

    private func toggle(_ mark: MarkdownEditing.InlineMark) {
        handle.apply(MarkdownEditing.toggle(mark, in: text, selection: selection))
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

private struct ExternalChangeBanner: View {
    let mine: String
    let theirs: String
    let keepMine: () -> Void
    let useTheirs: () -> Void
    let keepBoth: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("These notes were changed by something else while you were typing",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)

            // Added and removed are told apart by the row's own tinted well, not by the hue of one
            // small glyph. `systemGreen` as *text* on a light well measured ~2:1 — under the 4.5:1
            // floor, and it was carrying the entire distinction on its own. The marker is now drawn
            // at full label contrast in both schemes, and the tint behind the whole line is the
            // second, redundant channel.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(Self.diff(from: mine, to: theirs).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.added ? "+" : "−")
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(.primary)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        (line.added ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                            .opacity(0.18),
                        in: .rect(cornerRadius: 4, style: .continuous)
                    )
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 6, style: .continuous))

            HStack(spacing: 8) {
                Button("Keep mine", action: keepMine)
                Button("Use theirs", action: useTheirs)
                Button("Keep both", action: keepBoth)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .systemOrange).opacity(0.5))
        )
    }

    struct Line: Hashable {
        let added: Bool
        let text: String
    }

    /// Line-level, via the standard library's own difference algorithm. A diff library for this
    /// would be a dependency to render at most a dozen lines in a banner.
    static func diff(from mine: String, to theirs: String) -> [Line] {
        let old = mine.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = theirs.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let difference = new.difference(from: old)
        let removals = difference.removals.map { change -> (Int, Line) in
            guard case .remove(let offset, let element, _) = change else { return (0, Line(added: false, text: "")) }
            return (offset, Line(added: false, text: element))
        }
        let insertions = difference.insertions.map { change -> (Int, Line) in
            guard case .insert(let offset, let element, _) = change else { return (0, Line(added: true, text: "")) }
            return (offset, Line(added: true, text: element))
        }
        // Interleaved by position so a changed line reads as − then +, not as two distant blocks.
        // Capped: a banner is a summary, and a hundred-line diff belongs in an editor.
        return (removals + insertions)
            .sorted { $0.0 < $1.0 }
            .prefix(12)
            .map(\.1)
    }
}
