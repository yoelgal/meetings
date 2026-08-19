import AppKit
import MeetingsCore
import SwiftUI

/// The floating notes panels.
///
/// Scope added mid-run, and a better answer to a problem already named in its own words: the
/// menu bar item "exists because during a call your main window is behind Zoom". So does everything
/// else in the window — including the two things you actually write during a call.
///
/// There are **two panels, one per surface**, and either or both can be on screen. One panel showing
/// one of two meant that reaching the agenda you wrote before the call cost you sight of the notes
/// you were taking during it, which is the one moment both matter at once. Each hosts the same
/// `PreNotesEditor` or `LiveNotesPane` the detail column hosts, over the same `AppModel`, so a note
/// typed here anchors through the recording clock exactly as one typed in the window does and shows
/// up in the window the instant it commits. Popping out is a change of address, not a fork.
enum NotesPanel {
    /// The `UtilityWindow` scene id, one per surface. `UtilityWindow` is NSPanel-backed, which is
    /// what keeps these out of the app's main-window slot.
    static func sceneID(_ tab: NotesTab) -> String { "notes-panel-\(tab.rawValue)" }

    static let defaultSize = CGSize(width: 380, height: 470)

    // MARK: - Persistence

    /// Open/closed lives in UserDefaults rather than the settings table because it is window state,
    /// which is what UserDefaults is for and where `setFrameAutosaveName` already puts the frame.
    private static func openKey(_ tab: NotesTab) -> String { "MeetingsNotesPanelOpen.\(tab.rawValue)" }

    /// What the single panel used, before there were two. Read once below; never written again.
    private static let legacyOpenKey = "MeetingsNotesPanelOpen"

    /// A frame per panel, so the second one to open does not land exactly on top of the first and
    /// then drag both around as one remembered rectangle.
    private static func frameName(_ tab: NotesTab) -> String { "MeetingsNotesPanel.\(tab.rawValue)" }

    /// Nil during a forced run, which suppresses frame persistence for the same reason
    /// `Appearance.windowAutosaveName` does: a screenshot run must not leave the operator's panel
    /// somewhere he did not put it.
    static func frameAutosaveName(_ tab: NotesTab) -> String? {
        Appearance.notesPanelForced == nil ? frameName(tab) : nil
    }

    static var initialOpenTabs: Set<NotesTab> {
        if let forced = Appearance.notesPanelForced { return forced }
        return Set(NotesTab.allCases.filter(initialOpenState))
    }

    private static func initialOpenState(_ tab: NotesTab) -> Bool {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: openKey(tab)) as? Bool { return stored }
        // Nobody has a per-panel key yet on an installed copy — they have the one key the single
        // panel wrote. Dropping it would close, on the next launch, a panel the user had left open
        // and never asked to close, so it seeds the pre-notes side: that is the half that is
        // meaningful with nothing recording, which is the state a user quits the app in.
        return tab == .preNotes && defaults.bool(forKey: legacyOpenKey)
    }

    static func persist(open: Bool, tab: NotesTab) {
        guard Appearance.notesPanelForced == nil else { return }
        UserDefaults.standard.set(open, forKey: openKey(tab))
    }

    // MARK: - Capture

    /// `.none` is the mechanism behind "hide from screen sharing" — the window's contents become
    /// unreadable to every other process, which is what makes the panel absent from a Zoom share.
    /// Apple's own header warns it removes the window from screenshots and Mission Control too,
    /// which is why the setting says so in as many words.
    ///
    /// `MEETINGS_PANEL_CAPTURABLE=1` forces `.readOnly`, because `screencapture` is exactly what
    /// `.none` defeats and there is otherwise no way to photograph this panel at all. Inert unless
    /// set, and it is not the configuration that ships.
    static func sharingType(hiddenFromCapture: Bool) -> NSWindow.SharingType {
        if Appearance.notesPanelCapturable { return .readOnly }
        return hiddenFromCapture ? .none : .readOnly
    }

    // MARK: - First placement

    /// Where a panel goes the very first time, before it has a remembered frame: the trailing edge
    /// of the app's own window. The screen corner AppKit would otherwise pick is wherever the user
    /// happens to be working.
    @MainActor
    static func place(_ window: NSWindow, _ tab: NotesTab) {
        guard let host = NSApp.windows.first(where: {
            !($0 is NSPanel) && $0.isVisible && $0.frame.width > 400
        }) else { return }
        var frame = window.frame
        // Side by side, live notes inboard of pre-notes. Both panels can be open at once, and a
        // first launch that put the second one exactly where the first one is reads as a panel that
        // failed to open.
        let column: CGFloat = tab == .preNotes ? 0 : 1
        frame.origin = CGPoint(
            x: host.frame.maxX - frame.width - 24 - column * (frame.width + 12),
            y: host.frame.maxY - frame.height - 24
        )
        // A narrow host window near the left of the display puts the inboard column past the edge,
        // and a panel with no title bar showing cannot be dragged back from off screen.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(frame.origin.x, visible.minX + 12)
        }
        window.setFrame(frame, display: false)
    }
}

