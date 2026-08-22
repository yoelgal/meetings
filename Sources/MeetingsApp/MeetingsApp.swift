import AppKit
import MeetingsCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MeetingsApp: App {
    /// What the window opens at, and what onboarding puts it back to when it is done with it.
    static let defaultWindowSize = CGSize(width: 1180, height: 780)

    /// The store is opened here, synchronously, before the first frame: it is a local SQLite file
    /// and a migration check, and a window that appears empty and then fills in is worse than one
    /// that appears correct. Anything genuinely slow — model downloads, the audio engine — stays
    /// off this path (cold launch to a usable window under a second).
    @NSApplicationDelegateAdaptor(MeetingsAppDelegate.self) private var appDelegate
    private var launch: Launch { appDelegate.launch }

    var body: some Scene {
        Window("Meetings", id: "main") {
            Group {
                switch launch {
                case .ready(let model):
                    RootView(model: model)
                case .unavailable(let error):
                    StoreUnavailableView(error: error)
                        .windowGlass()
                }
            }
            .preferredColorScheme(Appearance.override)
            .background(WindowFrame(autosaveName: Appearance.windowAutosaveName))
        }
        .defaultSize(width: Self.defaultWindowSize.width, height: Self.defaultWindowSize.height)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .sidebar) {
                if case .ready(let model) = launch {
                    // One item per panel, because the two panels open and close independently.
                    // ⇧⌘N for the notes you wrote before the call, ⇧⌘L for the live ones, the
                    // letter each surface is named after, and neither is taken.
                    notesPanelItem(.preNotes, model, key: "n")
                    notesPanelItem(.liveNotes, model, key: "l")
                }
            }
            // ⌘K lives in a menu rather than on the toolbar button it opens: a key equivalent on a
            // button only fires while that button's window is key, and the notes panel is a window
            // you are meant to be typing in with the main one buried behind a call.
            CommandGroup(after: .textEditing) {
                if case .ready(let model) = launch {
                    Button("Search", systemImage: "magnifyingglass") { model.openSearchPalette() }
                        .keyboardShortcut("k")
                }
            }
            MarkdownFormattingCommands()
        }

        // The pop-outs, one per surface. `UtilityWindow` is NSPanel-backed, so neither takes the
        // app's main-window slot. Everything else — the floating level included — is set on the
        // backing NSWindow by `NotesPanelChrome`, because `.windowLevel(.floating)` as a scene
        // modifier re-asserts itself and leaves "Keep the notes panel above other apps" unable to
        // turn off.
        notesPanel(.preNotes)
        notesPanel(.liveNotes)

        // The remote control. Window style rather than menu style because it holds a text
        // field, and a quick note is the one thing you type without leaving your call.
        MenuBarExtra("Meetings", systemImage: menuBarSymbol) {
            if case .ready(let model) = launch {
                MenuBarContent(model: model)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            if case .ready(let model) = launch {
                SettingsView(model: model)
                    .preferredColorScheme(Appearance.override)
                    .windowGlass()
            }
        }
    }

    /// Both panels are the same window with a different surface in it, so they are built by one
    /// function rather than by two copies of a twenty-line modifier stack that would drift apart.
    private func notesPanel(_ tab: NotesTab) -> some Scene {
        // The scene title is what the Window menu and the accessibility hierarchy call it, and with
        // two of them "Notes" twice would name neither.
        UtilityWindow(tab.label, id: NotesPanel.sceneID(tab)) {
            if case .ready(let model) = launch {
                NotesPanelView(model: model, tab: tab)
                    .preferredColorScheme(Appearance.override)
            }
        }
        .defaultSize(width: NotesPanel.defaultSize.width, height: NotesPanel.defaultSize.height)
        // `.contentSize` — the utility-window default — would let the note list's flexible height
        // stretch the panel to the full height of the display, and `.contentMinSize` does the same
        // the moment a remembered frame is restored. The panel is a sticky note you resize; its
        // content does not get a vote on how big it is.
        .windowResizability(.automatic)
        // Each panel's open/closed state is ours to remember, not SwiftUI's — the app decides it
        // from that panel's own defaults key so the menu, the menu bar and the close button agree.
        // Still per scene: SwiftUI would otherwise restore both panels on every launch.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Drops the "Show <title>" item SwiftUI adds for every window scene. It opens the panel
        // behind the app's back — the remembered state would then close it again a frame later —
        // and the View menu already has an item per panel that goes through the model.
        .commandsRemoved()
    }

    /// The View menu's half of the same switch the menu bar offers, for when the window is in front.
    private func notesPanelItem(_ tab: NotesTab, _ model: AppModel, key: KeyEquivalent) -> some View {
        Button(model.notesPanelOpen(tab)
            ? "Put \(tab.label) Back in the Window"
            : "Float \(tab.label) Above Other Apps") {
            model.toggleNotesPanel(tab)
        }
        .keyboardShortcut(key, modifiers: [.command, .shift])
    }

    private var menuBarSymbol: String {
        if case .ready(let model) = launch { return model.menuBarSymbol }
        return "waveform"
    }

}

