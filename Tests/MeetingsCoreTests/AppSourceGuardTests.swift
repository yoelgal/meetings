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

        // And the editor is taller than the 360 pt slot that started this.
        let mount = try #require(detail.range(of: "SharedFieldEditor("))
        let after = String(detail[mount.upperBound...].prefix(900))
        let height = try #require(after.range(of: ".frame(height: "))
        let value = Int(after[height.upperBound...].prefix { $0.isNumber }) ?? 0
        #expect(value > 360, "the write-up got its old two-line slot back")
    }

    /// Actions are a checklist you can actually work, in the same block as the write-up they came
    /// out of — and every one of tick, retype, add and delete writes the `actions` column the CLI
    /// reads, through the one path that refuses to clobber a list somebody else rewrote.
    @Test func theActionsAreEditableInTheWriteUpAndWriteBackToTheStore() throws {
        let detail = try Self.source("MeetingDetailView.swift")
        #expect(detail.contains("ActionChecklist(actions:"), "the checklist has to be drawn")
        #expect(detail.contains(".toggleStyle(.checkbox)"),
                "a glyph that looks like a control and is not one is the defect this replaced")

        // Inside the write-up's own block, not in a section of its own further down: the mount has
        // to come before the next section starts.
        let summary = try #require(detail.range(of: "title: \"Summary\""))
        let checklist = try #require(detail.range(of: "ActionChecklist(actions:", range: summary.upperBound..<detail.endIndex))
        let preNotes = try #require(detail.range(of: "title: \"Pre-meeting notes\"", range: summary.upperBound..<detail.endIndex))
        #expect(checklist.lowerBound < preNotes.lowerBound,
                "the actions belong with the write-up, not in a disconnected list below it")

        let model = try Self.source("AppModel.swift")
        #expect(model.contains("func saveActions(meetingID: String, from previous: [Action], to next: [Action])"),
                "one write path for all four edits, taking the list the window was showing")
        let save = try #require(model.range(of: "func saveActions("))
        let body = String(model[save.upperBound...].prefix(600))
        #expect(body.contains("guard (meeting.actions ?? []) == previous"),
                """
                Without the compare, a tick against a list `meetings actions set` has since \
                replaced puts back every row the agent removed and ticks whichever action moved \
                into that position.
                """)
        #expect(body.contains("next.isEmpty ? nil : next"),
                "empty stores as NULL, the shape `meetings actions set` writes")
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
        #expect(editor.contains("NSViewRepresentable") && editor.contains("NSTextView.scrollableTextView()"),
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
        #expect(editor.contains("textView.textLayoutManager"),
                "selection geometry comes from NSTextLayoutManager")
        // The TextKit 1 accessor, which is what silently drops the view onto the old engine.
        #expect(!editor.contains(".layoutManager"), "TextKit 1 would be a downgrade, not a fallback")
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
        #expect(pane.contains("anchor.minY < $0.height + 8"),
                "and it flips below the selection when there is no room above it")
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