/// The two settings rows, keyed for what they do rather than for how they work, and stored in the
/// same `settings` table as everything else rather than in this window's private state.
///
/// `meetings config` will not reach them yet: it validates against a known-key list in
/// `MeetingsCore/Models/Settings.swift`, which this unit does not own. Adding the two keys there is
/// the whole change — reported rather than made.
extension SettingKey {
    static let notesPanelHiddenFromCapture = SettingKey("panel.hideFromScreenSharing")
    static let notesPanelFloats = SettingKey("panel.keepAboveOtherApps")
}

// MARK: - The panel

struct NotesPanelView: View {
    @Bindable var model: AppModel
    /// Which surface this panel *is*. It is fixed for the life of the window — there is one panel
    /// per surface now, so the panel has nothing to switch between and no picker in it.
    let tab: NotesTab

    /// `.key` is the window being typed into. That is the whole focus model here: the panel firms
    /// up when you are writing in it and fades back when you are not, because during a call you
    /// want to read the person, not your notes.
    @Environment(\.controlActiveState) private var controlState
    @Environment(\.dismiss) private var dismiss

    private var writing: Bool { controlState == .key || Appearance.notesPanelWriting }

    /// One shape for the glass and for the scrim that sits on it, so the two cannot drift apart.
    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(14)
        // A finite ideal in both axes. Without it the note list's flexible height reads as an
        // infinite ideal and every launch that restores a remembered frame re-stretches the panel
        // to the full height of the display.
        .frame(
            minWidth: 280, idealWidth: NotesPanel.defaultSize.width, maxWidth: .infinity,
            minHeight: 240, idealHeight: NotesPanel.defaultSize.height, maxHeight: .infinity,
            alignment: .topLeading
        )
        // Liquid Glass over a window with no background of its own, so the material samples what is
        // actually behind it — during a call, the other person's face.
        //
        // The scrim varies, the material never does. Wave 3 wrote `.opacity(writing ? 1 : 0.6)`
        // *outside* `.glassEffect`, which fades the material itself: at rest the panel became a
        // 60%-alpha wash over an **unblurred** backdrop, so 40% of the raw video punched straight
        // through and collided with the notes. Blur is the whole reason the notes stay readable
        // over somebody's face, so it is now unconditional, and "firms up when you type" is a fill
        // between the glass and the content — the layer that is *supposed* to come and go.
        .background(Self.shape.fill(.background.opacity(writing ? 0.34 : 0.06)))
        .glassEffect(.regular, in: Self.shape)
        .animation(.easeInOut(duration: 0.18), value: writing)
        .background(NotesPanelChrome(
            tab: tab,
            floats: model.notesPanelFloats,
            hiddenFromCapture: model.notesPanelHiddenFromCapture
        ))
        // Outermost, so the glass fills the window rather than stopping at the title bar's safe
        // area and leaving the header floating over nothing.
        .ignoresSafeArea()
        // SwiftUI presents a `UtilityWindow` at launch whatever `.defaultLaunchBehavior` says, so
        // the remembered state has the last word: a panel the user closed stays closed.
        .task { if !model.notesPanelOpen(tab) { dismiss() } }
        // Closing the panel from its own control has to mean the same thing as closing it from the
        // menu, including across the next launch.
        .onDisappear { model.setNotesPanel(tab, open: false) }
    }

    /// The clock and the live note field both hang off this one question, so they cannot disagree
    /// about whether a call is running.
    private func recording(_ meeting: Meeting) -> Bool {
        model.displayState(for: meeting) == .recording
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Which panel this is, above the meeting it is holding. Both panels are the same
            // titleless glass slab, and with the two of them floating over a call the meeting title
            // alone does not say which one you are about to type into.
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.notesPanelMeeting?.title ?? "No meeting selected")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // The clock belongs to the notes that are stamped with it, so it stays in the live-notes
            // panel rather than being repeated in both.
            if tab == .liveNotes, let meeting = model.notesPanelMeeting, recording(meeting) {
                HStack(spacing: 5) {
                    RecordingDot(size: 7)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Format.clock(milliseconds: model.elapsedMs(for: meeting)))
                            .font(.callout.monospacedDigit())
                            .contentTransition(.numericText())
                    }
                }
            }
            Button {
                model.setNotesPanel(tab, open: false)
            } label: {
                // The system's own picture-in-picture pair. A floating panel over a call *is*
                // picture-in-picture, and the two arrow symbols this used read as resize handles.
                Image(systemName: "pip.exit")
            }
            .buttonStyle(.borderless)
            .help("Put these notes back in the window")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .preNotes:
            if let meeting = model.notesPanelMeeting {
                // The panel scrolls, because the editor inside it does not any more: it is as tall
                // as its document, and a document longer than this small floating window has to have
                // somewhere to go. One scrolling surface, here as in the main window.
                ScrollView {
                    PreNotesEditor(meeting: meeting) { text in
                        model.savePreNotes(meetingID: meeting.id, text: text)
                    }
                }
            } else {
                hint("Pick a meeting in the main window and its pre-notes appear here.")
            }
        case .liveNotes:
            // A live note is stamped with the recording clock, and with nothing recording that clock
            // reads 00:00 — so a note field here would file everything you wrote at the start of a
            // call that never happened. The panel says that instead, and stays open while it says
            // it: closing itself would move a panel the user deliberately positioned before the
            // call, and going blank would look like the notes had been lost. A finished meeting's
            // notes are not shown either; they are in the window beside the transcript they anchor
            // into, and this panel is somewhere to write, not somewhere to read.
            if let meeting = model.notesPanelMeeting, recording(meeting) {
                LiveNotesPane(
                    notes: model.panelNotes,
                    elapsedMs: { model.elapsedMs(for: meeting) },
                    inPanel: true
                ) { text in
                    model.addLiveNote(text, to: meeting)
                }
            } else {
                hint("""
                    Live notes are stamped with the recording clock, so they start when the \
                    recording does. Press Start recording and type here.
                    """)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Everything the panel needs that SwiftUI has no scene modifier for: the collection behaviour that
/// puts it over another app's full-screen window, the non-activating style mask that stops a click
/// on it sending Chrome behind, the clear background the glass needs, and the sharing type that
/// keeps it out of a screen share. Every one of these was measured on this machine first — see
/// `scratchpad/float-probe`.
private struct NotesPanelChrome: NSViewRepresentable {
    /// Which panel this is. Only the remembered frame, the first placement and the diagnostics line
    /// differ by it — everything else here is what makes a panel a panel, and both get all of it.
    let tab: NotesTab
    let floats: Bool
    let hiddenFromCapture: Bool

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // A view has no window until it is in the hierarchy, which is one runloop turn away.
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            // It is a sticky note: it stays where it was put, across launches.
            var restored = false
            if let name = NotesPanel.frameAutosaveName(tab) {
                restored = window.setFrameUsingName(name)
                window.setFrameAutosaveName(name)
            }
            if !restored {
                window.setContentSize(NotesPanel.defaultSize)
                NotesPanel.place(window, tab)
            }
            apply(to: window)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The two settings rows change the live panel, not the next one.
        if let window = nsView.window { apply(to: window) }
    }

    private func apply(to window: NSWindow) {
        // Over another app's full-screen window, and on whichever Space you switch to.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Otherwise the panel vanishes the moment you click back into the call.
        window.hidesOnDeactivate = false
        // The glass has nothing to sample through an opaque window.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        // No traffic lights. The glass slab is the whole window, and the header's own control —
        // which says what it does — is the one way back into the window.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.sharingType = NotesPanel.sharingType(hiddenFromCapture: hiddenFromCapture)
        if let panel = window as? NSPanel {
            // Clicking the panel must not deactivate the app behind it.
            panel.styleMask.insert(.nonactivatingPanel)
            panel.becomesKeyOnlyIfNeeded = true
            // `isFloatingPanel` is itself a level setter, so it has to be set before the level and
            // it has to follow the setting — otherwise "keep above other apps" cannot be turned off.
            panel.isFloatingPanel = floats
        }
        window.level = floats ? .floating : .normal
        if Appearance.notesPanelDiagnostics {
            NotesPanelDiagnostics.report(window, tab)
        }
    }
}

