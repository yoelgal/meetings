import AppKit
import Foundation
import MeetingsCore
import Observation

/// What the sidebar selects. Folders are rows too, so this carries an associated id rather than
/// being a closed set of fixed lists.
enum Scope: Hashable, Identifiable {
    case needsWriteUp, all, upcoming, unfiled
    case folder(String)

    var id: String { token }

    /// The stable string form, used for `MEETINGS_SCOPE` and nothing else.
    var token: String {
        switch self {
        case .needsWriteUp: "needsWriteUp"
        case .all: "all"
        case .upcoming: "upcoming"
        case .unfiled: "unfiled"
        case .folder(let id): "folder:\(id)"
        }
    }

    init?(token: String) {
        switch token {
        case "needsWriteUp": self = .needsWriteUp
        case "all": self = .all
        case "upcoming": self = .upcoming
        case "unfiled": self = .unfiled
        default:
            guard token.hasPrefix("folder:") else { return nil }
            self = .folder(String(token.dropFirst("folder:".count)))
        }
    }

    /// The name a folder scope carries is looked up in the store, so this is only the fixed part.
    var title: String {
        switch self {
        case .needsWriteUp: "Needs write-up"
        case .all: "All meetings"
        case .upcoming: "Upcoming"
        case .unfiled: "Unfiled"
        case .folder: "Folder"
        }
    }

    var symbol: String {
        switch self {
        // Not `tray.full`: it and Unfiled's `tray` differ by a four-pixel stub at 13 pt, on the two
        // rows a person is most likely to confuse. A clipboard and a tray share no silhouette.
        case .needsWriteUp: "pencil.and.list.clipboard"
        case .all: "waveform"
        case .upcoming: "calendar"
        case .unfiled: "tray"
        case .folder: "folder"
        }
    }

    var folderID: String? {
        if case .folder(let id) = self { return id }
        return nil
    }
}

/// One bucket of the meeting list — Today, Previous 7 Days, June — already sorted. `order` decides
/// where the bucket sits and is never shown. An imported meeting with no date at all is legal
/// and lands in an "Undated" bucket at the bottom.
struct DayGroup: Identifiable {
    let order: Int
    let label: String
    let meetings: [Meeting]

    var id: Int { order }
}

/// The same header over Upcoming, which groups by calendar day rather than by "Previous 7 days" —
/// what you want to know about next week is which day it lands on.
struct UpcomingDayGroup: Identifiable {
    let day: Date
    let label: String
    let meetings: [Meeting]

    var id: Date { day }
}

@MainActor
@Observable
final class AppModel {
    let store: MeetingStore
    let transcription: TranscriptionService
    let recording: RecordingController
    let enhancement: EnhancementRunner
    let calendarSource: any CalendarSource

    var scope: Scope = .all {
        didSet {
            guard scope != oldValue else { return }
            selection = nil
            refresh()
        }
    }

    /// The selected meeting's id. Every row in every list is a meeting now, Upcoming included —
    /// there is no second kind of row for a selection to have to distinguish.
    var selection: String? {
        didSet {
            guard selection != oldValue else { return }
            loadSelection()
        }
    }

