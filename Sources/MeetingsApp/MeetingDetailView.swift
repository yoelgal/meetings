import AppKit
import MeetingsCore
import SwiftUI

/// The detail column. What it shows is decided by the meeting's state, and nothing in it pretends
/// to a capability the app does not have yet — a fake live transcript would be worse than an
/// honest empty one.
struct MeetingDetailView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let meeting = model.selectedMeeting {
                meetingDetail(meeting)
            } else if model.hasRowsToSelect {
                EmptyStateView(
                    symbol: "waveform",
                    title: "No meeting selected",
                    message: "Select a meeting from the list or start a new one."
                )
            }
            // Nothing at all when the list itself is empty. Wave 1 drew two empty states side by
            // side, both with the same glyph and both explaining the same absence — the list's own
            // empty state already says it, and saying it twice made a first run look broken.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func meetingDetail(_ meeting: Meeting) -> some View {
        switch model.displayState(for: meeting) {
        case .scheduled:
            ScheduledDetailView(model: model, meeting: meeting)
        case .recording:
            RecordingDetailView(model: model, meeting: meeting)
        case .transcribing:
            TranscribingDetailView(meeting: meeting, progress: model.transcribingProgress)
        case .ready, .complete:
            WrittenDetailView(
                meeting: meeting,
                segments: model.segments,
                issues: model.transcriptIssues,
                notes: model.notes,
                command: model.agentCommand(for: meeting),
                enhancementNote: meeting.state == .ready ? model.lastEnhancement : nil,
                folders: model.folders,
                moveToFolder: { model.move(meetingID: meeting.id, toFolder: $0) },
                rename: { model.rename(meetingID: meeting.id, to: $0) },
                saveSummary: { model.saveSummary(meetingID: meeting.id, text: $0) }
            )
        }
    }
}

extension AppModel {
    /// Whether the middle column has anything to pick. Drives the detail column's "pick something"
    /// state, which must not appear when there is nothing to pick.
    var hasRowsToSelect: Bool {
        scope == .upcoming ? !upcoming.isEmpty : !meetings.isEmpty
    }
}

// MARK: - Shared furniture

/// Left-aligned large title with one quiet line under it. Generous side margins, as in every
/// macOS 26 detail pane.
struct DetailHeader: View {
    let title: String
    let subtitle: String
    /// Non-nil makes the title editable where it is shown. Left nil on a `scheduled` meeting, whose
    /// title the calendar still owns — a rename there would be overwritten by the next sync.
    var rename: ((String) -> Void)?