// MARK: - The pop-out control, and what the window says once the content has gone

/// Which of a meeting's two note surfaces this is. They are different documents, not two views
/// of one: pre-notes are a document you write and edit, live notes are timestamped entries anchored
/// into the transcript.
enum NotesTab: String, CaseIterable, Identifiable {
    case preNotes, liveNotes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .preNotes: "Pre-notes"
        case .liveNotes: "Live notes"
        }
    }

    /// For the middle of a sentence, as in "Float my pre-notes".
    var phrase: String {
        switch self {
        case .preNotes: "pre-notes"
        case .liveNotes: "live notes"
        }
    }
}

/// The switch between them, in the window's own pane — one pane there still shows one of two. The
/// floating panels do not have it: there is a panel per surface, and both can be on screen at once.
/// A segmented control rather than a menu: there are two of them, they are peers, and which one you
/// are looking at has to be legible at a glance mid-call.
struct NotesTabPicker: View {
    @Binding var selection: NotesTab

    var body: some View {
        Picker("Notes", selection: $selection) {
            ForEach(NotesTab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}

/// The control on a pane whose content can be detached. Small, quiet, and in the pane's own header
/// where the pane's other affordances are.
struct PopOutButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "pip.enter")
        }
        .buttonStyle(.borderless)
        .help("Float these notes above your other apps")
    }
}

