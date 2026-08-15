import MeetingsCore
import SwiftUI

/// The `scheduled` detail: attendees, the big Start button, and a markdown editor for pre-meeting
/// notes that autosaves.
struct ScheduledDetailView: View {
    let model: AppModel
    let meeting: Meeting

    var body: some View {
        // The pane scrolls, because the editor inside it no longer does. One scrolling surface per
        // screen: the editor grows to its document and the page carries it, which is the same rule
        // the written-up detail follows.
        ScrollView {
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
                }
            }
            .padding(detailInset)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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
    /// Whether the field wears a section header.
    ///
    /// It does in the panel and the pre-meeting pane, where it is one field among several and has to
    /// say which one. The write-up does not: it is the whole surface of its screen, and a "Summary"
    /// caption over it was the last piece of panel chrome making a document read as a form. The
    /// title is still handed over — it is what the field is called to VoiceOver either way.
    var titleShown = true

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

    /// The reading measure: **40rem, where a rem is this app's own body text**, so it tracks the
    /// system text size instead of being a number that is only right at one of them.
    ///
    /// At the default 13 pt body that is 520 pt. Measured on `.SFNS-Regular` at 13 pt, the average
    /// advance over ordinary prose is 5.96 pt, so this column is about **87 characters** — against
    /// the 110 the full 656 pt detail column was giving, which is what made the write-up read as a
    /// wide text field rather than as a document. A pane wider than this puts the difference into
    /// margin, which is what the leftover space is for.
    ///
    /// ponytail: 87 characters is still above the 65–75 that typography would call comfortable —
    /// 40rem is the number the agreed design names, and the character count is the thing to argue
    /// with. One constant moves it.
    static var column: CGFloat { 40 * MarkdownStyle.bodyFont.pointSize }

    /// The editor's own inset inside the column.
    static let editorInset: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if titleShown || popOut != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if titleShown { SectionHeader(title: title, trailing: status) }
                    if let popOut { PopOutButton(action: popOut) }
                }
            } else {
                // No label over the write-up — the document is the surface. The row stays, at
                // caption height with nothing in it, so the document does not jump down the screen
                // the moment the field has something to say.
                Text(transientStatus ?? " ")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: Self.column, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .animation(.default, value: transientStatus)
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
            editor
                // No fill, no border, no corner radius. The write-up is the document this screen
                // exists for, and a box around it made it read as one field on a form — the
                // engine draws the structure a container was standing in for.
                .frame(maxWidth: Self.column)
                // Attached *inside* the padding, so top-leading here is the text view's own origin
                // and the only thing left to line up is its internal inset. Overlaying outside the
                // padding instead meant two hand-tuned numbers guessing at that origin, and they
                // guessed wrong: the caret sat above and left of the placeholder it belongs in
                // front of. The font has to match for the same reason — a different font puts the
                // first baseline in a different place. The 6 pt is the editor's own
                // `TextInsets(vertical:)`, and there is no leading inset to match any more — the
                // engine has no gutter, so prose starts at the column's edge.
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            // Matches the font an unstyled line is drawn at, for the reason above.
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
                .padding(Self.editorInset)
                // A floor, not a height. The editor is as tall as its document now — that is what
                // `heightBehavior: .fitsContent` buys — and this only keeps an empty one big enough
                // to aim a pointer at.
                .frame(minHeight: 220, alignment: .top)
                // Centred, so the leftover width on a wide pane becomes margin either side of the
                // measure rather than a longer line.
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(title)
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

    /// The editor, mounted once for both fields that have two writers, so the summary and the
    /// pre-notes cannot end up behaving differently. Everything the surrounding view does — the
    /// measure, the placeholder, the accessibility label, the change watcher that autosaves — is
    /// applied out here, because none of it is the editor's business.
    private var editor: some View {
        LiveMarkdownEditor(text: $text, documentId: identity)
    }

    private var status: String {
        if tooLargeToEdit { return "Read-only" }
        if external != nil { return "Updated externally" }
        if saving { return "Saving…" }
        return touched ? "Unsaved" : "Saved"
    }

    /// The same states, minus the steady one. A field that says "Saved" permanently is telling you
    /// something that is true almost always and therefore worth nothing; the states that are *not*
    /// the resting state are the ones somebody needs to see.
    private var transientStatus: String? {
        let now = status
        return now == "Saved" ? nil : now
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
            // No scroll view of its own. Every home of this editor now scrolls its page, and a
            // second surface inside one of them is the ambiguous trackpad drag the write-up just
            // stopped having.
            MarkdownText(source: value)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

/// "Updated externally", with the diff rather than a shrug. Showing what changed is the difference
/// between a decision and a coin toss — the choice this offers is keep mine, take theirs, or keep
/// both, and nobody can make it from the fact that *something* moved.
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