    /// The ⌘K palette's field. The store has had FTS5 and a working `meetings search` since
    /// wave 1; until now the window was the one place you could not reach it.
    var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            runSearch()
        }
    }

    /// Whether the search palette is on screen. One flag, because there is exactly one way into
    /// search now: the toolbar's field became a button that flips this, and ⌘K flips it from the
    /// menu bar.
    private(set) var searchPaletteOpen = false

    /// Which hit Return would open. Reset to the top whenever the results change, because an index
    /// into a list that has just been replaced points at a different meeting from the one that was
    /// under the highlight a keystroke ago.
    private(set) var highlightedResult = 0

    var highlightedHit: SearchHit? {
        searchResults.indices.contains(highlightedResult) ? searchResults[highlightedResult] : nil
    }

    /// One row per matching meeting, best hit first. The store returns a hit per matching *line*,
    /// which is the right answer for an agent and the wrong one for a list — three matching
    /// sentences in one meeting is one meeting to open, not three rows to choose between.
    private(set) var searchResults: [SearchHit] = []

    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    /// False until the store has actually been read once. An unread list and an empty list look
    /// identical and mean opposite things: "No meetings yet" shown while the read is still running
    /// is a false statement about the user's data, and on a large store it is on screen for as long
    /// as the read takes.
    ///
    /// Every empty state that speaks for the store is gated on this — the meetings list, the
    /// sidebar's folders, and search's "No matches", which wave 3 claimed and the last two did not
    /// have. The window's other empty states are not about the store and are not gated here: the
    /// calendar has `upcomingLoaded`, and "the store could not be opened", "Listening" and "No
    /// meeting selected" are each true the moment they are drawn.
    private(set) var loaded = false
    /// The same distinction for the calendar, which is read asynchronously and separately.
    private(set) var upcomingLoaded = false

    private(set) var meetings: [Meeting] = []
    private(set) var folders: [Folder] = []
    /// Upcoming, as store rows. Every calendar meeting inside the look-ahead window has one from the
    /// moment it appears (``CalendarSync``), so this is the same kind of thing every other list
    /// holds — filable, notable, and recordable without a step in between.
    private(set) var upcoming: [Meeting] = []
    /// The events the last sync saw, by calendar event id. The row carries no video link, and this
    /// is where the Join button on a scheduled meeting gets one without a second calendar read.
    private(set) var calendarEvents: [String: CalendarEvent] = [:]
    private(set) var needsWriteUpCount = 0
    /// Folder id → how many meetings are in it, for the sidebar's trailing counts. Worked out here,
    /// from the same read every other number on screen comes from, so the counts cannot disagree
    /// with the list beside them — see ``count(inFolder:)``.
    private(set) var folderCounts: [String: Int] = [:]
    /// Set once, late, if GitHub has a newer release than this build. Nil covers every other case,
    /// including the check being switched off and every kind of failure, so the sidebar only ever
    /// has to ask whether there is something to say.
    private(set) var availableUpdate: AvailableUpdate?
    /// Launch check plus the daily tick, held so it dies with the model rather than outliving it.
    private var updateChecks: Task<Void, Never>?

    private(set) var selectedMeeting: Meeting?
    /// The transcript of the selected meeting. Final segments win over live ones when both exist.
    private(set) var segments: [TranscriptSegment] = []
    /// What went wrong with the selected meeting's transcript, and why. Read beside `segments`
    /// because it is the other half of the same answer: a meeting whose microphone handed the
    /// recorder pure digital silence produces a perfectly ordinary-looking half transcript, and
    /// until this was read the window had no way to tell one from a whole one. The CLI has said so
    /// since wave 2; the surface the user actually looks at said nothing at all.
    private(set) var transcriptIssues: [TranscriptIssue] = []
    /// Every meeting in the store carrying one, for the list's row marker. One query per refresh
    /// rather than one per row — a transcript failure is rare, so almost every refresh pays a
    /// single empty lookup. The same query `meetings list` uses for its `*`.
    private(set) var meetingsWithTranscriptIssues: Set<String> = []
    /// The live notes written during the selected meeting, oldest first.
    private(set) var notes: [Note] = []
    /// The line a `ready` meeting offers to copy, read from `ai.manual.pasteCommand`.
    ///
    /// Deliberately **not** Mode B's `ai.localAgent.runCommand`: that one is exec'd, so it has to
    /// start a fresh headless run (`claude -p …`), and a fresh run is exactly what somebody pasting
    /// into a session they already have open is trying to avoid. One setting could not be right for
    /// both, and while it was one setting this card handed out the wrong half.
    private(set) var manualPasteCommand = SettingKey.aiManualPasteCommand.defaultValue ?? ""
    /// What Mode B last did, when it ran. Nil in the default manual mode, forever.
    private(set) var lastEnhancement: String?
    var errorMessage: String?

    /// What recording found missing the last time it was asked to start. It lives on the model and
    /// not on any one button because four entry points reach `startRecording` — the detail view's
    /// Start Recording, the toolbar's New Meeting, the menu bar and the calendar nudge — and a copy
    /// of the check at each of them is three places to forget one. The window shows it wherever the
    /// press came from.
    private(set) var recordingBlockers: [Prerequisite] = []

    /// The onboarding wizard, shown once on a store that has never completed it.
    var showingOnboarding = false
    /// The dialog behind an audio file dropped on the window.
    var pendingImport: PendingImport?

    /// The calendar-event nudge. Owned here because both the menu bar and the window
    /// read it, and because it must survive the menu closing.
    let nudge: NudgeModel

    // MARK: - The floating notes panels

    /// Which panels are on screen, remembered across launches — they are sticky notes, and they stay
    /// where they were put. Pre-notes and live notes are two independent windows: during a call the
    /// agenda you wrote beforehand and the notes you are taking are both wanted at once, and one
    /// panel showing one of two made you close the first to see the second.
    private(set) var openNotesPanels: Set<NotesTab> = NotesPanel.initialOpenTabs

    func notesPanelOpen(_ tab: NotesTab) -> Bool { openNotesPanels.contains(tab) }

    /// The one way in. Open/closed is decided here rather than in the four places that ask for it —
    /// the View menu, the menu bar, each pane's pop-out control and the panel's own close button —
    /// so none of them can leave the remembered state disagreeing with what is on screen.
    func setNotesPanel(_ tab: NotesTab, open: Bool) {
        guard notesPanelOpen(tab) != open else { return }
        if open { openNotesPanels.insert(tab) } else { openNotesPanels.remove(tab) }
        NotesPanel.persist(open: open, tab: tab)
    }

    func toggleNotesPanel(_ tab: NotesTab) {
        setNotesPanel(tab, open: !notesPanelOpen(tab))
    }

    /// Default **on**. A panel holding your private thoughts during a call you are sharing should
    /// not leak because you forgot to turn something on.
    var notesPanelHiddenFromCapture = true {
        didSet { write(.notesPanelHiddenFromCapture, notesPanelHiddenFromCapture) }
    }

    /// Default **on**. Being above the call is the entire point of the thing.
    var notesPanelFloats = true {
        didSet { write(.notesPanelFloats, notesPanelFloats) }
    }

    /// Default **on**. Switched off, the app makes no unprompted network request of any kind.
    ///
    /// Turning it off does not clear a notice already on screen. That notice is a true statement
    /// about a release that exists, and withdrawing it would make the switch look like it undid the
    /// release rather than the checking.
    var updateCheckEnabled = true {
        didSet { write(.updateCheckEnabled, updateCheckEnabled) }
    }

    /// Whichever meeting's notes the panel is holding: the one being recorded if there is one —
    /// that is what the panel is for — otherwise whatever the window has selected.
    var notesPanelMeeting: Meeting? { activeMeeting ?? selectedMeeting }

    /// Which notes the *window's* pane is showing, when the user has said. Nil means "whichever the
    /// meeting implies". The panels do not read it — there is one per surface — but the window has
    /// a single pane for both and still has to choose.
    ///
    /// It exists because the implied answer is not always the wanted one. During a recording the
    /// implied answer is the live notes, and that left what you wrote *before* the call — the agenda,
    /// the questions you meant to ask — unreachable for the entire call, which is the one stretch of
    /// time it was written for.
    var notesTab: NotesTab?

    /// What that pane should actually show: the choice if one was made, else the meeting's own state.
    var effectiveNotesTab: NotesTab {
        if let notesTab { return notesTab }
        guard let meeting = notesPanelMeeting else { return .preNotes }
        return displayState(for: meeting) == .recording ? .liveNotes : .preNotes
    }

    /// True when that panel is holding this meeting's notes, which is when the window's own pane for
    /// the same surface should say where its content went instead of drawing a second copy of it.
    /// Asked per surface, because the two panels open and close independently: the live notes can be
    /// floating while the pre-notes are still in the window.
    func notesPanelHolds(_ meeting: Meeting, _ tab: NotesTab) -> Bool {
        notesPanelOpen(tab) && notesPanelMeeting?.id == meeting.id
    }

    /// The notes the panel is showing. Usually the very array the window has — the panel follows
    /// the recording and the window normally selects it — but they diverge the moment you click a
    /// different meeting mid-call, and the panel must keep showing the call's notes.
    private(set) var panelNotes: [Note] = []

    private func write(_ key: SettingKey, _ value: Bool) {
        try? store.setSetting(key, value ? "true" : "false")
    }

    private var observation: StoreChange.Observation?
    /// See ``syncUpcoming()``.
    private var upcomingSync: Task<Void, Never>?
    private var upcomingSyncQueued = false
    /// Which meetings were already at `ready` when this session started, so arming Mode B on a
    /// *transition* to ready does not fire it for a backlog on the first refresh after launch.
    private var knownReady: Set<String> = []
    private var readyBaselineTaken = false

    init(store: MeetingStore, calendarSource: any CalendarSource = CalendarSources.resolved()) {
        self.store = store
        self.calendarSource = calendarSource
        let transcription = TranscriptionService(store: store)
        self.transcription = transcription
        self.recording = RecordingController(store: store, transcription: transcription)
        self.enhancement = EnhancementRunner(store: store)
        self.nudge = NudgeModel(store: store, calendarSource: calendarSource)
        // Both default on, and both are rows in the same `settings` table as everything else.
        // `didSet` does not fire during init, so this reads without writing back.
        notesPanelHiddenFromCapture = ((try? store.settingBool(.notesPanelHiddenFromCapture)) ?? nil) ?? true
        notesPanelFloats = ((try? store.settingBool(.notesPanelFloats)) ?? nil) ?? true
        updateCheckEnabled = ((try? store.settingBool(.updateCheckEnabled)) ?? nil) ?? true
        // Here rather than in `start()`, which the root view calls from `.task` — one runloop turn
        // after the first frame. Deciding it there meant a first launch drew the whole app, sidebar
        // and empty list and all, and only then replaced it with the wizard and shrank the window
        // around it. One settings row is the same cost as the two above it and is paid before
        // anything is on screen, which is the only place it can be paid without a flash.
        showingOnboarding = Appearance.forceOnboarding
            || (try? store.settingBool(.onboardingCompleted)) != true
    }

    var calendarAuthorization: CalendarAuthorization { calendarSource.authorizationStatus() }

    /// Called once from the root view's `.task`. Nothing here touches the transcription models —
    /// a cold launch has to reach a usable window in under a second and asking whether a
    /// 600 MB model is on disk is not something the first frame should wait for.
    func start() {
        // Before anything reads a WAV. A recording interrupted by a crash left its header unfinalised,
        // which reads as zero frames even though every byte is on disk — the batch pass would then
        // "succeed" with an empty transcript and bin a meeting that was fully recoverable.
        WAVRepair.repairTree()
        // Then the meeting the audio belongs to. `WAVRepair` gets the bytes back; this gets the row
        // back — without it a crash mid-recording strands the meeting at `recording` forever, with
        // a phantom red dot and a Stop button that throws. It runs after the repair (an unfinalised
        // WAV reads as zero frames, and deciding on that would bin a recoverable meeting) and
        // before `resumePendingOnLaunch()`, which is the queue that picks up what it recovers.
        RecordingRecovery.sweepOnLaunch(store: store)
        // The retention sweep runs on launch. The rule itself lives in MeetingsCore so the
        // CLI applies exactly the same one.
        Retention.sweepOnLaunch(store: store)
        refresh()
        applyLaunchOverrides()
        // Anything still at `transcribing` is work this or a previous launch did not finish: a crash
        // mid-pass, or an imported backlog that outlived the session. The store is the queue.
        Task { await transcription.resumePendingOnLaunch() }
        // The setup wizard has always claimed "Meetings installs an agent skill on launch" and
        // nothing in the app ever did it — the only caller was `meetings skill install`, which you
        // reach by typing the command the skill exists to save you from typing. Doing it here is
        // also what keeps the skill from going stale: it is rewritten every launch, so an app
        // update cannot leave an older copy of SKILL.md describing commands that have moved.
        //
        // Off the main actor because it is file I/O on the launch path, and safe to do unasked
        // because `SkillInstall.targets()` never creates an agent tool's config directory — it only
        // writes where one already exists. A tool you do not use sees nothing.
        Task.detached(priority: .utility) { try? SkillInstall.install() }
        nudge.start()
        // Detached and unawaited, because this is the one thing on the launch path that touches the
        // network and the window must not wait on a socket to draw. It settles into the
        // sidebar whenever it settles, or never, which is the correct amount of ceremony for news
        // that a newer version exists.
        // Every launch, then once a day for as long as the app stays open. Launch deliberately
        // ignores the daily interval: you have just relaunched, quite possibly *because* you
        // updated, and being told you are current until tomorrow is the wrong answer to that.
        updateChecks = Task { [weak self, store] in
            if let update = await UpdateCheck.run(.launch, store: store, currentVersion: AppInfo.version)
                .available {
                self?.availableUpdate = update
            }
            // A window left open for a week would otherwise never check again.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(UpdateCheck.interval))
                guard !Task.isCancelled else { return }
                if let update = await UpdateCheck
                    .run(.periodic, store: store, currentVersion: AppInfo.version).available {
                    self?.availableUpdate = update
                }
            }
        }
        // GRDB's ValueObservation only sees writes from this process, and the CLI is a second
        // process on the same file. This is the only thing that makes an agent's write show up.
        observation = StoreChange.observe(storePath: store.dbPool.path, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func applyLaunchOverrides() {
        if let token = Appearance.scopeToken {
            // A folder can be named rather than identified, because a screenshot run has no ids.
            if let name = token.split(separator: ":", maxSplits: 1).last.map(String.init),
               token.hasPrefix("folder:"),
               let folder = folders.first(where: { $0.id == name || $0.name == name }) {
                scope = .folder(folder.id)
            } else if let parsed = Scope(token: token) {
                scope = parsed
            }
        }
        if let state = Appearance.select, let first = meetings.first(where: { $0.state == state }) {
            selection = first.id
        }
        if let query = Appearance.search {
            searchQuery = query
            searchPaletteOpen = true
        }
    }

    /// The Check now button. Runs whatever the setting says: pressing it *is* the consent the
    /// setting exists to record, and a button that silently does nothing because a preference is off
    /// is a button people press again.
    ///
    /// Returns the outcome rather than only setting `availableUpdate`, because "you are up to date"
    /// and "GitHub is unreachable" are both things a press has to be able to say.
    func checkForUpdates() async -> UpdateCheck.Outcome {
        let outcome = await UpdateCheck.run(.manual, store: store, currentVersion: AppInfo.version)
        if let update = outcome.available { availableUpdate = update }
        return outcome
    }

    func refresh() {
        do {
            // ponytail: one query, filtered in memory. A personal store holds hundreds of rows, not
            // millions; push the scope into SQL when a list actually gets slow.
            let all = try store.allMeetings()
            folders = try store.folders()
            meetingsWithTranscriptIssues = (try? store.meetingIDsWithTranscriptIssues()) ?? []
            needsWriteUpCount = all.filter { $0.state == .ready }.count
            folderCounts = all.reduce(into: [:]) { counts, meeting in
                if let id = meeting.folderID { counts[id, default: 0] += 1 }
            }
            // A folder deleted in the other process takes its sidebar row with it, and the window
            // was left sitting in a scope that no longer exists: title "Folder", and "No meetings
            // yet" over a folder that is not there — which reads as "this folder is empty" and is
            // a false statement about the user's data. Fall back to the list that is always true.
            //
            // `scope`'s own `didSet` refreshes again, so the rest of this pass runs twice and lands
            // on the same answer both times. Cheaper than a second code path that has to remember
            // everything this one does.
            if let id = scope.folderID, !folders.contains(where: { $0.id == id }) {
                scope = .all
                errorMessage = "That folder is no longer in the store, so this is All meetings."
            }
            switch scope {
            case .all: meetings = all
            case .needsWriteUp: meetings = all.filter { $0.state == .ready }
            case .unfiled: meetings = all.filter { $0.folderID == nil }
            case .folder(let id): meetings = all.filter { $0.folderID == id }
            case .upcoming: meetings = []
            }
            manualPasteCommand = (try store.setting(.aiManualPasteCommand)) ?? manualPasteCommand
            nudge.recordingInProgress = isRecording
            runSearch()
            loadSelection()
            armEnhancement(for: all)
        } catch {
            errorMessage = "The meeting store could not be read: \(PlainText.sentence(for: error))"
        }
        // Set whether the read succeeded or failed: a store that will not open has an error banner
        // to say so, and a spinner that never stops is its own lie.
        loaded = true
        syncUpcoming()
    }

    /// One calendar pass at a time, with a single trailing one behind it.
    ///
    /// A first launch creates a row per calendar meeting, each row posts a `StoreChange`, and this
    /// process answers its own posts with another `refresh()` — so twenty meetings in the window
    /// meant twenty more passes over that window, each building an `EKEventStore` to ask a question
    /// the pass before it had already answered. Only the last one's answer is current, so only the
    /// last one is kept.
    private func syncUpcoming() {
        guard upcomingSync == nil else {
            upcomingSyncQueued = true
            return
        }
        upcomingSync = Task { [weak self] in
            await self?.loadUpcoming()
            guard let self else { return }
            upcomingSync = nil
            guard upcomingSyncQueued else { return }
            upcomingSyncQueued = false
            syncUpcoming()
        }
    }

    // MARK: - The search palette (⌘K)

    func openSearchPalette() {
        searchPaletteOpen = true
    }

    /// Closing empties the field. The palette is the only place the query can be seen or edited, so
    /// a query left behind would be an invisible filter, and reopening would drop the cursor into
    /// the middle of a search nobody remembers running.
    func closeSearchPalette() {
        searchPaletteOpen = false
        searchQuery = ""
    }

    func moveSearchHighlight(by delta: Int) {
        highlightedResult = SearchSelection.moved(
            highlightedResult, by: delta, count: searchResults.count
        )
    }

    /// Return, or a click on a row. Opening a hit means selecting its meeting, which is what drives
    /// the detail column.
    func openHighlightedResult() {
        guard let hit = highlightedHit else { return }
        // A hit is usually outside the list you are looking at — search reads the whole store, so a
        // match found from a folder, from Needs write-up or from Upcoming has no row to select in
        // the middle column and the choice would land in a column showing something else entirely.
        // Setting `scope` clears the selection, so widening it first is load-bearing.
        if !meetings.contains(where: { $0.id == hit.meeting.id }) { scope = .all }
        selection = hit.meeting.id
        closeSearchPalette()
    }

    func highlight(_ index: Int) {
        highlightedResult = SearchSelection.moved(0, by: index, count: searchResults.count)
    }

    /// ponytail: straight through to SQLite on every keystroke, no debounce. FTS5 over a personal
    /// store answers in well under a frame; add a debounce when a real store makes it stutter.
    ///
    /// **The whole store, never the selected folder.** This passed `scope.folderID` through, so a
    /// sidebar sitting on a folder turned ⌘K into a search of that folder alone — while
    /// `meetings search` searches everything unless it is handed `--folder`, so the CLI found
    /// meetings the window swore did not exist. Nothing said a filter was on and nothing could take
    /// it off, and the palette's "No matches" speaks for the whole store. It was not a decision
    /// either: the other four scopes carry a nil `folderID`, so only one kind of sidebar row ever
    /// narrowed it.
    private func runSearch() {
        highlightedResult = 0
        guard isSearching else {
            searchResults = []
            return
        }
        do {
            var seen: Set<String> = []
            searchResults = try store
                .search(query: searchQuery)
                .filter { seen.insert($0.meeting.id).inserted }
        } catch {
            searchResults = []
            errorMessage = "That search could not be run: \(PlainText.sentence(for: error))"
        }
    }

    /// Syncs the look-ahead window into the store, then reads the list back out of it.
    ///
    /// The sync is what makes Upcoming a list of meetings rather than a list of calendar events:
    /// every event carrying a meeting link gets its row here, so the pane it opens is the ordinary
    /// scheduled-meeting pane with a pre-notes editor in it. ``CalendarSync`` documents what a
    /// second pass does to a row that already exists, and what it does not.
    ///
    /// It writes, and this process hears its own writes as a `StoreChange` and answers them with
    /// another `refresh()` — which lands back here. That settles rather than spins because the sync
    /// only writes when a field actually differs; the second pass over an unchanged calendar writes
    /// nothing and posts nothing.
    ///
    /// Never prompts — `CalendarSource` returns an empty list when access has not been granted, and
    /// the Upcoming list says so rather than throwing up a permission dialog nobody asked for.
    private func loadUpcoming() async {
        let now = Date()
        let days = CalendarSync.lookAheadDays(in: store)
        let horizon = now.addingTimeInterval(Double(days) * 86_400)
        do {
            let events = try await CalendarSync(store: store, calendar: calendarSource)
                .run(now: now, days: days)
            calendarEvents = Dictionary(events.map { ($0.id, $0) }) { first, _ in first }
            // Read from the store, not from the events: an ad-hoc meeting somebody scheduled for
            // tomorrow is coming up too, and listing only what came from the calendar is how the
            // window and `meetings upcoming` came to disagree about what "upcoming" means.
            upcoming = try store.meetings(state: .scheduled)
                .filter { ($0.scheduledStart ?? .distantPast) >= now }
                .filter { ($0.scheduledStart ?? .distantFuture) <= horizon }
                .sorted { ($0.scheduledStart ?? .distantFuture) < ($1.scheduledStart ?? .distantFuture) }
        } catch {
            upcoming = []
            errorMessage = "The calendar could not be read: \(PlainText.sentence(for: error))"
        }
        upcomingLoaded = true
    }

    /// The calendar event a row came from, while it is still in the synced window. Nil for an ad-hoc
    /// meeting, and for one whose event has dropped out of the window — neither has a link to join.
    func calendarEvent(for meeting: Meeting) -> CalendarEvent? {
        meeting.calendarEventID.flatMap { calendarEvents[$0] }
    }

    private func loadSelection() {
        selectedMeeting = nil
        segments = []
        transcriptIssues = []
        notes = []
        defer { loadPanelNotes() }
        guard let id = selection else { return }
        do {
            // A meeting deleted in the other process while you were reading it. The row is gone, so
            // the detail column falls back to "No meeting selected" — but the selection itself
            // stayed pointing at a meeting that no longer exists, which meant clicking anywhere and
            // coming back re-selected nothing, silently, forever. Drop the dead id and say what
            // happened, once.
            guard let meeting = try store.meeting(id: id) else {
                selection = nil
                errorMessage = "That meeting is no longer in the store."
                return
            }
            selectedMeeting = meeting
            segments = Self.visibleTranscript(try store.segments(meetingID: id))
            transcriptIssues = try store.transcriptIssues(meetingID: id)
            notes = try store.notes(meetingID: id)
        } catch {
            errorMessage = "That meeting could not be read: \(PlainText.sentence(for: error))"
        }
    }

    /// One fetch, and only when the panel is looking somewhere the window is not.
    private func loadPanelNotes() {
        guard let meeting = notesPanelMeeting else {
            panelNotes = []
            return
        }
        if meeting.id == selectedMeeting?.id {
            panelNotes = notes
        } else {
            panelNotes = (try? store.notes(meetingID: meeting.id)) ?? []
        }
    }

    /// The batch pass replaces live rows with final ones, but it does so on stop — mid-meeting both
    /// can be present. Showing them interleaved would duplicate every sentence.
    private static func visibleTranscript(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let final = segments.filter { $0.pass == .final }
        return final.isEmpty ? segments : final
    }

    var groupedMeetings: [DayGroup] {
        var labels: [Int: String] = [:]
        var buckets: [Int: [Meeting]] = [:]
        for meeting in meetings {
            let bucket = Format.bucket(for: meeting.sortDate)
            labels[bucket.order] = bucket.label
            buckets[bucket.order, default: []].append(meeting)
        }
        // The rows inside a bucket keep the store's newest-first order; only the buckets are sorted.
        //
        // Except Scheduled, which is the one bucket pointing the other way. Newest-first there puts
        // the meeting furthest into the future at the top and the one starting in ten minutes at the
        // bottom, which is backwards for the only question anyone asks of it.
        return buckets.keys.sorted().map { order in
            let rows = buckets[order] ?? []
            return DayGroup(
                order: order,
                label: labels[order] ?? "",
                meetings: order == Format.scheduledBucket ? rows.reversed() : rows
            )
        }
    }

    var upcomingGroups: [UpcomingDayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Meeting]] = [:]
        for meeting in upcoming {
            // Every row in `upcoming` was filtered on having a start, so this default is unreachable
            // rather than a guess about where an undated meeting belongs.
            let day = calendar.startOfDay(for: meeting.scheduledStart ?? Date())
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(meeting)
        }
        return order.map {
            UpcomingDayGroup(day: $0, label: Format.dayLabel($0), meetings: buckets[$0] ?? [])
        }
    }

    func title(for scope: Scope) -> String {
        guard let id = scope.folderID else { return scope.title }
        return folders.first { $0.id == id }?.name ?? "Folder"
    }

    /// The exact line a `ready` meeting offers to copy into an agent session.
    func agentCommand(for meeting: Meeting) -> String {
        manualPasteCommand.replacingOccurrences(of: "{meeting_id}", with: meeting.id)
    }

    /// The elapsed clock for a meeting that is recording. Prefers the controller's own start
    /// instant; falls back to the stored `started_at` so a row left at `recording` by a crashed
    /// session still renders a real number instead of 00:00.
    func recordingStart(for meeting: Meeting) -> Date? {
        if recording.meetingID == meeting.id, case .recording(let startedAt) = recording.phase {
            return startedAt
        }
        return meeting.startedAt
    }

    /// The state to draw. While this process is driving the recording, the controller is ahead of
    /// the database — it knows it is stopping before the row does.
    func displayState(for meeting: Meeting) -> MeetingState {
        guard recording.meetingID == meeting.id else { return meeting.state }
        switch recording.phase {
        case .starting, .recording: return .recording
        case .stopping, .transcribing: return .transcribing
        case .idle, .failed: return meeting.state
        }
    }

    var transcribingProgress: Double? {
        if case .transcribing(let progress) = recording.phase { return progress }
        return nil
    }

    var isRecording: Bool {
        // Screenshot seam, inert unless the environment variable is set — see `Appearance`.
        if Appearance.forceRecordingChrome { return true }
        return switch recording.phase {
        case .starting, .recording: true
        default: false
        }
    }

    /// Whether the toolbar draws the recording transport. Only when the recording screen — which
    /// carries its own dot, clock, meters and Stop along the bottom — is not the thing on screen.
    /// Otherwise the same three controls appear twice in one window, ~700 pt apart.
    var recordingChromeBelongsInToolbar: Bool {
        guard isRecording else { return false }
        guard let selected = selectedMeeting else { return true }
        return displayState(for: selected) != .recording
    }

    /// The meeting currently being recorded, for the menu bar's quick note.
    var activeMeeting: Meeting? {
        guard let id = recording.meetingID, isRecording else { return nil }
        return meetings.first { $0.id == id } ?? (try? store.meeting(id: id)) ?? nil
    }

    // MARK: - Actions

    /// A meeting that is not on the calendar: the row is created, selected, and recording starts.
    /// Without this nothing can be recorded at all.
    func startAdHocMeeting() async {
        let now = Date()
        let meeting = Meeting(
            // A new meeting lands in whichever folder you are looking at. Anywhere else and every
            // ad-hoc recording has to be filed by hand immediately after it ends.
            folderID: scope.folderID,
            title: "Meeting at \(Format.timeOfDay(now))",
            state: .scheduled,
            scheduledStart: now
        )
        do {
            try store.createMeeting(meeting)
        } catch {
            errorMessage = "The meeting could not be created: \(PlainText.sentence(for: error))"
            return
        }
        refresh()
        selection = meeting.id
        guard await startRecording(meetingID: meeting.id) else {
            // Nothing was captured, so leave no half-meeting behind for the user to clean up.
            _ = try? store.deleteMeeting(id: meeting.id)
            selection = nil
            refresh()
            return
        }
    }

    @discardableResult
    func startRecording(meetingID: String) async -> Bool {
        recordingBlockers = await Prerequisites.forRecording(transcription, store: store)
        // The microphone is the only fatal one. Without it the recorder still opens a file, still
        // runs its clock and captures nothing at all, and the first the user hears of it is an empty
        // transcript half an hour later. Missing system audio or missing models each cost part of a
        // recording that is still worth having, so those start anyway and leave the notice up saying
        // what this recording will not have.
        guard !recordingBlockers.contains(where: { $0.id == "mic" }) else { return false }
        do {
            try await recording.start(meetingID: meetingID)
            nudge.dismissForActiveRecording()
            refresh()
            return true
        } catch {
            errorMessage = "Recording could not start: \(PlainText.sentence(for: error))"
            return false
        }
    }

    /// Re-reads the blockers so the notice can retire itself. Granting a permission means leaving
    /// for System Settings and coming back, and having to press Start a second time to discover it
    /// worked is how a user concludes it did not.
    func recheckRecordingBlockers() async {
        recordingBlockers = await Prerequisites.forRecording(transcription, store: store)
    }

    func stopRecording() async {
        do {
            try await recording.stop()
        } catch {
            errorMessage = "Recording could not be stopped cleanly: \(PlainText.sentence(for: error))"
        }
        // Back to the implied answer. A choice of "live notes" made during the call would otherwise
        // outlive it, and the switch that set it is only on screen while recording — so the panel
        // would sit on a finished meeting's live notes with nothing offering to change it back.
        notesTab = nil
        refresh()
    }

    /// Starts recording the calendar event the nudge is pointing at, materialising its row first —
    /// the same rule a `cal:` write follows.
    func startNudgedRecording() async {
        guard let event = nudge.pending else { return }
        guard let meeting = await materialise(event) else { return }
        await startRecording(meetingID: meeting.id)
    }

    /// Gives a calendar event a row in the store and selects it.
    ///
    /// ``CalendarSync`` has normally made the row already — it runs over the whole look-ahead
    /// window — but the nudge is on its own thirty-second poll and can reach a meeting first, and
    /// pressing Record must not depend on which of the two ran last. It is also the one path that
    /// deliberately overrides a dismissal: asking to record this meeting is asking for its row back.
    ///
    /// Same `resolveForWrite` the sync and a `cal:` write from the CLI both use, so whichever gets
    /// there first, there is one row rather than two racing for the same calendar id.
    @discardableResult
    func materialise(_ event: CalendarEvent) async -> Meeting? {
        do {
            let resolver = RefResolver(store: store, calendar: calendarSource)
            let meeting = try await resolver.resolveForWrite(.calendar(event.id))
            refresh()
            selection = meeting.id
            return meeting
        } catch {
            errorMessage = "That event could not be opened: \(PlainText.sentence(for: error))"
            return nil
        }
    }

    // MARK: - Notes

    /// A live note, anchored at the instant it was written. The offset is the recording
    /// clock rather than wall time, and the store picks the anchor segment with the same rule the
    /// batch pass will use later to remap it — so a note never moves because the final pass ran.
    ///
    /// The default argument keeps the menu bar's quick note pointed at whatever is recording; the
    /// window's pane and the floating panel both name the meeting they are showing, because they
    /// can be showing a row a *previous* session left at `recording`.
    func addLiveNote(_ text: String, to meeting: Meeting? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let target = meeting ?? activeMeeting else { return }
        do {
            try store.addNote(
                meetingID: target.id,
                tOffsetMs: elapsedMs(for: target),
                text: trimmed
            )
            refresh()
        } catch {
            errorMessage = "That note could not be saved: \(PlainText.sentence(for: error))"
        }
    }

    /// The recording clock for a meeting, in milliseconds — the offset a live note anchors at, and
    /// the number the panel and the recording bar both display.
    ///
    /// Same two-source rule as `recordingStart(for:)`: this process's own recorder when it is the
    /// one recording, otherwise the row's `started_at`, so a session a crash interrupted still
    /// files its notes at the offset they were actually written at instead of at zero.
    func elapsedMs(for meeting: Meeting) -> Int {
        if recording.meetingID == meeting.id, case .recording = recording.phase {
            return recording.elapsedMs
        }
        guard displayState(for: meeting) == .recording, let startedAt = meeting.startedAt else {
            return 0
        }
        return max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    func savePreNotes(meetingID: String, text: String) {
        do {
            try store.updateMeeting(id: meetingID) { $0.preNotes = text }
        } catch {
            errorMessage = "Pre-notes could not be saved: \(PlainText.sentence(for: error))"
        }
    }

    /// `Meeting.setSummary` rather than a plain field write, because clearing a summary moves the
    /// meeting back to `ready` — the same rule `meetings summary set` runs, so a write-up deleted
    /// here and one deleted at the command line leave the meeting in the same state.
    ///
    /// The refresh is what moves the row between Needs write-up and the rest of the list; without
    /// it the state changed underneath a middle column that goes on showing the old one.
    func saveSummary(meetingID: String, text: String) {
        do {
            let before = try store.meeting(id: meetingID)?.state
            let after = try store.updateMeeting(id: meetingID) { $0.setSummary(text) }
            if before != after.state {
                refresh()
                loadSelection()
            }
        } catch {
            errorMessage = "The summary could not be saved: \(PlainText.sentence(for: error))"
        }
    }

    // `saveActions(meetingID:from:to:)` used to be here, with a compare-and-set that dropped a
    // click if `meetings actions set` had rewritten the column in between. Actions are task list
    // items inside the summary now, so ticking one is an edit to the write-up and goes through
    // `saveSummary` above — and the two-writer question it answered is the one ``SharedFieldEdit``
    // already answers for this field: an untouched editor reloads silently, a touched one raises
    // the banner rather than letting either side win. One mechanism, not two.

    /// An empty title is not a rename, it is a mistake — "Meeting at 17:06" is generated, and a row
    /// with no name at all cannot be told from its neighbours in the list.
    ///
    /// The refresh is what puts the new name in the middle column: the list is read once per
    /// refresh and does not observe individual rows.
    func rename(meetingID: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.updateMeeting(id: meetingID) { $0.title = trimmed }
            refresh()
            loadSelection()
        } catch {
            errorMessage = "That meeting could not be renamed: \(PlainText.sentence(for: error))"
        }
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(named name: String) -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let folder = try store.createFolder(Folder(name: trimmed, sortOrder: folders.count))
            refresh()
            return folder
        } catch {
            errorMessage = "That folder could not be created: \(PlainText.sentence(for: error))"
            return nil
        }
    }

    func renameFolder(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var folder = folders.first(where: { $0.id == id }), !trimmed.isEmpty else { return }
        folder.name = trimmed
        do {
            try store.updateFolder(folder)
            refresh()
        } catch {
            errorMessage = "That folder could not be renamed: \(PlainText.sentence(for: error))"
        }
    }

    /// Deletes the folder, not its meetings: the schema sets their `folder_id` to null, so they
    /// reappear under Unfiled rather than vanishing with the folder.
    func deleteFolder(id: String) {
        do {
            _ = try store.deleteFolder(id: id)
            if scope.folderID == id { scope = .all }
            refresh()
        } catch {
            errorMessage = "That folder could not be deleted: \(PlainText.sentence(for: error))"
        }
    }

    @discardableResult
    func move(meetingID: String, toFolder folderID: String?) -> Bool {
        do {
            try store.updateMeeting(id: meetingID) { $0.folderID = folderID }
            refresh()
            return true
        } catch {
            errorMessage = "That meeting could not be moved: \(PlainText.sentence(for: error))"
            return false
        }
    }

    // MARK: - Writing a finished meeting up

    /// Asks the runner to write a meeting up when it *arrives* at `ready`, and never for the backlog
    /// that was already sitting there when the app launched. The runner picks the mode and is the
    /// real off switch — this only decides when to ask it, and asks once, so a mode that fails does
    /// not get asked again until the meeting reaches `ready` afresh.
    private func armEnhancement(for all: [Meeting]) {
        let ready = Set(all.filter { $0.state == .ready }.map(\.id))
        defer { knownReady = ready }
        guard readyBaselineTaken else {
            readyBaselineTaken = true
            return
        }
        for id in ready.subtracting(knownReady) {
            Task { [enhancement] in
                let result = await enhancement.enhanceOnReady(meetingID: id)
                await MainActor.run { self.record(result) }
            }
        }
    }

    private func record(_ result: EnhancementResult) {
        switch result {
        case .disabled, .notReady:
            // Nothing was attempted on purpose. Manual mode is the default, and a line saying so
            // after every meeting would be a notification for the absence of a feature.
            break
        case .ran(let run):
            lastEnhancement = run.exitCode == 0
                ? "Your agent wrote this up at \(Format.timeOfDay(Date()))."
                : "Your agent exited \(run.exitCode): \(run.output)"
            refresh()
        case .wroteSummary:
            lastEnhancement = "Your provider wrote this up at \(Format.timeOfDay(Date()))."
            refresh()
        case .failed(let message):
            // Already one sentence in the user's terms, and never carrying an API key: the runner
            // words it, because only the runner knows which mode was tried and what it hit.
            lastEnhancement = message
        }
    }

}
