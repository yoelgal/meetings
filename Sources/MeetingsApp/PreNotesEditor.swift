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
    @FocusState private var focused: Bool

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
                .focused($focused)
                // Attached *inside* the padding, so top-leading here is the text view's own origin
                // and the only thing left to line up is its internal inset. Overlaying outside the
                // padding instead meant two hand-tuned numbers guessing at that origin, and they
                // guessed wrong: the caret sat above and left of the placeholder it belongs in
                // front of. The font has to match for the same reason — a different font puts the
                // first baseline in a different place.
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            // Matches the font an unstyled line is drawn at, for the reason above.
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(10)
                .frame(minHeight: 220, maxHeight: .infinity)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10, style: .continuous))
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
/// **No library, and no text engine of our own.** macOS 26's `TextEditor` takes an
/// `AttributedString` binding with a selection to keep valid across attribute changes
/// (`transform(updating:)`), which is the entire hard part of live rendering — caret and undo
/// belong to the same `NSTextView` AppKit has always shipped. Everything below is the markdown
/// decision (``MarkdownSyntax``, in MeetingsCore where it is tested) and a font for each answer.
///
/// Markers are styled *with* the text they mark rather than hidden. Hiding them means the document
/// on screen has different offsets from the document in the store, which is a second text model to
/// keep in step, and it is the thing that makes a caret land a character off.
private struct LiveMarkdownEditor: View {
    @Binding var text: String

    /// What the text view actually holds. `text` stays the value of record — this is a styled view
    /// of it, rebuilt from it whenever the two disagree about characters.
    @State private var rich = AttributedString()
    @State private var selection = AttributedTextSelection()

    var body: some View {
        TextEditor(text: $rich, selection: $selection)
            .scrollContentBackground(.hidden)
            .onChange(of: rich) { _, edited in
                let plain = String(edited.characters)
                // Characters first: the autosave, the conflict check and the store all work off the
                // plain string, and they must not wait on the restyle below.
                if plain != text { text = plain }
                restyle()
            }
            // `initial` covers the first appearance and every reset of the parent's identity — a
            // different meeting is a different document, and there is no separate seeding step to
            // forget.
            .onChange(of: text, initial: true) { _, incoming in
                guard incoming != String(rich.characters) else { return }
                rich = MarkdownStyle.styled(incoming)
                selection = AttributedTextSelection()
            }
    }

    /// Attributes only, never characters — so the caret does not move, and typing at the end of a
    /// heading does not inherit heading size onto the next line.
    ///
    /// Terminates: this writes `rich`, which re-enters `onChange`, whose restyle is idempotent and
    /// so leaves the value equal and writes nothing.
    private func restyle() {
        var styled = rich
        styled.transform(updating: &selection) { MarkdownStyle.apply(to: &$0) }
        if styled != rich { rich = styled }
    }
}

/// Which font each of ``MarkdownSyntax``'s answers is drawn in. The split is deliberate: what
/// counts as a heading is logic and lives in MeetingsCore with tests behind it, and this is the
/// half that is a typeface.
@MainActor enum MarkdownStyle {
    static func styled(_ source: String) -> AttributedString {
        var attributed = AttributedString(source)
        apply(to: &attributed)
        return attributed
    }

    static func apply(to attributed: inout AttributedString) {
        // Everything back to body first, so a line that *stops* being a heading — the `#` deleted —
        // goes back down instead of keeping the size it was given a keystroke ago.
        attributed.font = .body
        attributed.foregroundColor = .primary

        let source = String(attributed.characters)
        var start = attributed.startIndex

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let end = attributed.index(start, offsetByCharacters: line.count)
            if start < end {
                let kind = MarkdownSyntax.line(line)
                let base = font(for: kind)
                attributed[start..<end].font = base
                if kind == .quote { attributed[start..<end].foregroundColor = .secondary }

                for span in MarkdownSyntax.inline(line) {
                    let from = attributed.index(start, offsetByCharacters: span.range.lowerBound)
                    let to = attributed.index(start, offsetByCharacters: span.range.upperBound)
                    switch span.style {
                    case .strong: attributed[from..<to].font = base.bold()
                    case .emphasis: attributed[from..<to].font = base.italic()
                    case .code: attributed[from..<to].font = base.monospaced()
                    }
                }
            }
            // Step over the newline `split` consumed. The last line has none, and asking for the
            // index after the end of the document traps.
            guard end < attributed.endIndex else { break }
            start = attributed.index(end, offsetByCharacters: 1)
        }
    }

    /// `##` is what an agent writes far more often than `#`, so it has to be a heading you can see —
    /// the same sizing ``MarkdownText`` renders a finished document at, so the write-up does not
    /// change shape between the editor and the exported markdown.
    static func font(for line: MarkdownSyntax.Line) -> Font {
        switch line {
        case .heading(let level): MarkdownText.headingFont(level)
        case .bullet, .quote, .body: .body
        }
    }
}

/// "Updated externally", with the diff rather than a shrug. Showing what changed is the difference
/// between a decision and a coin toss.
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
