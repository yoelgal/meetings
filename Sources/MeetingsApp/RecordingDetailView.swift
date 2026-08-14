import MeetingsCore
import SwiftUI

/// The `recording` detail: live transcript on the left, note editor on the right, with the
/// recording controls pinned along the bottom.
///
/// A note commits on newline and anchors to the transcript position at that instant. The anchor is
/// taken from `RecordingController.elapsedMs` — the recording clock, which keeps running even when
/// the recogniser is a second behind — and the store resolves it to the segment covering that
/// offset using the same rule the batch pass will use to remap it afterwards. So a note does not
/// move when the final transcript replaces the live one.
struct RecordingDetailView: View {
    let model: AppModel
    let meeting: Meeting

    /// Below this the two panes cannot both hold a readable measure, so they stack instead of
    /// sitting side by side. It is the sum of the two minimums plus the divider, and it is
    /// deliberately under the ~580 pt the detail column gets in the default 1180 pt window — that
    /// window keeps the side-by-side layout it has always had.
    private static let sideBySideWidth: CGFloat = 500

    var body: some View {
        // The bar is a sibling in a VStack, not a `.safeAreaInset`, and measurably so: a safe-area
        // inset does not shrink the content's *frame*, it only narrows the safe area that scrolling
        // views read. `HSplitView` is an NSSplitView underneath and lays its children out at full
        // height regardless, which put the note field bodily behind the bar — the exact overlap the
        // inset was supposed to remove. A sibling cannot overlap anything by construction.
        VStack(spacing: 0) {
            // Measured rather than declared. `HSplitView`'s child `minWidth`s propagate all the way
            // out to the window's own minimum size, which is how starting a recording used to force
            // a half-screen window out to 1030 pt — on the one screen whose entire premise is that
            // your main window is buried behind the call. A `GeometryReader` reports flexible in
            // both axes, so nothing in here can push the window wider than the user put it; the
            // panes simply stack when there is no room to sit side by side.
            GeometryReader { geometry in
                if geometry.size.width < Self.sideBySideWidth {
                    VStack(spacing: 0) {
                        transcriptPane
                        Divider()
                        notesPane.frame(minHeight: 150, maxHeight: 260)
                    }
                } else {
                    HSplitView {
                        transcriptPane.frame(minWidth: 260, idealWidth: 520)
                        notesPane.frame(minWidth: 220, idealWidth: 340)
                    }
                }
            }

            RecordingBar(
                title: meeting.title,
                startedAt: model.recordingStart(for: meeting),
                levels: model.recording.levels
            ) {
                Task { await model.stopRecording() }
            }
        }
    }

    private var transcriptPane: some View {
        LiveTranscriptPane(
            segments: model.recording.meetingID == meeting.id
                ? model.recording.liveSegments
                : model.segments,
            unavailable: model.recording.liveTranscriptionUnavailable,
            systemAudioUnavailable: model.recording.systemAudioUnavailable
        )
    }

    /// The same pane the floating panel hosts, over the same notes and the same clock. Only its
    /// address changes.
    @ViewBuilder
    private var notesPane: some View {
        let tab = model.effectiveNotesTab
        VStack(spacing: 0) {
            // Both, during the call. What you wrote before the meeting is the agenda you meant
            // to follow and the questions you meant to ask, and until this switch existed it
            // was unreachable for the whole call — the pane showed live notes and nothing else.
            //
            // It stays above the detached notice too. With one surface floating the other is still
            // in the window, and hiding the switch would strand the pane on the half that left.
            //
            // Full width with a rule under it, because it switches the whole pane below. Centred at
            // its natural size it read as a pill sitting on top of the section header rather than
            // the control that changes what the header describes, and with nothing between them the
            // two lines collided.
            NotesTabPicker(selection: Binding(
                get: { model.effectiveNotesTab },
                set: { model.notesTab = $0 }
            ))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            if model.notesPanelHolds(meeting, tab) {
                DetachedNotesNotice(what: tab == .liveNotes
                    ? "Your live notes"
                    : "Your pre-meeting notes") {
                    model.setNotesPanel(tab, open: false)
                }
            } else if tab == .liveNotes {
                LiveNotesPane(
                    notes: model.notes,
                    elapsedMs: { model.elapsedMs(for: meeting) },
                    popOut: { model.setNotesPanel(.liveNotes, open: true) }
                ) { text in
                    model.addLiveNote(text, to: meeting)
                }
            } else {
                // Spelled out rather than using a trailing closure: `save` and `popOut` are both
                // closures, and which one a trailing brace binds to is not worth having to
                // reason about at a call site.
                // Scrolled here, for the reason the panel is: the editor is the height of its
                // document now, and this pane is a fixed slice of a recording window.
                ScrollView {
                    PreNotesEditor(
                        meeting: meeting,
                        save: { model.savePreNotes(meetingID: meeting.id, text: $0) },
                        popOut: { model.setNotesPanel(.preNotes, open: true) }
                    )
                }
                // The inset the sibling pane carries internally. `LiveNotesPane` pads its own
                // content by 16 and `PreNotesEditor` does not, because its other home wraps it in
                // `detailInset`. Switching tabs therefore slid the section header and the editor
                // flush against the pane edge while the picker above them stayed indented.
                .padding(.horizontal, 16)
                .padding(.top, 4)
                // ...and the same 16 along the bottom, which was missing: the editor ran flush into
                // the recording bar while its other three edges were inset, so the pane looked
                // cropped rather than padded.
                .padding(.bottom, 16)
            }
        }
    }
}