/// What a pane shows once its content is in the panel. Popping out should read as detaching, not as
/// opening a second thing, so the window says where the content went and offers to take it back.
struct DetachedNotesNotice: View {
    let tab: NotesTab
    let bringBack: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Your \(tab.phrase) are in the floating panel")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Bring them back", action: bringBack)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Diagnostics

/// `MEETINGS_PANEL_DIAGNOSTICS=1` prints the resolved window state to stdout. It exists because the
/// one requirement that cannot be photographed under the never-interrupt rule — floating over
/// another app's *native full screen* window — is decided entirely by two collection-behaviour
/// flags, and printing the resolved raw value is the honest substitute for a picture.
enum NotesPanelDiagnostics {
    @MainActor
    static func report(_ window: NSWindow, _ tab: NotesTab) {
        let behavior = window.collectionBehavior
        // The tab first: two panels can be up at once and every other field on this line — level,
        // collection behaviour, sharing type — is identical between them, so without it a run that
        // opened both prints two indistinguishable reports.
        print("""
            NOTES-PANEL tab=\(tab.rawValue) class=\(type(of: window)) \
            level=\(window.level.rawValue) \
            collectionBehavior=\(behavior.rawValue) \
            canJoinAllSpaces=\(behavior.contains(.canJoinAllSpaces)) \
            fullScreenAuxiliary=\(behavior.contains(.fullScreenAuxiliary)) \
            nonactivating=\(window.styleMask.contains(.nonactivatingPanel)) \
            hidesOnDeactivate=\(window.hidesOnDeactivate) \
            sharingType=\(window.sharingType.rawValue) \
            isOpaque=\(window.isOpaque) \
            styleMask=\(window.styleMask.rawValue) \
            fullSizeContent=\(window.styleMask.contains(.fullSizeContentView)) \
            frame=\(window.frame) contentLayout=\(window.contentLayoutRect) \
            windowNumber=\(window.windowNumber)
            """)
        for menu in NSApp.mainMenu?.items ?? [] {
            // Case-insensitive: the View menu's two items name the panels, and "Pre-notes" and
            // "Live notes" both spell it with a small n.
            for item in menu.submenu?.items ?? [] where item.title.localizedCaseInsensitiveContains("notes") {
                print("NOTES-PANEL menu item: \"\(item.title)\" in the \(menu.title) menu "
                    + "shortcut=⇧⌘\(item.keyEquivalent.uppercased()) enabled=\(item.isEnabled)")
            }
        }
        fflush(stdout)
    }
}
