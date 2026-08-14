import Foundation
import Testing

@testable import MeetingsCore

/// Two shipped defects that a unit test cannot reach, because the thing that is wrong is the *shape
/// of the SwiftUI source*, not a value any function returns. Both were found by a critic reading
/// pixels; both are cheap to catch by reading the source instead.
///
/// These scan `Sources/MeetingsApp`, which has no test target of its own — the package builds it as
/// an `executableTarget` and nothing links it. Adding `MeetingsAppTests` is a six-line change to
/// `Package.swift`, which this unit does not own; until it exists, this is where an app-level
/// regression check can live.
@Suite struct AppSourceGuardTests {
    /// The repository, found from this file rather than from the working directory, so the tests
    /// pass under `swift test` from anywhere.
    static let appSources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MeetingsCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Sources/MeetingsApp")

    static func swiftFiles() throws -> [(name: String, lines: [String])] {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: appSources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        #expect(names.count > 5, "the app sources moved — this guard is scanning nothing")
        return try names.map { name in
            let text = try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
            return (name, text.components(separatedBy: "\n"))
        }
    }

    /// `Text("…" + "…")` is an **expression**, not a string literal, so it resolves to
    /// `Text.init<S: StringProtocol>(_:)` instead of `Text.init(_ key: LocalizedStringKey)` — and
    /// only the `LocalizedStringKey` initialiser runs SwiftUI's markdown parser. Four shipped
    /// strings hit this, including onboarding step 2 of 5, and drew their asterisks and backticks
    /// as literal characters.
    ///
    /// The idiom is not banned outright: joining two plain sentences across a line is fine and the
    /// app does it in about thirty places. What is banned is joining a string that *contains*
    /// markdown, because that string is silently not markdown any more.
    @Test func noConcatenatedTextCarriesMarkdown() throws {
        var offenders: [String] = []

        for file in try Self.swiftFiles() {
            var index = 0
            while index < file.lines.count {
                guard file.lines[index].contains("Text(\"") else {
                    index += 1
                    continue
                }
                // The whole expression: this line plus every following `+ "…"` continuation.
                var chunk = file.lines[index]
                var end = index + 1
                while end < file.lines.count,
                      file.lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("+ \"") {
                    chunk += file.lines[end]
                    end += 1
                }
                let concatenated = end > index + 1
                let markdown = chunk.contains("`") || chunk.contains("**")
                if concatenated, markdown {
                    offenders.append("\(file.name):\(index + 1)  \(file.lines[index].trimmingCharacters(in: .whitespaces))")
                }
                index = max(end, index + 1)
            }
        }

        #expect(offenders.isEmpty, """
            These render their markdown as literal characters. `Text("…" + "…")` is an expression, \
            so SwiftUI's automatic markdown parsing never applies — write one string literal \
            (a `\"""` literal with `\\` line continuations reads the same and keeps the parsing):
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// `.opacity()` applied on top of `.glassEffect()` fades the **material**, not the content
    /// sitting on it: at 0.6 the floating panel became a 60%-alpha wash over an *unblurred*
    /// backdrop, so 40% of the raw video behind it punched through and collided with the notes.
    ///
    /// The blur is the only reason the panel is legible over arbitrary video, so it is
    /// unconditional. "More transparent at rest, firms up when you type" is a fill *between* the
    /// glass and the content — see `NotesPanelView.body`.
    @Test func panelGlassIsNeverFaded() throws {
        let source = try String(
            contentsOf: Self.appSources.appendingPathComponent("NotesPanel.swift"),
            encoding: .utf8
        )
        // Comments stripped: the fix's own comment quotes the code it replaced, and a guard that
        // trips on its own explanation is a guard nobody keeps.
        let lines = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        // A line that *begins* `.opacity(` is a view modifier applied to whatever the chain has
        // built so far — glass included. `.background(shape.fill(.background.opacity(…)))` is a
        // nested call on a colour, which is the layer that is allowed to vary and does.
        let faded = lines.enumerated()
            .filter { $0.element.trimmingCharacters(in: .whitespaces).hasPrefix(".opacity(") }
            .map { "NotesPanel.swift:\($0.offset + 1)" }
        #expect(faded.isEmpty, """
            An .opacity() modifier in the panel's own chain fades the material and takes the blur \
            with it: \(faded.joined(separator: ", ")). Vary the scrim between the glass and the \
            content instead.
            """)

        #expect(
            lines.contains { $0.contains(".glassEffect(") },
            "the panel has to have glass at all for any of this to mean anything"
        )
        for line in lines where line.contains(".glassEffect(") {
            #expect(
                !line.contains("writing"),
                "the material itself must not be conditional on focus — only the scrim on it is"
            )
        }
    }

    // MARK: - The window has to say what the CLI says

    static func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    /// `transcript_issues` was read by the CLI and by nothing in the app.
    ///
    /// So in the window — the surface a person actually looks at — a meeting whose microphone
    /// handed the recorder pure digital silence was indistinguishable from one that recorded
    /// perfectly: same `ready` state, same transcript section, same summary drawn from half a
    /// conversation. That is the entire failure the issues table was built to end, still live in
    /// the one place it does the most damage.
    ///
    /// Three things have to be wired for the window to say it, and this checks each is still
    /// attached rather than that the pixels look right. A UI test target for `MeetingsApp` is a
    /// `Package.swift` change this unit does not own.
    @Test func theWindowReadsAndShowsTranscriptIssues() throws {
        let model = try Self.source("AppModel.swift")
        #expect(model.contains("store.transcriptIssues(meetingID:"),
                "AppModel has to read the issues for the selected meeting, beside its segments")
        #expect(model.contains("store.meetingIDsWithTranscriptIssues()"),
                "and the set for the list, in one query rather than one per row")

        let detail = try Self.source("MeetingDetailView.swift")
        #expect(detail.contains("TranscriptIssueBanner(issues:"),
                "the detail view has to draw the banner")

        let list = try Self.source("MeetingListView.swift")
        #expect(list.contains("TranscriptIssueMark()"), "the list row has to carry the mark")
        #expect(list.contains("transcriptIssueLegend(shownWhen:"),
                "and the legend saying what the mark means — a glyph with no key is the CLI's asterisk")
    }

    /// The kind set grows: `capture` and `transcription` today, `vocabulary` landing beside this.
    /// A build that meets a kind it has never heard of has to show it, not crash on it or guess at
    /// it — so nothing in the app may `switch` over `TranscriptIssue.Kind`, and the wording of each
    /// line has to come from MeetingsCore's own `sentence`.
    @Test func theAppNeverSwitchesOverTheKindsOfTranscriptIssue() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles() {
            for (index, line) in file.lines.enumerated()
            where line.contains("switch") && line.contains(".kind") {
                offenders.append("\(file.name):\(index + 1)  \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, """
            An exhaustive switch over TranscriptIssue.Kind stops compiling — or worse, stops being \
            exhaustive — the moment a kind is added. Read `issue.sentence`, or test membership of a \
            named set: \(offenders.joined(separator: "\n"))
            """)
        #expect(try Self.source("TranscriptIssueViews.swift").contains("issue.sentence"),
                "the banner's wording is MeetingsCore's to keep current, not the app's to invent")
    }

    /// The app's copy of the recogniser's minimum term length, checked against the real one.
    ///
    /// `VocabularyBiasing.minimumTermLength` is internal to MeetingsCore, so the Settings pane
    /// cannot import it and holds a literal instead. Two copies of a number drift; this is what
    /// stops them. (The CLI's copy is held to the same boundary by `CLIVocabularyTests`, which
    /// drives the real binary rather than reading its source.)
    @Test func theSettingsPaneUsesTheRecognisersOwnMinimumTermLength() throws {
        let source = try Self.source("SettingsView.swift")
        #expect(
            source.contains("static let minimumTermLength = \(VocabularyBiasing.minimumTermLength)"),
            """
            Settings refuses terms at a different length from the one the recogniser drops them at, \
            so the pane is either refusing terms that would have worked or listing terms as active \
            that never reach the transcriber.
            """
        )
        #expect(source.contains("VocabularyRules.refusal(for:"),
                "and the Add button has to actually consult it")
    }

    /// `AppModel.loaded`'s own comment claimed every empty state in the window was gated on it, and
    /// two were not: the sidebar's "No folders yet" and search's "No matches", both of which are
    /// statements about the user's data made before the store had been read once.
    @Test func theEmptyStatesThatSpeakForTheStoreAreGatedOnTheFirstRead() throws {
        let sidebar = try Self.source("SidebarView.swift")
        #expect(sidebar.contains("if model.loaded, model.folders.isEmpty"),
                "\"No folders yet\" over an unread store is a false statement about the user's data")

        // Search's own branch, in the ⌘K palette since search stopped being a toolbar field: the
        // loading state has to be reached before the "No matches" state, or the gate is decorative.
        let palette = try Self.source("SearchPalette.swift")
        let results = try #require(palette.range(of: "private var results: some View"))
        let untilNoMatches = try #require(palette.range(of: "title: \"No matches\"", range: results.upperBound..<palette.endIndex))
        let branch = String(palette[results.upperBound..<untilNoMatches.lowerBound])
        #expect(branch.contains("if !model.loaded"),
                "search answers \"nothing contains that\" before it has read anything")
    }

    /// The wizard's fourth page and Settings ▸ AI configure the same two modes, and they have to do
    /// it through the same views over the same settings rows.
    ///
    /// A second set of fields with its own state is how the two surfaces come to disagree about what
    /// is configured — the wizard showing a base URL that Settings does not, because one of them
    /// wrote to a copy. There is no UI test target to open both windows, so this checks the wiring.
    @Test func theWizardAndSettingsConfigureTheAIModesThroughTheSameFields() throws {
        let settings = try Self.source("SettingsView.swift")
        #expect(settings.contains("struct LocalAgentCommandFields"), "the shared fields live in Settings")
        #expect(settings.contains("struct CloudProviderFields"))
        for surface in ["SettingsView.swift", "OnboardingView.swift"] {
            let source = try Self.source(surface)
            #expect(source.contains("LocalAgentCommandFields(store:"), "\(surface) has to draw the shared fields")
            #expect(source.contains("CloudProviderFields(store:"), "\(surface) has to draw the shared fields")
        }
        // And both verify buttons are MeetingsCore's one check, not two lookalikes.
        #expect(settings.contains("AIVerify.localAgent(template:"))
        #expect(settings.contains("AIVerify.cloud(store:"))
    }

    /// The line offered for pasting and the command Mode B execs are two settings, and the window
    /// has to keep them apart.
    ///
    /// They were one, and the one value could not be right for both: `claude -p …` execs correctly
    /// and starts a *fresh headless run*, which is the exact thing somebody pasting into a session
    /// they already have open is avoiding, while `/meetings …` pastes correctly and execs nothing.
    /// Merging them back together is a one-line change with no visible symptom until a write-up
    /// silently costs money or silently never happens.
    @Test func theCopiedCommandAndTheExecutedCommandStayTwoSettings() throws {
        let model = try Self.source("AppModel.swift")
        #expect(model.contains(".aiManualPasteCommand"), "the card offers the pasteable line")
        #expect(!model.contains(".aiLocalAgentRunCommand"),
                "the card must never offer the exec'd command, which starts a fresh headless run")

        let settings = try Self.source("SettingsView.swift")
        #expect(settings.contains("SettingBinding(store: store, key: .aiManualPasteCommand)"))
        #expect(settings.contains("SettingBinding(store: store, key: .aiLocalAgentRunCommand)"))
        // Only Mode B's command is checkable: a verify beside the pasteable one would resolve a
        // slash command as a binary and report it missing.
        let paste = try #require(settings.range(of: "struct ManualPasteCommandFields"))
        let nextType = try #require(settings.range(of: "\nstruct ", range: paste.upperBound..<settings.endIndex))
        #expect(!settings[paste.upperBound..<nextType.lowerBound].contains("AIVerify"),
                "a slash command cannot be resolved as a binary, so it gets no verify button")
    }

    /// "The only mode that sends a transcript off this Mac", on the Cloud card, was false.
    ///
    /// Mode B runs whatever command is configured and the shipped default is `claude -p`, which
    /// sends the whole transcript to Anthropic. Read on the page where the three modes are chosen,
    /// that sentence was a privacy assurance about Mode B that the product does not keep, and
    /// somebody picking Local agent to keep their data local was misled by us.
    @Test func noSurfaceClaimsCloudIsTheOnlyModeThatSendsATranscriptAway() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles() {
            for (index, line) in file.lines.enumerated() {
                // Comments stripped: the fix's own comment quotes the copy it replaced, and a guard
                // that trips on its own explanation is a guard nobody keeps.
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                if line.contains("off this Mac") || line.contains("only mode") {
                    offenders.append("\(file.name):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, """
            Mode B sends the transcript wherever the configured command sends it, so no surface may \
            imply Cloud is the only one that leaves the Mac: \(offenders.joined(separator: ", "))
            """)

        // And the truth is stated on Local agent rather than left as an absence. Matched on the
        // clause's last few words, because the sentence is joined across two source lines.
        for surface in ["OnboardingView.swift", "SettingsView.swift"] {
            #expect(
                try Self.source(surface).contains("the command you set"),
                "\(surface) has to say that Mode B's reach depends on the command"
            )
        }
    }

    /// Upcoming is a list of store rows, and the window's look-ahead is the same setting the CLI
    /// reads. There is no test target that can open the window, so this checks the wiring.
    ///
    /// Both halves were separate copies of the same seven days: `AppModel.loadUpcoming` hardcoded
    /// its horizon and `UpcomingCommand` hardcoded a `--days` default, so widening one left the two
    /// surfaces disagreeing about what "coming up" means. `CalendarSync.lookAheadDays` is the one
    /// answer, and the window has to ask it rather than compute its own.
    @Test func theWindowSyncsTheCalendarAndTakesItsHorizonFromTheSetting() throws {
        let model = try Self.source("AppModel.swift")
        #expect(model.contains("CalendarSync.lookAheadDays(in: store)"),
                "the window has to read the same setting the CLI reads, not a literal seven")
        #expect(model.contains("CalendarSync(store: store, calendar: calendarSource)"),
                "and give every calendar meeting in that window a row")
        #expect(model.contains("store.meetings(state: .scheduled)"),
                "Upcoming reads rows out of the store, not events out of EventKit")

        let settings = try Self.source("SettingsView.swift")
        #expect(settings.contains("SettingBinding(store: model.store, key: .calendarLookAheadDays)"),
                "a setting the CLI can write and the window cannot is a setting nobody finds")
    }

    /// The calendar-event row and its read-only pane are gone, and must not come back.
    ///
    /// While they existed a person looking at next Tuesday's meeting was looking at a thing that
    /// could not be filed, could not be renamed, and needed a "materialise" step nobody should have
    /// had to know about. A second kind of row in the list is what forced all three.
    @Test func nothingInTheWindowStillTreatsACalendarEventAsAKindOfRow() throws {
        var offenders: [String] = []
        for file in try Self.swiftFiles() {
            for (index, line) in file.lines.enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                if line.contains("RowID") || line.contains("selectedEvent") || line.contains("EventDetailView") {
                    offenders.append("\(file.name):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, """
            Upcoming lists store rows now, so selection is a meeting id and every pane is a meeting \
            pane: \(offenders.joined(separator: ", "))
            """)
    }

    /// The palette may never become a sheet.
    ///
    /// AppKit refuses to terminate an app that has a sheet attached, and it refuses *before* the
    /// application delegate is consulted — there is no `applicationShouldTerminate` to intervene in.
    /// A sheet here would therefore make ⌘Q, the Quit menu item and macOS's own "Quit & Reopen"
    /// silently do nothing for as long as search was open. It is an overlay for that reason, and
    /// the reason is invisible in the diff that would undo it.
    @Test func theSearchPaletteIsNeverPresentedAsASheet() throws {
        let palette = try Self.source("SearchPalette.swift")
        #expect(!palette.contains(".sheet("),
                "a sheet blocks app termination before any code of ours runs")

        let app = try Self.source("MeetingsApp.swift")
        let mount = try #require(app.range(of: "SearchPalette(model: model)"))
        // The 400 characters before it: the presenting modifier, whatever it is.
        let before = String(app[app.index(mount.lowerBound, offsetBy: -400)..<mount.lowerBound])
        #expect(before.contains(".overlay {"),
                "the palette has to be ordinary window content, not a presented surface")
    }

    /// ⌘K searched only the folder the sidebar happened to be sitting on.
    ///
    /// `AppModel.runSearch` handed `folderID: scope.folderID` to the store, so with a folder
    /// selected the palette searched inside that folder and nowhere else — while `meetings search`
    /// searches the whole store unless it is given `--folder`. A meeting the CLI finds by name was
    /// simply not there, and the palette answered "No meeting name, transcript, note, pre-meeting
    /// note or summary contains X": a claim about the whole store, made about one folder, with
    /// nothing on screen to say a filter was on or any way to take it off.
    ///
    /// It was never a decision, which is why it disagreed with itself: `.all`, `.needsWriteUp`,
    /// `.unfiled` and `.upcoming` all carry a nil `folderID`, so four of the five kinds of sidebar
    /// row searched everything and the fifth quietly did not. `openHighlightedResult` already
    /// widens the scope for a hit that has no row in the current list, so reaching outside what you
    /// are looking at is what the palette was built to do.
    @Test func theSearchPaletteSearchesTheWholeStoreRatherThanTheSelectedFolder() throws {
        let model = try Self.source("AppModel.swift")
        let scoped = model.components(separatedBy: "\n").enumerated()
            .filter { $0.element.contains(".search(query:") && $0.element.contains("folderID") }
            .map { "AppModel.swift:\($0.offset + 1)" }
        #expect(scoped.isEmpty, """
            The palette's search is scoped to the sidebar's folder: \(scoped.joined(separator: ", ")). \
            ⌘K is the way to reach a meeting you are not already looking at, and its "No matches" \
            speaks for the whole store — pass no folder, the way `meetings search` takes none.
            """)
    }

    /// Every one of these is a key the palette answers to, and search that needs the mouse in the
    /// middle of it is search nobody uses. There is no UI test target to press them for real, so
    /// this checks each is still wired to the model call that moves or commits the highlight.
    @Test func theSearchPaletteStaysDrivableFromTheKeyboardAlone() throws {
        let palette = try Self.source("SearchPalette.swift")
        for wiring in [
            ".onKeyPress(.upArrow) { model.moveSearchHighlight(by: -1)",
            ".onKeyPress(.downArrow) { model.moveSearchHighlight(by: 1)",
            ".onKeyPress(.escape) { model.closeSearchPalette()",
            ".onSubmit { model.openHighlightedResult() }",
        ] {
            #expect(palette.contains(wiring), "the palette lost its keyboard wiring: \(wiring)")
        }
    }

    /// The summary and the pre-notes are the same problem — a column the CLI writes while the user
    /// is typing into it — and it is answered once. A summary rendered through `MarkdownText`
    /// again is read-only, which is the defect; a summary given its own editor is a second answer
    /// that will drift from the first. Both have to be the one `SharedFieldEditor`.
    @Test func bothFieldsWithTwoWritersUseTheOneEditor() throws {
        let detail = try Self.source("MeetingDetailView.swift")
        let mount = try #require(
            detail.range(of: "SharedFieldEditor("),
            "the write-up went back to being read-only"
        )
        let arguments = String(detail[mount.upperBound...].prefix(400))
        #expect(arguments.contains("title: \"Summary\""))
        #expect(arguments.contains("value: meeting.summary ?? \"\""))
        #expect(arguments.contains("model.saveSummary(meetingID:") || detail.contains("save: saveSummary"),
                "the editor has to write back through the model")

        // And the state rule stays the store's, not a copy in the window: clearing the write-up
        // moves the meeting back, and `meetings summary set` already knows how.
        let model = try Self.source("AppModel.swift")
        #expect(model.contains("setSummary("),
                "the app must clear a summary through Meeting.setSummary, not by nilling the field")

        let editor = try Self.source("PreNotesEditor.swift")
        #expect(editor.contains("SharedFieldEdit.receive("),
                "the conflict decision belongs to MeetingsCore, where it is tested")
    }

    /// The write-up is the surface this screen exists for, and the layout has to say so.
    ///
    /// It did not: the transcript and the notes sat above the fold at full height and the summary
    /// got a 360 pt slot they pushed off screen. The three sections that outrank nothing are
    /// collapsed now, each with its count on the closed row so nothing is hidden silently — and a
    /// note whose click scrolls the transcript has to open it first, or the jump lands on rows that
    /// are not laid out and does nothing at all.
    @Test func theWriteUpOutranksTheTranscriptAndTheNotes() throws {
        let detail = try Self.source("MeetingDetailView.swift")
        for section in ["title: \"Transcript\"", "title: \"Your notes\"", "title: \"Pre-meeting notes\""] {
            let mount = try #require(detail.range(of: section), "\(section) went missing")
            // The 200 characters before it: whatever is presenting the section.
            let before = String(detail[detail.index(mount.lowerBound, offsetBy: -200)..<mount.lowerBound])
            #expect(before.contains("SecondarySection("),
                    "\(section) is drawn at full height above the write-up again")
        }
        #expect(detail.contains("showTranscript = true"),
                "clicking a note has to open the transcript it is about to scroll")

        // And the write-up has no height of its own at all.
        //
        // This used to require a `.frame(height:)` larger than the 360 pt slot that started it. The
        // number was always a workaround for an editor that could not say how tall it was, and at
        // 520 pt it cut a heading in half across the boundary while scrolling separately from the
        // page it sits on. Any fixed height here is that bug, whatever the number is.
        let mount = try #require(detail.range(of: "SharedFieldEditor("))
        let after = String(detail[mount.upperBound...].prefix(900))
        #expect(!after.contains(".frame(height: "), """
            The write-up is back in a fixed-height box. It is a document: it is as tall as what is \
            written in it, and the page is the one thing that scrolls.
            """)
    }

    /// The write-up grows with its document, and the page is the only thing that scrolls.
    ///
    /// Two defects, one cause. The editor wrapped `NSTextView.scrollableTextView()`, so there was an
    /// `NSScrollView` inside the detail pane's own `ScrollView` — a trackpad drag had to guess which
    /// one it meant — and because that wrapper's ideal height inside a scroll view is arbitrary, the
    /// write-up was pinned to a magic 520 pt that sliced a heading horizontally in half.
    ///
    /// The fix is for the view to answer the question instead of being told: `sizeThatFits` reports
    /// the height TextKit 2 actually laid the document out to, so it grows as lines are typed and
    /// shrinks as they are deleted. Measured on this engine at a 520 pt measure: an empty document
    /// is 28 pt, ten lines 172 pt, forty lines 652 pt — and the same forty-line document is 236 pt
    /// at 520 pt wide against 492 pt at 260 pt wide, so it rewraps rather than clipping.
    @Test func theWriteUpGrowsWithItsDocumentRatherThanScrollingInsideThePage() throws {
        let editor = try Self.source("MarkdownTextView.swift")
        #expect(!editor.contains("let scroll = NSTextView.scrollableTextView()"),
                "a scroll view inside the page's scroll view is two surfaces and one ambiguous drag")
        #expect(!editor.contains("func makeNSView(context: Context) -> NSScrollView"),
                "the representable is the text view itself now")
        #expect(editor.contains("func sizeThatFits("),
                "the editor has to report its own height, or the parent has to invent one")
        #expect(editor.contains("usageBoundsForTextContainer"),
                "the height is what TextKit 2 laid out, measured, not a constant")
        #expect(editor.contains("layout.ensureLayout(for: layout.documentRange)"),
                "layout is lazy — measuring before it runs reports the height of nothing")
        #expect(editor.contains("widthTracksTextView = true"),
                "the height is only right if the container rewraps to the width being measured")

        // Every other home of the same editor gained the page scroll the write-up already had, so
        // "one scrolling surface" is the rule everywhere rather than a special case in one pane.
        for home in ["NotesPanel.swift", "RecordingDetailView.swift", "PreNotesEditor.swift"] {
            let source = try Self.source(home)
            let mount = try #require(source.range(of: "PreNotesEditor("), "\(home) lost its editor")
            let before = String(source[source.startIndex..<mount.lowerBound])
            #expect(before.contains("ScrollView {"), """
                \(home) hosts the editor with nothing to scroll. The editor is the height of its \
                document now, so a document taller than the pane has nowhere to go.
                """)
        }
    }

    /// Actions are **task list items inside the write-up**, and the checklist that used to sit
    /// under it is gone — with it, the two guards that used to live here.
    ///
    /// `aLongActionKeepsItsOwner` pinned the layout of an `ActionRow`'s `TextField` against the
    /// owner column beside it; there is no row and no owner column, and an action's text is a line
    /// of markdown that wraps like every other line. `theActionsAreEditableInTheWriteUp…` pinned
    /// `AppModel.saveActions` and its compare-and-set; ticking a box is an edit to the summary now,
    /// and it goes through the write path that field already had.
    ///
    /// What replaces both is the invariant that actually matters: the chrome is gone, one edit path
    /// remains, and the checkbox is a real control drawn over characters that never move.
    @Test func theActionsAreTheDocumentAndTheChromeIsGone() throws {
        // Comments stripped: the note left where the checklist used to be names every type it
        // replaced, and a guard that trips on its own explanation is a guard nobody keeps.
        let detail = try Self.source("MeetingDetailView.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for vanished in ["struct ActionChecklist", "struct ActionRow", "Add an action",
                         "Delete this action", "ActionChecklist(actions:"] {
            #expect(!detail.contains(vanished), """
                \(vanished) is chrome for a list that no longer exists. Adding an action is typing \
                `- [ ] `, and deleting one is deleting the line.
                """)
        }

        // And no second write path for them. `saveActions` and its compare-and-set existed because
        // the `actions` column had two writers and no other guard; the summary has `SharedFieldEdit`.
        let model = try Self.source("AppModel.swift")
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!model.contains("func saveActions("), """
            A second mechanism for the same two-writer problem is one more than can be reasoned \
            about. A tick is an edit to the write-up, and SharedFieldEdit already decides what \
            happens when somebody else wrote while the user was typing.
            """)
        #expect(model.contains("func saveSummary(meetingID: String, text: String)"),
                "which leaves the one write path the write-up already had")

        // The checkbox itself: a real control over the characters, never instead of them.
        let editor = try Self.source("MarkdownTextView.swift")
        #expect(editor.contains("MarkdownSyntax.taskItem("),
                "what counts as a task list item is MeetingsCore's decision, where it is tested")
        #expect(editor.contains("MarkdownEditing.toggleTask("), """
            Ticking goes through the same edit path as typing, or it is not undoable and it does \
            not autosave.
            """)
        #expect(editor.contains("override func mouseDown"), "and the click has to be hit-tested")
        #expect(editor.contains("value: NSColor.clear, range: range(task.box)"), """
            The box is drawn transparent at its own width — the three characters stay in the \
            string, at the same offsets, which is the rule that protects the caret.
            """)
    }

    /// The summary renders its markdown as it is typed, and it does it with the platform's own text
    /// engine rather than a second one of our own.
    ///
    /// The characters on screen have to stay the characters in the store, at the same offsets —
    /// hiding a `##` means keeping two documents in step, which is how a caret comes to land a
    /// character off from where it was clicked.
    ///
    /// This used to pin `TextEditor(text:selection:)` by name. It now pins the *invariant* that
    /// spelling stood for, because the spelling had to change: SwiftUI's attributed `TextEditor`
    /// works in a scope with no paragraph-style key, so a hanging indent is not expressible in it,
    /// and its selection carries no geometry for the toolbar to anchor to. What must not change is
    /// that the engine is AppKit's — one `NSTextView`, its own caret, its own undo — and that the
    /// value of record stays the plain `String` the CLI writes.
    @Test func theEditorRendersMarkdownWithoutASecondTextModel() throws {
        let editor = try Self.source("MarkdownTextView.swift")
        #expect(editor.contains("NSViewRepresentable") && editor.contains("NSTextView(frame: .zero)"),
                "the engine is AppKit's own text view — nothing here rolls its own")
        #expect(editor.contains("MarkdownSyntax.line(") && editor.contains("MarkdownSyntax.inline("),
                "what counts as markdown is MeetingsCore's decision, where it is tested")

        // The value of record. Everything above this view — autosave, the two-writer banner, the
        // oversize guard — works off a `String`, and an editor that started holding the truth in an
        // attributed form would take all three with it.
        let mount = try #require(try Self.source("PreNotesEditor.swift").range(of: "LiveMarkdownEditor(text: $text)"))
        #expect(mount.isEmpty == false)
        #expect(editor.contains("@Binding var text: String"),
                "the store still holds the string the CLI writes, not an attributed one")
        #expect(editor.contains("parent.text = now"),
                "what the user typed is pushed back up as characters")

        // TextKit 2, not the legacy layout manager — asking for `NSLayoutManager` on macOS 26
        // drags the text view back onto the compatibility engine.
        #expect(editor.contains("textLayoutManager"),
                "selection geometry comes from NSTextLayoutManager")
        // The TextKit 1 accessor, which is what silently drops the view onto the old engine.
        #expect(!editor.contains(".layoutManager"), "TextKit 1 would be a downgrade, not a fallback")

        // The *other* way onto the old engine, and it does not look like one. Measured on macOS 26:
        // a subclass of `NSTextView` that overrides `draw(_:)` comes back with `textLayoutManager`
        // **nil** — the whole view silently falls to TextKit 1, taking the gutter's measurements,
        // the document height and the rects the toolbar and the slash menu hang off with it.
        // `drawBackground(in:)` is the hook that does not, which is where the checkbox is painted.
        #expect(!editor.contains("override func draw(_ dirtyRect"), """
            Overriding draw(_:) on an NSTextView drops it to TextKit 1 on macOS 26 — measured: \
            textLayoutManager comes back nil. Paint in drawBackground(in:) instead.
            """)
    }

    /// Undo has to survive, and the two ways to lose it are both here.
    ///
    /// Writing the whole string back into the text view on every change is the first: SwiftUI hands
    /// the binding back down after every keystroke, and a view that obeys it flattens the undo
    /// stack into one blob. Changing text behind the user's back without telling AppKit is the
    /// second: a list continuation that skips `shouldChangeText` is a change ⌘Z cannot reach.
    @Test func undoSurvivesBothWaysOfLosingIt() throws {
        let editor = try Self.source("MarkdownTextView.swift")
        #expect(editor.contains("textView.allowsUndo = true"))
        #expect(editor.contains("guard textView.string != text else { return }"),
                """
                Without this guard the view writes the document back to itself on every keystroke, \
                and every one of them lands as a single undo step over the whole string.
                """)
        let apply = try #require(editor.range(of: "func apply(_ edit: MarkdownEditing.Edit)"))
        let body = String(editor[apply.upperBound...].prefix(700))
        #expect(body.contains("shouldChangeText(in: range, replacementString: edit.replacement)"),
                "a follow-up edit has to be registered with AppKit or ⌘Z cannot reach it")
        #expect(body.contains("textView.didChangeText()"),
                "and the change has to be closed, or it never lands on the undo stack")

        // Restyling is attributes only, and attributes are not text — so none of it is undoable,
        // and ⌘Z after typing a `#` undoes the character rather than the colour it caused.
        #expect(editor.contains("storage.beginEditing()") && editor.contains("storage.endEditing()"))
    }

    /// The gutter is drawn with **attributes**, never by taking characters out.
    ///
    /// Hiding a marker by deleting it from the drawn text is the one thing this editor must not do:
    /// the document on screen would then have different offsets from the document in the store, and
    /// that is precisely what makes a caret land a character off. The markers stay; a `kern` pads
    /// them out to a common width and a `foregroundColor` dims them, and both are restyles the
    /// existing `transform(updating:)` already keeps the selection valid across.
    @Test func theGutterIsAnAttributeAndNotACharacterEverRemoved() throws {
        let editor = try Self.source("MarkdownTextView.swift")
        #expect(editor.contains("MarkdownSyntax.blockMarker("),
                "which characters go in the gutter is MeetingsCore's decision, where it is tested")
        #expect(editor.contains("MarkdownSyntax.markers("),
                "which characters dim is MeetingsCore's decision too")

        // The gutter is a paragraph property. It is the only thing that can put a line with *no*
        // marker on the same left edge as one with a six-character marker, because there is no
        // character in front of a paragraph to pad.
        #expect(editor.contains("style.firstLineHeadIndent") && editor.contains("style.headIndent"),
                "the gutter is a hanging indent")
        #expect(editor.contains("MarkdownSyntax.gutterIndent("),
                "the indent arithmetic is MeetingsCore's, where it is tested")
        // And the padding hack it replaced is gone rather than left alongside it.
        #expect(!editor.contains(".kern"),
                "two mechanisms for one gutter is one more than can be reasoned about")

        // Never characters. The storage is only ever handed attributes by the styling pass; the one
        // place characters change is `apply`, which is the user's own edit going through undo.
        #expect(!editor.contains("MarkdownStyle") || !editor.contains("replaceCharacters(in: whole"),
                "styling must never remove a marker from the document")

        // The styling function is handed the caret so it knows which line to reveal, and the
        // selection changing has to restyle or the reveal never moves off the first line.
        #expect(editor.contains("caret utf16: Int?"), "the reveal needs to know where the caret is")
        #expect(editor.contains("func textViewDidChangeSelection"),
                "moving the caret changes which line is revealed")

        // The container is gone. A box around the write-up made it read as one field on a form.
        let pane = try Self.source("PreNotesEditor.swift")
        #expect(!pane.contains(".background(.quaternary.opacity(0.35)"),
                "the write-up sits on the pane, not in a filled box")
        #expect(pane.contains("maxWidth: Self.column"),
                "the document is a centred measure, not the full width of a wide window")
    }

    /// Inline markers are **hidden** off the caret's line; block markers stay dim in the gutter.
    ///
    /// Dimming was not enough. A dimmed `**` still occupies its two characters, so bold text read as
    /// punctuation with a word inside it and the surface still looked like source waiting to be
    /// rendered. Hidden here means a hair-sized transparent font over characters that are all still
    /// in the string — measured, `make it **bold** now` draws 102.38 pt with the markers hidden
    /// against 102.36 pt with the four characters actually deleted, and 126.58 pt when they are
    /// merely coloured clear. Colour alone hides nothing; it leaves the gap.
    ///
    /// Nothing is removed, which is the rule that protects the caret: the drawn document and the
    /// stored document keep identical offsets. And a line the caret is on reveals its markers at
    /// full size, so the caret can never sit inside a hair-sized run.
    @Test func inlineMarkersAreHiddenAndBlockMarkersStayInTheGutter() throws {
        let editor = try Self.source("MarkdownTextView.swift")
        #expect(editor.contains("static let hiddenFont = NSFont.systemFont(ofSize: 0.01)"), """
            An inline marker is hidden by drawing it at no width. `ofSize: 0` is not that — AppKit \
            reads zero as "the default size" and would draw the markers full size.
            """)
        #expect(editor.contains("value: NSColor.clear"), "and transparent, so no ghost of it remains")

        // The split. `markers` merges ranges that touch, so `- **bold**` arrives as one span across
        // the bullet and the opening delimiters; the gutter's end is where the two treatments part.
        #expect(editor.contains("let blockEnd = MarkdownSyntax.blockMarker(line)?.upperBound ?? 0"), """
            Without the split a bullet touching a bold run is hidden along with it, and the gutter \
            — the whole point of the design — silently loses its marker.
            """)
        #expect(editor.contains("if span.lowerBound < blockEnd"),
                "the part of the span inside the gutter stays visible and dim")

        // Still never characters. This is the same rule the gutter test pins, restated for the one
        // change that would have been most tempting to make by deleting text.
        #expect(!editor.contains("deleteCharacters") && !editor.contains("replacingOccurrences(of: \"**\""),
                "hiding a marker by removing it is two documents to keep in step, and a caret a character off")
    }

    /// The write-up is read at a measure, and everything on the screen shares its edge.
    ///
    /// It was the full detail column: 656 pt, which at the 13 pt body font this app draws — 5.96 pt
    /// average advance, measured — is about 110 characters a line. Roughly double a comfortable
    /// measure, and the reason the surface read as a wide text field rather than as a document; the
    /// gutter alignment it was built around is invisible at that width.
    ///
    /// 40rem, where a rem is the app's own body text, so it tracks the system text size instead of
    /// being right at exactly one of them. At the default that is 520 pt, about 87 characters.
    @Test func theWriteUpIsReadAtAMeasureAndTheActionsShareItsColumn() throws {
        let pane = try Self.source("PreNotesEditor.swift")
        #expect(pane.contains("static var column: CGFloat { 40 * MarkdownStyle.bodyFont.pointSize }"), """
            The measure is 40rem of this app's own body text. A hardcoded point size is right at \
            one system text size and wrong at every other.
            """)
        #expect(pane.contains("static var bodyEdge: CGFloat { editorInset + MarkdownStyle.gutter }"),
                "anything lining up with the prose measures the gutter rather than guessing at it")

        let detail = try Self.source("MeetingDetailView.swift")
        #expect(detail.contains("static var documentWidth: CGFloat { SharedFieldEditor.column"), """
            The title, the chips, the write-up and the actions are one column. Two widths that \
            nearly agree read as a misalignment, which is what a document must not have.
            """)
        #expect(detail.contains(".frame(maxWidth: .infinity, alignment: .center)"),
                "the leftover width of a wide pane is margin, not a longer line")

        // The actions need no column of their own any more: they are lines of the write-up, so they
        // are read at the write-up's measure by construction. Nothing may re-introduce a second
        // block beside it.
        #expect(!detail.contains("SectionHeader(title: \"Actions\""), """
            A section label over a filled block is what made the actions read as their own panel. \
            In the document they are a `## Actions` the author wrote, like any other heading.
            """)
    }

    /// The write-up wears no panel chrome, and the meeting's facts are chips.
    ///
    /// A "Summary" caption and a permanent "Saved" over the document were the last of the form
    /// look — "Saved" is true almost always and therefore says nothing, so only the states that are
    /// *not* the resting state speak. The title still exists: it is what the field is called to
    /// VoiceOver, which is why it is passed and not deleted.
    @Test func theWriteUpIsTheSurfaceRatherThanAFieldOnAForm() throws {
        let detail = try Self.source("MeetingDetailView.swift")
        let mount = try #require(detail.range(of: "SharedFieldEditor("))
        let arguments = String(detail[mount.upperBound...].prefix(600))
        #expect(arguments.contains("titleShown: false"),
                "no section label over the write-up — the document is the surface")

        let pane = try Self.source("PreNotesEditor.swift")
        #expect(pane.contains(".accessibilityLabel(title)"),
                "dropping the visible label must not drop the field's name for VoiceOver")
        #expect(pane.contains("private var transientStatus: String?") && pane.contains("== \"Saved\" ? nil"),
                "the resting state is silent; saving, unsaved and conflicted are not")

        // The metadata run became chips, and the last of them files the meeting — through the same
        // model call the meeting row's context menu uses, not a second filing path.
        #expect(detail.contains("private struct MeetingChips: View"), "the metadata run became chips")
        #expect(detail.contains("Add to folder") && detail.contains("moveToFolder("),
                "filing is reachable from the write-up, not only from a right-click back in the list")
        let app = try Self.source("MeetingActions.swift")
        #expect(app.contains("model.move(meetingID: meeting.id, toFolder:"),
                "and it is the one move path, which the context menu still calls")
    }

    /// Both floating surfaces hang off a rect the text view measured, not off a corner of the pane.
    /// A menu that opens at the top-left while you are typing on line forty is a menu about
    /// somewhere else.
    @Test func theMenuAndTheToolbarAnchorToWhereTheTextActuallyIs() throws {
        let editor = try Self.source("MarkdownTextView.swift")
        #expect(editor.contains("enumerateTextSegments("),
                "the rects come from the layout manager rather than from a guess")
        #expect(editor.contains("@Binding var caretRect: CGRect?")
                && editor.contains("@Binding var selectionRect: CGRect?"))

        let pane = try Self.source("PreNotesEditor.swift")
        #expect(pane.contains("if let menu, let anchor = caretRect"),
                "the slash menu opens under the caret")
        #expect(pane.contains("if let anchor = selectionRect, !selection.isEmpty"),
                "the toolbar appears over the selection, and only over a real one")

        // **Where** it lands is a decision with tests behind it, not arithmetic buried in an
        // `alignmentGuide` closure nothing could reach. It was the latter, and it was unbounded:
        // a 280 pt toolbar centred on a selection at the left edge of the text computed a negative
        // origin, which is outside the document column and past the left edge of the split view's
        // detail pane — and an NSSplitView pane clips.
        #expect(pane.contains(".floating(over: anchor, in: width)"),
                "both surfaces go through the one placement, so they cannot disagree about it")
        #expect(pane.contains("MarkdownEditing.floating("),
                "and that placement is MeetingsCore's, where the clamp and the flip are tested")

        // An anchor is only as good as its freshness. Published from the selection delegate alone,
        // it went stale on any layout change — a resized pane, a re-wrapped document, or a
        // selection made before the text had been laid out at all, which leaves it nil forever.
        #expect(editor.contains("coordinator.publishRects()"), """
            The rects have to be republished when the layout changes, not only when the selection \
            does, or the toolbar hangs off where the text used to be — or off nothing.
            """)
    }

    /// Typing the shorthand, Return continuing a list and the slash menu are all one vocabulary,
    /// and every one of them is a pure function in `MeetingsCore` rather than a rule buried in a
    /// view where nothing can reach it.
    @Test func theEditorsTypingRulesLiveWhereTheyCanBeTested() throws {
        let engine = try Self.source("MarkdownTextView.swift")
        let pane = try Self.source("PreNotesEditor.swift")
        #expect(engine.contains("MarkdownEditing.followUp("),
                "list continuation and the shorthand are MeetingsCore's, where they are tested")
        #expect(pane.contains("MarkdownEditing.slashQuery("),
                "when the menu is open is a decision with tests behind it")
        #expect(pane.contains("MarkdownEditing.insert("),
                "and so is what choosing an item does")

        // Driven by what the text became, not by second-guessing which key produced it.
        #expect(engine.contains("before: before, after: now"),
                "a keystroke is read off the document rather than reconstructed from the event")

        // The menu's keys are taken at `doCommandBy`, which is a real interception point. The
        // previous build used SwiftUI's `onKeyPress` and hoped it would win the race against a
        // focused text view for Return and the arrows.
        #expect(engine.contains("func textView(_ textView: NSTextView, doCommandBy selector: Selector)"),
                "the slash menu's keys have to be taken where NSTextView offers them")
        for command in ["NSResponder.moveUp", "NSResponder.moveDown",
                        "NSResponder.insertNewline", "NSResponder.cancelOperation"] {
            #expect(engine.contains(command), "the slash menu lost its keyboard wiring: \(command)")
        }
        #expect(!pane.contains(".onKeyPress("), "onKeyPress on a focused text view is a race, not a binding")
    }

    /// One transform behind every surface that turns a line into a heading or a list.
    ///
    /// A menu that builds its own `"## "` and a toolbar that builds another is two definitions of
    /// Heading 2 that will disagree the first time either grows a rule — about indentation, about
    /// what happens to the marker already there.
    @Test func everyBlockTransformGoesThroughTheOneImplementation() throws {
        let chrome = try Self.source("MarkdownEditorChrome.swift")
        #expect(chrome.contains("MarkdownEditing.SlashCommand"),
                "the menu draws the commands MeetingsCore defines, it does not list its own")
        for hardcoded in ["\"## \"", "\"- [ ] \"", "\"# \""] {
            #expect(!chrome.contains(hardcoded),
                    "\(hardcoded) is built in the view instead of by MarkdownEditing.applyBlock")
        }

        // The toolbar is a third way to reach the same two functions, and it draws its pressed
        // state from the same question `toggle` asks — a button that says "on" while the shortcut
        // turns it on again is two answers to one question.
        #expect(chrome.contains("MarkdownEditing.isActive(mark, in: text, selection: selection)"),
                "the toolbar's pressed state has to come from MarkdownEditing, not from a guess")
        #expect(chrome.contains("MarkdownEditing.blockCommands"),
                "the turn-into buttons are the commands MeetingsCore defines")
        let pane = try Self.source("PreNotesEditor.swift")
        #expect(pane.contains("MarkdownEditing.applyBlock(command, in: text, replacing: selection)"),
                "the toolbar's block buttons go through the one transform the slash menu uses")

        // The formatting shortcuts are menu items, because the main menu is the one thing that
        // outranks a focused NSTextView for a key equivalent.
        #expect(chrome.contains("CommandMenu(\"Format\")"))
        for shortcut in [
            ".keyboardShortcut(key, modifiers: modifiers)",
            "\"b\", [.command]", "\"i\", [.command]",
            "\"s\", [.command, .shift]", "\"e\", [.command]", "\"k\", [.command, .shift]",
        ] {
            #expect(chrome.contains(shortcut), "the formatting shortcuts lost \(shortcut)")
        }
        // ⌘K stays Search. It opens from anywhere, the floating notes panel included, so the
        // editor does not get to take it away — link insertion is ⌘⇧K.
        let app = try Self.source("MeetingsApp.swift")
        #expect(app.contains(".keyboardShortcut(\"k\")"), "⌘K is still Search")
        #expect(!chrome.contains("\"k\", [.command]"), "link insertion must not shadow ⌘K")
        #expect(app.contains("MarkdownFormattingCommands()"), "the Format menu has to be mounted")
    }
}