private struct LiveTranscriptPane: View {
    let segments: [TranscriptSegment]
    let unavailable: String?
    let systemAudioUnavailable: String?

    var body: some View {
        VStack(spacing: 0) {
            // A degraded channel is news whether or not anything has been said yet, so it stays
            // pinned above whatever the pane is showing.
            if let systemAudioUnavailable {
                Notice(
                    symbol: "speaker.slash",
                    text: "Only your microphone is being recorded. Everyone else on the call will "
                        + "be missing from the transcript."
                )
                // The value is `String(describing:)` of an error upstream — a Swift type dump,
                // which tells somebody mid-recording nothing they can act on. It stays on the
                // tooltip because it is the only thing that names which failure this was when a
                // half-empty transcript gets reported afterwards.
                .help(systemAudioUnavailable)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            if segments.isEmpty {
                // Centred, not a banner clinging to the top of an otherwise empty pane. Before the
                // first word this *is* the pane, and every other empty state in the app is centred.
                EmptyStateView(
                    symbol: unavailable == nil ? "waveform" : "exclamationmark.triangle",
                    title: unavailable == nil ? "Listening" : "No live transcript",
                    message: unavailable.map {
                        "The live transcript is unavailable: \($0). The recording will be "
                            + "transcribed when you stop."
                    } ?? "Words appear here a moment after they are said. The final transcript "
                        + "is made when you stop."
                )
            } else {
                transcript
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ChannelLegend()
                    TranscriptView(segments: segments)
                    // A zero-height anchor at the very end: scrolling to the last segment would
                    // stop with it at the top of the view rather than following the conversation.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: segments.count) {
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private static let bottomAnchor = "live-transcript-bottom"
}

private struct Notice: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8, style: .continuous))
    }
}

/// The live note field. Hosted by the recording detail pane and, unchanged, by the floating panel —
/// one editor over one `AppModel`, because two editors over one field is how a note goes missing.
struct LiveNotesPane: View {
    let notes: [Note]
    /// Read every second rather than passed as a number: a note field showing "12:04" while the
    /// clock beside it says "18:24" is not a smaller bug for being a cosmetic one.
    let elapsedMs: @MainActor () -> Int
    /// Nil inside the panel, where the content is already out.
    var popOut: (() -> Void)?
    /// True inside the panel. It gates one screenshot seam and nothing else.
    var inPanel = false
    let commit: (String) -> Void

    @State private var draft = ""
    @State private var seeded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(notes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let popOut { PopOutButton(action: popOut) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(notes) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Format.clock(milliseconds: note.tOffsetMs))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text(note.text)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(note.id)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: notes.count) {
                    if let last = notes.last?.id { withAnimation { proxy.scrollTo(last) } }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                // Return commits; Option-Return puts in a line break. That is what "commits on
                // newline" has to mean for a field you can also write two sentences in.
                TextField("Note", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(commitDraft)
                    // Return is how you file a note deliberately. It cannot be the *only* way one
                    // gets saved: a half-written note with the caret still in it is the most
                    // valuable thing on screen, and pressing Stop threw it away silently — the
                    // draft lived in this view's `@State` and the view is replaced the moment the
                    // meeting stops recording. Clicking Stop moves focus off the field first, so
                    // filing it here is what keeps the note's timestamp honest: the recording clock
                    // is still running at this point, and by `onDisappear` it reads zero.
                    .onChange(of: focused) { wasFocused, _ in
                        if wasFocused { commitDraft() }
                    }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    // "Return files this note at 23:33" read first as a sentence about files.
                    Text("Press Return to save this note at \(Format.clock(milliseconds: elapsedMs()))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Never in the panel: putting the caret in a floating window would take the keyboard
            // from whatever the operator is actually doing.
            if !inPanel { focused = true }
            // Screenshot seam, inert unless the environment variable is set — see
            // `Appearance.panelNote`. It enters the same `commitDraft()` a Return keystroke does.
            if inPanel, !seeded, let text = Appearance.panelNote {
                seeded = true
                draft = text
                commitDraft()
            }
        }
        // The backstop, for the paths where focus never moved: the window closing, the notes
        // popping out into the panel, a meeting ending from the menu bar while the caret sat here.
        // It files the text late rather than not at all — see `commitDraft`.
        .onDisappear(perform: commitDraft)
    }

    private func commitDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commit(text)
        draft = ""
    }
}