/// Either the app or a truthful explanation of why not. A store that will not open is not something
/// to crash over — the path may simply be unwritable.
enum Launch {
    case ready(AppModel)
    /// The error itself, not a sentence made from it. `MeetingsDatabase.open` already diagnoses
    /// every way this fails and throws a `StoreOpenError` that says what to do about it;
    /// interpolating `localizedDescription` here threw that away and put GRDB's raw text — SQL,
    /// and for a constraint failure the offending row — on screen instead.
    case unavailable(Error)

    @MainActor
    init() {
        do {
            // The store first: opening it is what diagnoses a home that is a file, a full volume or
            // a damaged database. `ensureDirectories` hits the same problems one step earlier and
            // reports them as whatever Foundation says about `mkdir`.
            let store = try MeetingStore()
            try Paths.ensureDirectories()
            self = .ready(AppModel(store: store))
        } catch {
            self = .unavailable(error)
        }
    }
}


/// Owns first-run: present the OLA wizard and keep the SwiftUI window off screen until setup
/// finishes. Traffic-light close quits; the next launch is still the wizard.
@MainActor
final class MeetingsAppDelegate: NSObject, NSApplicationDelegate {
    let launch = Launch()
    private weak var mainWindow: NSWindow?

    var needsOnboarding: Bool {
        if Appearance.panel?.name == "onboarding" { return true }
        if case .ready(let model) = launch { return model.showingOnboarding }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        cacheMainWindow()
        guard needsOnboarding, case .ready(let model) = launch else { return }
        hideMainWindows()
        OnboardingWindowController.shared.show(
            model: model,
            initialStep: Appearance.panel?.argument
        ) { [weak self] in
            self?.revealMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard needsOnboarding, case .ready(let model) = launch else { return true }
        hideMainWindows()
        OnboardingWindowController.shared.show(model: model, initialStep: Appearance.panel?.argument) { [weak self] in
            self?.revealMainWindow()
        }
        return false
    }

    private func cacheMainWindow() {
        mainWindow = NSApp.windows.first {
            $0.identifier?.rawValue != OnboardingWindowController.windowID && !($0 is NSPanel)
        }
    }

    private func hideMainWindows() {
        cacheMainWindow()
        mainWindow?.orderOut(nil)
    }

    func revealMainWindow() {
        if case .ready(let model) = launch {
            model.showingOnboarding = false
        }
        if mainWindow == nil { cacheMainWindow() }
        guard let window = mainWindow else { return }
        window.styleMask.insert(.resizable)
        window.setContentSize(MeetingsApp.defaultWindowSize)
        WindowGlass.apply(window, titleVisible: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Launch-time overrides, all inert unless the environment variable is set. They exist because the
/// window has to be photographed in a given state without ever being clicked or brought forward —
/// the same reason `MEETINGS_CALENDAR_FIXTURE` exists in `MeetingsCore`.
enum Appearance {
    private static func value(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// `MEETINGS_APPEARANCE=light|dark`. Scoped to this window: changing the system appearance to
    /// compare the two would change it for whoever is using the Mac.
    static var override: ColorScheme? {
        switch value("MEETINGS_APPEARANCE")?.lowercased() {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    /// `MEETINGS_SCOPE=needsWriteUp|all|upcoming|unfiled|folder:<id or name>`.
    static var scopeToken: String? { value("MEETINGS_SCOPE") }

    /// `MEETINGS_SELECT=<meeting state>` — select the first meeting in that state.
    static var select: MeetingState? {
        value("MEETINGS_SELECT").flatMap(MeetingState.init(rawValue:))
    }

    /// `MEETINGS_ONBOARDING=1` — show the wizard even on a store that has completed it.
    static var forceOnboarding: Bool { value("MEETINGS_ONBOARDING") == "1" }

    /// `MEETINGS_SEARCH=<query>` — open the ⌘K palette with that text in its field, exactly as if
    /// it had been typed. Typing it for real would mean taking the operator's keyboard. It moved
    /// from the toolbar field to the palette when the palette replaced the field; the variable is
    /// the same one because what it photographs — search, holding a query — is the same thing.
    static var search: String? { value("MEETINGS_SEARCH") }

    /// `MEETINGS_PANEL=settings[:tab]|menubar|onboarding[:step]` renders a surface that normally
    /// lives in its own window or a sheet *inside* the main window instead of the split view.
    ///
    /// This exists only so those surfaces can be photographed: `screencapture -l` needs a window
    /// id, and `shot.sh` picks the largest normal window of the process — which is always the main
    /// one, never a settings window or an attached sheet. Inert unless set, and it changes nothing
    /// about how any of those surfaces is built.
    /// `MEETINGS_PRENOTES_DRAFT=<text>` — start the pre-notes editor holding unsaved text, exactly
    /// as if it had just been typed. It exists to photograph the conflict path: proving
    /// "otherwise show an updated-externally banner" needs a *touched* field, and typing into the
    /// window would mean taking focus from whoever is using this Mac. It injects nothing a keystroke
    /// would not; every branch after it is the real one.
    static var preNotesDraft: String? { value("MEETINGS_PRENOTES_DRAFT") }

    /// `MEETINGS_IMPORT=<audio path>[|go]` — hand the window an audio file as if it had been
    /// dropped on it. Without `|go` it opens the same dialog a drop opens; with it, the import runs
    /// to completion. A pointer drag cannot be synthesised without taking the operator's mouse, so
    /// this enters the drop handler's own code path one step later and changes nothing about it.
    static var importFile: (url: URL, immediate: Bool)? {
        guard let raw = value("MEETINGS_IMPORT") else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        return (URL(fileURLWithPath: parts[0]), parts.count > 1 && parts[1] == "go")
    }

    static var panel: (name: String, argument: String?)? {
        guard let raw = value("MEETINGS_PANEL") else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }

    /// `MEETINGS_WINDOW=<width>x<height>` — open the window at exactly that size, and do not save
    /// it. A screenshot run has to show the same screen narrow and wide, and the only alternatives
    /// are resizing the window with the mouse or through the accessibility API: the first takes the
    /// operator's pointer, the second needs a permission nothing here may ask for.
    static var windowSize: CGSize? {
        guard let raw = value("MEETINGS_WINDOW") else { return nil }
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// Nil suppresses frame persistence, which is what a forced size wants — otherwise a run
    /// photographing the narrow layout would leave the window narrow for the next real launch.
    static var windowAutosaveName: String? {
        windowSize == nil ? "MeetingsMainWindow" : nil
    }

    /// `MEETINGS_PANEL_CAPTURABLE=1` — force the notes panel's `sharingType` to `.readOnly`.
    ///
    /// The shipped default is `.none`, which makes the panel unreadable to every other process —
    /// that is the whole point of "hide from screen sharing", and `screencapture` is one of the
    /// processes it defeats. Without this seam the panel cannot be photographed at all. **Every
    /// panel screenshot in this run was taken with it set**, which is a different configuration
    /// from the one that ships, and saying so is the point.
    static var notesPanelCapturable: Bool { value("MEETINGS_PANEL_CAPTURABLE") == "1" }

    /// `MEETINGS_NOTES_PANEL=1|0|pre|live` — which panels are open for this launch only, without
    /// persisting either the state or the frame. Same reason as `MEETINGS_WINDOW`: photographing a
    /// panel must not leave the operator's own panels open, or somewhere he did not put them.
    ///
    /// `1` and `0` predate the split into two panels and still mean all and none, so an existing
    /// invocation keeps working; `pre` and `live` name one, which is what photographing a single
    /// panel needs now that opening one no longer means the other is closed.
    static var notesPanelForced: Set<NotesTab>? {
        switch value("MEETINGS_NOTES_PANEL")?.lowercased() {
        case "1", "both": Set(NotesTab.allCases)
        case "0", "none": []
        case "pre", "pre-notes": [.preNotes]
        case "live", "live-notes": [.liveNotes]
        default: nil
        }
    }

    /// `MEETINGS_PANEL_NOTE=<text>` — commit that text through the panel's note field once, exactly
    /// as pressing Return in it would. It enters the real `commitDraft()` one step after the
    /// keystroke and changes nothing after that; typing it for real would mean taking the
    /// operator's keyboard, which nothing here may do.
    static var panelNote: String? { value("MEETINGS_PANEL_NOTE") }

    /// `MEETINGS_PANEL_WRITING=1` — render the panel in its focused, firmed-up state.
    ///
    /// The panel firms up when it is the key window, which is the same as saying "when you are
    /// typing in it". Making it key for real would put the operator's next keystroke into it, and
    /// nothing here may take focus — so this drives the same `writing` flag the key state drives,
    /// through the same code path. What it changes is the cause, never the rendering.
    static var notesPanelWriting: Bool { value("MEETINGS_PANEL_WRITING") == "1" }

    /// `MEETINGS_PANEL_DIAGNOSTICS=1` — print the panel's resolved AppKit window state to stdout.
    static var notesPanelDiagnostics: Bool { value("MEETINGS_PANEL_DIAGNOSTICS") == "1" }

    /// `MEETINGS_RECORDING_CHROME=1` — render the window as though *this process* were the one
    /// recording, without opening the microphone.
    ///
    /// Same reason as `notesPanelWriting`. Where the recording transport is drawn depends on
    /// `RecordingController.phase`, and the only way to move that phase for real is to start a
    /// capture — which on a freshly built, ad-hoc-signed bundle raises the microphone and screen
    /// recording dialogs, and nothing here may ask for a permission. This flips one input:
    /// "a recording is in progress". Every decision after it — which meeting is being recorded,
    /// whether the recording screen is the one on screen, and therefore whether the toolbar draws
    /// the transport at all — is the shipping logic, unchanged.
    static var forceRecordingChrome: Bool { value("MEETINGS_RECORDING_CHROME") == "1" }
}

/// Remembers where the window was and how big it was, across launches.
///
/// SwiftUI's `.defaultSize` is only a default, and nothing else in a `Window` scene persists the
/// frame, so wave 2's window opened at exactly 1180×780 forever no matter what you had resized it
/// to. `setFrameUsingName` / `setFrameAutosaveName` is AppKit's own mechanism for this and it does
/// not depend on state restoration, so it survives a crash and a force-quit as well as a clean one.
private struct WindowFrame: NSViewRepresentable {
    let autosaveName: String?

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // The view has no window until it is in the hierarchy, which is one runloop turn away.
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            if let size = Appearance.windowSize {
                window.setContentSize(size)
            } else if let autosaveName, window.frameAutosaveName != autosaveName {
                window.setFrameUsingName(autosaveName)
                window.setFrameAutosaveName(autosaveName)
            }
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// What the menu bar item shows: the remote control, plus the one control that reaches the
/// floating panel from a menu you can open with the main window buried behind Zoom — which is the
/// situation the panel exists for. Composed here rather than inside `MenuBarView` so the menu and
/// the screenshot seam that photographs it cannot drift apart.
struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarView(model: model)
            if model.isRecording {
                Divider()
                HStack(spacing: 8) {
                    floatButton(.preNotes)
                    floatButton(.liveNotes)
                }
                .padding(12)
            }
        }
        .frame(width: 280)
    }

    private func floatButton(_ tab: NotesTab) -> some View {
        let floating = model.notesPanelOpen(tab)
        return Button {
            model.toggleNotesPanel(tab)
        } label: {
            Label(tab.label, systemImage: floating ? "pip.exit" : "pip.enter")
                .frame(maxWidth: .infinity)
        }
        .help(floating
            ? "Put my \(tab.phrase) back in the window"
            : "Float my \(tab.phrase) above other apps")
    }
}

struct RootView: View {
    @State var model: AppModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            switch Appearance.panel?.name {
            case "settings":
                SettingsView(model: model, initialTab: Appearance.panel?.argument)
            case "menubar":
                MenuBarContent(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            case "import":
                importPanel
            case "onboarding":
                Color.clear
            default:
                split
            }
        }
        .modifier(MainWindowGlass(enabled: Appearance.panel?.name != "onboarding"))
        // Search, over whatever the window is showing. An overlay rather than a sheet, deliberately
        // and permanently: a sheet stops AppKit terminating the app before the delegate is even
        // asked, so ⌘Q would do nothing while it was open (`SearchPalette` has the full reason).
        .overlay {
            if model.searchPaletteOpen {
                SearchPalette(model: model)
            }
        }
        // One place decides which panels are on screen, so the menu items, the menu bar rows, the
        // panels' own close buttons and the remembered state cannot disagree.
        .onChange(of: model.showingOnboarding) { _, showing in
            guard showing else { return }
            OnboardingWindowController.shared.show(model: model, initialStep: nil) {
                model.showingOnboarding = false
            }
        }
        .onChange(of: model.openNotesPanels, initial: true) { _, open in
            guard !model.showingOnboarding else { return }
            for tab in NotesTab.allCases {
                if open.contains(tab) {
                    openWindow(id: NotesPanel.sceneID(tab))
                } else {
                    dismissWindow(id: NotesPanel.sceneID(tab))
                }
            }
        }
        .task {
            model.start()
            if let requested = Appearance.importFile {
                model.beginImport(of: requested.url)
                if requested.immediate, let pending = model.pendingImport {
                    await model.completeImport(pending)
                }
            }
        }
        // Dragging an audio file onto the window creates a meeting from it. That is the
        // whole GUI import story; a folder of legacy recordings is a CLI job driven by an agent.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: isAudio) else { return false }
            model.beginImport(of: url)
            return true
        }
        .sheet(item: $model.pendingImport) { pending in
            ImportSheet(
                pending: pending,
                folders: model.folders,
                transcription: model.transcription,
                store: model.store
            ) {
                model.pendingImport = nil
            } confirm: { confirmed in
                Task { await model.completeImport(confirmed) }
            }
        }
    }

    /// The import dialog rendered in the main window rather than as a sheet — a sheet is a child
    /// window and `screencapture -l` on the parent does not include it. Screenshot seam only.
    @ViewBuilder
    private var importPanel: some View {
        if let pending = model.pendingImport {
            ImportSheet(
                pending: pending,
                folders: model.folders,
                transcription: model.transcription,
                store: model.store
            ) {} confirm: { _ in }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return AppModel.importableAudioTypes.contains { type.conforms(to: $0) }
    }

    private var split: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } content: {
            MeetingListView(model: model)
        } detail: {
            GlassContentCard {
                VStack(spacing: 0) {
                    if let message = model.errorMessage {
                        ErrorBanner(message: message) { model.errorMessage = nil }
                    }
                    if !model.recordingBlockers.isEmpty {
                        PrerequisiteNotice(prerequisites: model.recordingBlockers) {
                            Task { await model.recheckRecordingBlockers() }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    MeetingDetailView(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 380, ideal: 640)
        }
        .navigationTitle(model.title(for: model.scope))
        .toolbar {
            if model.recordingChromeBelongsInToolbar {
                ToolbarItem(placement: .principal) {
                    RecordingToolbarStatus(model: model)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.recordingChromeBelongsInToolbar {
                    Button("Stop recording", systemImage: "stop.circle") {
                        Task { await model.stopRecording() }
                    }
                    .labelStyle(.iconOnly)
                    .help("Stop recording")
                } else if !model.isRecording {
                    Button("New meeting", systemImage: "plus") {
                        Task { await model.startAdHocMeeting() }
                    }
                    .labelStyle(.iconOnly)
                    .help("New meeting that is not in your calendar")
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                SearchToolbarButton(model: model)
            }
        }
    }
}

/// The elapsed clock in the toolbar, so a recording is visible from any meeting in the window and
/// not only from the one being recorded.
private struct RecordingToolbarStatus: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            RecordingDot(size: 8)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Format.clock(milliseconds: model.recording.elapsedMs))
                    .font(.callout.monospacedDigit())
                    .contentTransition(.numericText())
            }
        }
        .help(model.activeMeeting.map { "Recording \($0.title)" } ?? "Recording")
    }
}

/// Errors belong in the window, not in a modal. Losing the connection to the store or failing to
/// start the microphone should not stop you reading the transcript you already have.
private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss)
                .buttonStyle(.link)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5))
    }
}