    @State private var draft: String?
    /// Set by Escape so the field's own dismissal does not then save what Escape just rejected.
    @State private var discarding = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let draft {
                TextField("Title", text: Binding(get: { draft }, set: { self.draft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.largeTitle.weight(.semibold))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand {
                        discarding = true
                        self.draft = nil
                    }
                    // Clicking away saves rather than discards. Losing what someone typed because
                    // they reached for the window instead of the Return key is the same bug as the
                    // note field's, and the answer is the same one.
                    .onChange(of: focused) { wasFocused, _ in
                        if wasFocused { commit() }
                    }
            } else {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)
                    // The whole line, not just the glyphs: a title is a click target the width of
                    // the pane, and hunting for the exact letters is not editing.
                    .contentShape(.rect)
                    .onTapGesture(perform: beginEditing)
                    .help(rename == nil ? "" : "Click to rename")
            }
            // Empty on the written-up screen, which says the same things in chips underneath. An
            // empty `Text` still takes a line, and a line of nothing under a title is a gap nobody
            // asked for.
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginEditing() {
        guard rename != nil else { return }
        discarding = false
        draft = title
        focused = true
    }

    private func commit() {
        guard let text = draft else { return }
        draft = nil
        guard !discarding else { return discarding = false }
        // `rename` drops an empty or whitespace-only title on the floor, so a cleared field leaves
        // the generated name in place rather than an unnameable row.
        rename?(text)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            if let trailing {
                Spacer()
                Text(trailing)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textCase(nil)
    }
}

struct AttendeeList: View {
    let attendees: [Attendee]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Attendees")
            if attendees.isEmpty {
                Text("No attendees.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(attendees.enumerated()), id: \.offset) { _, attendee in
                    HStack(spacing: 8) {
                        Text(attendee.displayName)
                            .font(.body)
                        if let email = attendee.secondaryLine {
                            Text(email)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

let detailInset = EdgeInsets(top: 24, leading: 32, bottom: 24, trailing: 32)

/// Markdown, rendered with SwiftUI's own parser and no dependency.
///
/// `AttributedString(markdown:)` handles inline runs — bold, code, links — but Text draws a heading
/// as the literal characters `## Summary`, which is what an agent's summary is mostly made of. So
/// blocks are split here and inline markdown is applied within each.
///
/// Blocks, not lines. Wave 3 mapped one source *line* to one block, which is only correct for
/// source nobody hard-wrapped — and most agents hard-wrap. A wrapped paragraph became a stack of
/// one-line paragraphs: extra leading between every line, and a rag that ignored the measure
/// because each line had already been broken somewhere else. Soft line breaks now reflow into the
/// block they belong to, which is what CommonMark says they mean.
struct MarkdownText: View {
    let source: String

    /// How much of a document this will lay out. Nothing about the limit is arbitrary except the
    /// number: the cost here is one `AttributedString(markdown:)` parse and one `Text` per block,
    /// inside a **non-lazy** `VStack`, so the whole document is parsed and measured before the
    /// first pixel — and there is no scroll position at which SwiftUI stops paying for the rest.
    ///
    /// A 10 MB pre-notes document — an agent that piped a repository into `--file`, which takes one
    /// command — is around 600,000 blocks. It did not render slowly: it wedged the window at 100%
    /// of one core, permanently, on "Reading your meetings…", with the sidebar and the meeting list
    /// gone. The only way out was Force Quit, and the next launch did it again, because the
    /// selection is remembered.
    ///
    /// 40,000 characters is about 7,000 words, which is longer than any summary or briefing note
    /// this pane exists to show. Past that the document is a file, not a note, and the footer says
    /// where to read it whole.
    static let renderLimit = 40_000

    /// `prefix` on a `String` is O(limit), not O(source) — the 10 MB never gets walked.
    private var visible: String { String(source.prefix(Self.renderLimit)) }

    /// `utf8.count` and not `count`: the second walks grapheme clusters, which on 10 MB is an
    /// eighth of a second — every time `body` runs. The first is stored on a native String.
    private var overflowed: Bool { source.utf8.count > Self.renderLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(visible).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(Self.headingFont(level))
                        .padding(.top, 6)
                case .bullet(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // A fixed measure so an ordered list's numbers line up on the period and
                        // its text on a single left edge, the way a list is supposed to read.
                        Text(marker)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 2)
                case .paragraph(let text):
                    Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                case .blank:
                    Color.clear.frame(height: 4)
                }
            }
            if overflowed { overflowNotice }
        }
        .font(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Says the text is cut and names the one command that prints the whole thing. Without it the
    /// pane would simply stop mid-sentence, which is the same lie as showing nothing.
    private var overflowNotice: some View {
        Text("Showing first \(Self.renderLimit.formatted()) characters of \(source.utf8.count.formatted(.byteCount(style: .file))). Read the rest via CLI.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
    }

    /// An agent writes `##` far more often than `#`, so `##` has to be a heading you can see. Wave 3
    /// gave it `.headline`, which is body's own point size in a heavier weight — a heading that
    /// only differs in weight is not a heading, it is a bold sentence.
    static func headingFont(_ level: Int) -> Font {
        switch level {
        case ...1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        default: .headline
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    enum Block: Equatable {
        case heading(Int, String)
        /// The marker is rendered, not re-derived: `•` for an unordered item, `3.` for an ordered
        /// one, so an ordered list keeps its own numbering instead of being flattened to bullets.
        case bullet(marker: String, text: String)
        case paragraph(String)
        case blank
    }

    static func blocks(_ source: String) -> [Block] {
        var out: [Block] = []
        /// The block still taking continuation lines. Flushed by a blank line, a heading, or the
        /// start of another list item — the three things that end a paragraph in markdown.
        var pending: Block?

        func flush() {
            if let pending { out.append(pending) }
            pending = nil
        }

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flush()
                // One blank between blocks however many the source has, and none leading.
                if !out.isEmpty, out.last != .blank { out.append(.blank) }
                continue
            }
            if line.hasPrefix("#") {
                flush()
                let hashes = line.prefix { $0 == "#" }.count
                let text = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                out.append(.heading(hashes, text))
                continue
            }
            if let item = listItem(line) {
                flush()
                pending = .bullet(marker: item.marker, text: item.text)
                continue
            }
            // A soft line break: this line continues whatever block is open.
            switch pending {
            case .paragraph(let existing): pending = .paragraph(existing + " " + line)
            case .bullet(let marker, let text): pending = .bullet(marker: marker, text: text + " " + line)
            default: pending = .paragraph(line)
            }
        }
        flush()
        while out.last == .blank { out.removeLast() }
        return out
    }

    /// `- x`, `* x`, `+ x`, `1. x`, `2) x`. Ordered items keep their own number.
    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return ("•", String(line.dropFirst(marker.count)))
        }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return ("\(digits).", String(rest.dropFirst(2)))
    }
}

// MARK: - transcribing

private struct TranscribingDetailView: View {
    let meeting: Meeting
    let progress: Double?

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Transcribing \(meeting.title)")
                    .font(.headline)
                Text("Transcribing on-device. The meeting will appear under Needs write-up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 380)
            if let progress {
                ProgressView(value: progress).frame(maxWidth: 260)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ready / complete

private struct WrittenDetailView: View {
    let meeting: Meeting
    let segments: [TranscriptSegment]
    let issues: [TranscriptIssue]
    let notes: [Note]
    let command: String
    let enhancementNote: String?
    let folders: [Folder]
    let moveToFolder: (String?) -> Void
    let rename: (String) -> Void
    let saveSummary: (String) -> Void

    /// The segment a clicked note scrolled to, held so it can be highlighted for a moment.
    @State private var highlighted: Int64?
    /// The three sections the write-up outranks, each closed until asked for. Held here rather than
    /// inside each section so clicking a note can open the transcript it is about to scroll.
    @State private var showPreNotes = false
    @State private var showNotes = false
    @State private var showTranscript = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailHeader(title: meeting.title, subtitle: "", rename: rename)
                        // Chips rather than a grey run of `14 Aug 2026 · 14:53 · 8 min`. Each fact
                        // is its own object, and the last of them is a control: filing a meeting
                        // used to be reachable only by right-clicking its row in the list.
                        MeetingChips(
                            meeting: meeting, folders: folders, moveToFolder: moveToFolder
                        )
                    }

                    // Above the transcript section, and above everything else with it. The summary
                    // and the actions on this screen were written *from* the damaged transcript, so
                    // a warning that only appears once you have scrolled past them arrives after
                    // the reader has already believed them.
                    if !issues.isEmpty {
                        TranscriptIssueBanner(issues: issues)
                    }
                    if meeting.state == .ready {
                        AgentCommandCard(command: command, note: enhancementNote)
                    }
                    // The write-up, which now carries the actions inside it, as one surface and the
                    // tallest thing on the screen.
                    //
                    // It is what somebody opens a finished meeting *for* — the transcript is the
                    // evidence behind it and the notes are the raw material, and both used to sit
                    // above the fold at full height while the summary got a 360 pt slot they pushed
                    // off screen. They are still one click away, with their counts on the closed
                    // row so nothing is hidden silently; the write-up is the thing that is open.
                    //
                    // An editor rather than rendered markdown, and always, not behind an edit mode.
                    // A write-up with one wrong sentence in it used to mean going back to the CLI to
                    // fix it. This is the same editor the pre-notes field uses, so a summary the CLI
                    // rewrites while it is open is handled the one way this app handles that — and
                    // the actions in it are ticked by clicking the checkbox the editor draws over
                    // each `- [ ]`, which is one more edit to this same field.
                    //
                    // No height at all any more. It had `.frame(height: 520)` because the editor
                    // wrapped an `NSScrollView`, whose ideal height inside this `ScrollView` was
                    // arbitrary — and 520 pt then sliced a heading in half at the boundary and gave
                    // the page a second thing to scroll. The editor reports the height of its own
                    // laid-out document now, so the page is the only scrolling surface and the
                    // write-up ends where the writing ends.
                    SharedFieldEditor(
                        title: "Summary",
                        value: meeting.summary ?? "",
                        identity: "summary:\(meeting.id)",
                        placeholder: "Write summary or generate with an agent. Markdown supported.",
                        oversizeHint: "View or edit with `meetings show --summary` and `meetings summary set --file`.",
                        subject: "this write-up",
                        save: saveSummary,
                        titleShown: false
                    )
                    if !meeting.preNotes.isEmpty {
                        SecondarySection(title: "Pre-meeting notes", open: $showPreNotes) {
                            MarkdownText(source: meeting.preNotes)
                        }
                    }
                    if !notes.isEmpty {
                        SecondarySection(
                            title: "Your notes",
                            trailing: "\(notes.count) · click to jump",
                            open: $showNotes
                        ) {
                            ForEach(notes) { note in
                                NoteRow(note: note, active: highlighted != nil && highlighted == note.anchorSegmentID) {
                                    jump(to: note, proxy: proxy)
                                }
                            }
                        }
                    }
                    // Hidden rather than shown empty: a meeting with notes and no audio is legal
                    // and an empty "Transcript" heading would read as a failure.
                    if !segments.isEmpty {
                        SecondarySection(
                            title: "Transcript",
                            trailing: "\(segments.count) segments",
                            open: $showTranscript
                        ) {
                            // Said once, here, instead of on every segment.
                            if meeting.source != .imported {
                                ChannelLegend()
                            }
                            TranscriptView(
                                segments: segments,
                                singleChannel: meeting.source == .imported,
                                highlighted: highlighted
                            )
                        }
                    }
                }
                // One column, and everything on the screen shares its edge: the title, the chips,
                // the write-up, the actions under it and the three sections below them.
                //
                // Clamped *before* the inset and centred after it, so the leftover width of a wide
                // pane becomes margin either side rather than a longer line — the detail column was
                // giving the write-up 110 characters, and a measure that wide is why it read as a
                // text field. Narrower than the column and the clamp simply stops applying, so a
                // 500 pt pane is the pane's width minus the inset, as it always was.
                .frame(maxWidth: Self.documentWidth, alignment: .leading)
                .padding(detailInset)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// The write-up's measure plus the editor's own inset either side, so the document column and
    /// everything stacked with it are one width.
    static var documentWidth: CGFloat { SharedFieldEditor.column + 2 * SharedFieldEditor.editorInset }

    /// Clicking a note scrolls the transcript to its anchor. A note written before anyone
    /// spoke has no anchor at all, which is legal — it just has nowhere to jump to.
    private func jump(to note: Note, proxy: ScrollViewProxy) {
        guard let anchor = note.anchorSegmentID else { return }
        highlighted = anchor
        // The transcript is closed to begin with, and `scrollTo` a segment that is not laid out
        // does nothing at all — which from the outside is a note that has stopped working. Opening
        // it is not instant, so a jump that had to open it waits for the rows to exist.
        let wasOpen = showTranscript
        showTranscript = true
        Task {
            if !wasOpen { try? await Task.sleep(for: .milliseconds(150)) }
            withAnimation { proxy.scrollTo(anchor, anchor: .center) }
            try? await Task.sleep(for: .seconds(2))
            if highlighted == anchor { highlighted = nil }
        }
    }

}

/// What the meeting *was*, as chips under its title: when, how long, who, and which folder it is in.
///
/// A run of grey text separated by interpuncts said the same things and was one object — you read it
/// or you did not. Each fact is its own now, and the last one is a control rather than a statement:
/// filing a meeting was previously reachable only by right-clicking its row back in the list, which
/// is not where you are when you have just read the write-up and decided where it belongs.
private struct MeetingChips: View {
    let meeting: Meeting
    let folders: [Folder]
    let moveToFolder: (String?) -> Void

    /// Two names, then a count. A nine-person meeting is not nine chips.
    private static let inlineAttendees = 2

    var body: some View {
        HStack(spacing: 6) {
            if let date = meeting.sortDate {
                chip(Format.detailDate(date))
                chip(Format.timeOfDay(date))
            }
            if let length = Format.duration(from: meeting.startedAt, to: meeting.endedAt) {
                chip(length)
            }
            // Not decoration: audio that the retention sweep has purged is the difference between a
            // transcript you can check and one you have to take on trust.
            if meeting.audioPurgedAt != nil {
                chip("Audio deleted")
            }
            // By index, as everywhere else a list of attendees is drawn: two people can share a
            // display name, and a duplicate id is a row SwiftUI quietly drops.
            ForEach(Array(meeting.attendees.prefix(Self.inlineAttendees).enumerated()), id: \.offset) {
                chip($0.element.displayName)
            }
            if meeting.attendees.count > Self.inlineAttendees {
                chip("+\(meeting.attendees.count - Self.inlineAttendees) more")
            }
            folderChip
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// The same destinations, and the same `move`, as the meeting row's context menu — one filing
    /// path, not a second one that drifts.
    private var folderChip: some View {
        Menu {
            Button("Unfiled") { moveToFolder(nil) }
                .disabled(meeting.folderID == nil)
            ForEach(folders) { folder in
                Button(folder.name) { moveToFolder(folder.id) }
                    .disabled(meeting.folderID == folder.id)
            }
        } label: {
            chip(current?.name ?? "Move to Folder", symbol: current == nil ? "plus" : "folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // With no folders in the store the only destination is Unfiled, and an unfiled meeting is
        // already there — the same rule the context menu applies.
        .disabled(folders.isEmpty && meeting.folderID == nil)
    }

    private var current: Folder? {
        meeting.folderID.flatMap { id in folders.first { $0.id == id } }
    }

    private func chip(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(.separator))
        .contentShape(.capsule)
    }
}

/// One live note in the written-up view. Clicking it is the whole point, so it looks clickable.
private struct NoteRow: View {
    let note: Note
    let active: Bool
    let jump: () -> Void

    var body: some View {
        Button(action: jump) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.clock(milliseconds: note.tOffsetMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 46, alignment: .trailing)
                Text(note.text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if note.anchorSegmentID != nil {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                active ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary.opacity(0.35)),
                in: .rect(cornerRadius: 6, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(note.anchorSegmentID == nil)
    }
}

/// A section the write-up outranks: closed to begin with, and saying on the closed row how much is
/// inside it.
///
/// The count is the point. A disclosure triangle over a heading with nothing beside it is how a
/// hundred-and-forty-segment transcript comes to look like an empty section somebody can ignore,
/// and a section nobody opens is a section that may as well have been deleted.
private struct SecondarySection<Content: View>: View {
    let title: String
    var trailing: String?
    @Binding var open: Bool
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            SectionHeader(title: title, trailing: trailing)
                // The whole row, not just the triangle: a caption-sized label beside a small
                // triangle is a target you have to aim at.
                .contentShape(.rect)
                .onTapGesture { withAnimation { open.toggle() } }
        }
    }
}

/// The one-click copy of the exact command. In the default manual mode nothing writes a
/// summary on its own, and the gap between "I should write this up" and "what was that command
/// again" is where fifty transcripts go to die.
private struct AgentCommandCard: View {
    let command: String
    let note: String?

    @State private var copied = false

    /// Held rather than recomputed in `body`: `body` reruns on every copy, every enhancement note
    /// and every parent redraw, and `CLIInstall.status()` goes to the filesystem each time.
    @State private var prerequisites: [Prerequisite] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run this command in your agent session:")
                .font(.callout)
                .foregroundStyle(.secondary)
            // Above the command rather than under the Copy button. Reading and copying is one
            // motion, so a warning placed after it is read in the terminal instead — as
            // "meetings: command not found", with nothing there tying it back to the setup step
            // that was skipped.
            if !prerequisites.isEmpty {
                PrerequisiteNotice(prerequisites: prerequisites) {
                    prerequisites = Prerequisites.forAgentCommand()
                }
            }
            // No line limit, and the button is below rather than beside it. `.lineLimit(2)` on a
            // monospaced identifier truncated mid-UUID at a narrow detail column: the command on
            // screen was silently not the command, and the id is the one part of it you cannot
            // reconstruct by eye.
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.background.secondary, in: .rect(cornerRadius: 6, style: .continuous))
            HStack {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copy()
                }
                .labelStyle(.titleAndIcon)
                Spacer(minLength: 0)
            }
            // Mode B ran and something came back. Silence here would leave the user watching a
            // meeting that never changes, with no idea their agent exited 127 twenty minutes ago.
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10, style: .continuous))
        .onAppear { prerequisites = Prerequisites.forAgentCommand() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