/// The recording controls, as a bottom bar rather than a floating capsule.
///
/// Wave 1 drew this as glass floating over the content and it measured **1.02:1** against the pane
/// in light mode — a control cluster with no discernible edge.
///
/// Its separation here is structural rather than chromatic, and deliberately: measured on this
/// machine, *no* macOS chrome colour reaches 3:1 against a content pane in both schemes
/// (`windowBackgroundColor` 1.00:1 light, `underPageBackgroundColor` 1.13:1 dark), because the
/// platform separates chrome from content with a hairline and an edge, not with a fill. So this is
/// a full-width bar at the window edge, with a divider above it, and content that ends above the
/// divider instead of sliding under it. The recording state *also* lives in the toolbar — see
/// `RecordingToolbarStatus` — which is the other half of where macOS puts a transport.
private struct RecordingBar: View {
    let title: String
    let startedAt: Date?
    let levels: [Channel: Float]
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    RecordingDot()
                    // A timer view rather than observed state: elapsed time is derived from the
                    // clock, so nothing posts a change for it to react to.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsed(at: context.date))
                            .font(.title3.monospacedDigit())
                            .contentTransition(.numericText())
                    }
                }
                Divider().frame(height: 26)
                VStack(alignment: .leading, spacing: 5) {
                    LevelMeter(channel: .mic, level: levels[.mic] ?? 0)
                    LevelMeter(channel: .system, level: levels[.system] ?? 0)
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        // The bar material alone measures 1.00:1 against the pane in a captured window, because
        // `.bar` *is* the pane's material with nothing behind it — and no macOS chrome colour
        // clears 3:1 against a content pane in both schemes (measured on this machine:
        // windowBackground 1.00:1 in both, underPageBackground 2.96:1 light but 1.13:1 dark). The
        // platform does not separate chrome from content with a fill, so neither do we; the wash
        // on top of the material is the tonal step, the divider above is the edge, and the window
        // edge below closes it.
        .background {
            Rectangle()
                .fill(.quaternary.opacity(0.4))
                .background(.bar)
        }
    }

    private func elapsed(at now: Date) -> String {
        guard let startedAt else { return Format.clock(milliseconds: 0) }
        return Format.clock(milliseconds: Int(now.timeIntervalSince(startedAt) * 1000))
    }
}

/// The red dot, breathing slowly. The one piece of motion in the app, and it earns itself: it is
/// the difference between "recording" and a screenshot of "recording".
struct RecordingDot: View {
    var size: CGFloat = 9

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate) % 2 == 0
            Circle()
                .fill(.red)
                .frame(width: size, height: size)
                .opacity(on ? 1 : 0.45)
                .animation(.easeInOut(duration: 0.8), value: on)
        }
    }
}

/// One channel's input level.
///
/// Wave 2 drew a continuous 4 pt grey track whose fill was zero-width at silence, with a 40 pt grey
/// word beside it — which is exactly a disabled progress bar, on the one screen whose job is proving
/// audio is arriving. The problem is not only the styling: a *continuous* bar at silence is an empty
/// bar, and silence is what this meter shows most of the time.
///
/// So it is segmented, the way every hardware meter and Apple's own Audio MIDI Setup are. An unlit
/// segment is still visibly a segment, so the instrument reads as an instrument before a single
/// sample arrives; the scale the critic asked for is the segments themselves. The floor is one lit
/// segment, so a live-but-silent channel is distinguishable from a dead one. The channel is named by
/// its symbol in its own colour — the transcript's two-colour key again, at a tenth of the width the
/// word took.
struct LevelMeter: View {
    let channel: Channel
    let level: Float

    var segments = 14

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: ChannelStyle.symbol(channel))
                .font(.caption2)
                .foregroundStyle(ChannelStyle.color(channel))
                .frame(width: 13, alignment: .center)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { index in
                    Capsule()
                        .fill(index < lit ? ChannelStyle.rule(channel) : AnyShapeStyle(.quaternary))
                        .frame(width: 3, height: 8)
                }
            }
            .animation(.default, value: level)
        }
        .help("\(channel.label) input level")
    }

    /// At least one, so silence still reads as a live channel rather than an absent one.
    private var lit: Int {
        max(1, Int((CGFloat(min(max(level, 0), 1)) * CGFloat(segments)).rounded()))
    }
}
