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

    static func source(_ name: String, in directory: String = "Sources/MeetingsApp") throws -> String {
        let root = appSources.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(directory).appendingPathComponent(name),
            encoding: .utf8
        )
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
    ///
    /// This reads one line at a time and so only catches the folder written on the same line as the
    /// call; ``thePaletteAsksTheStoreExactlyWhatTheCLIAsksIt`` reads the whole call expression and
    /// catches the same argument wrapped onto its own line, along with every other argument the CLI
    /// is never handed. This one stays because it names *which* argument shipped and why.
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

    /// The arguments of a call, from just after its `(` to the matching `)`, whitespace flattened.
    /// A call written across three lines and the same call written on one have to read identically
    /// here, or a guard on the arguments is a guard on the formatting.
    static func callArguments(_ text: String, from start: String.Index) -> String {
        var depth = 1
        var index = start
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            index = text.index(after: index)
        }
        return text[start..<index].split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The window and the CLI answer one query with one function, and the window shapes nothing.
    ///
    /// Twice now ⌘K and `meetings search` have disagreed about the same store, and both times the
    /// store was right and the window was asking it something else: first `folderID: scope.folderID`
    /// silently narrowed the search to the sidebar's folder, then the palette searched `ro` because
    /// it ran the read inside the keystroke that typed `or`. A divergence found by eye — one meeting
    /// in the window, a different meeting in the terminal — is expensive to trace and reads as data
    /// loss while it lasts, so the shape that makes it possible is what this pins.
    ///
    /// One call site, and its arguments are exactly the text in the field. No folder, no limit, no
    /// state, no trimming, no `*` appended, no second entry point, and no SQL of the app's own: any
    /// of those is a query the CLI cannot be handed, and therefore an answer the CLI cannot
    /// reproduce. Presentation is free to differ — the palette labels a `.title` hit "Meeting name"
    /// where the CLI prints `title` — because that happens on the *results*, after this call.
    @Test func thePaletteAsksTheStoreExactlyWhatTheCLIAsksIt() throws {
        let cli = try Self.source("SearchCommand.swift", in: "Sources/meetings")
        #expect(cli.contains("store.search(query: query"),
                "the CLI's search entry point moved — this guard is comparing against nothing")

        var callSites: [(file: String, arguments: String)] = []
        for file in try Self.swiftFiles() {
            let text = file.lines.joined(separator: "\n")
            var from = text.startIndex
            while let call = text.range(of: ".search(", range: from..<text.endIndex) {
                callSites.append((file.name, Self.callArguments(text, from: call.upperBound)))
                from = call.upperBound
            }
        }

        #expect(callSites.count == 1, """
            The window has \(callSites.count) search call sites: \
            \(callSites.map(\.file).joined(separator: ", ")). ⌘K and `meetings search` have to be \
            the same question asked twice, which needs there to be one place the window asks it.
            """)
        #expect(callSites.first?.arguments == "query: searchQuery", """
            The palette shapes its own query: `.search(\(callSites.first?.arguments ?? ""))`. \
            Everything but the text in the field — a folder, a limit, a state, a trimmed or \
            decorated string — is something `meetings search` is never handed, so the window and \
            the CLI stop being able to give the same answer about the same store.
            """)

        // The other way to diverge is to stop calling it at all. `MeetingStore.search` owns the
        // tokenising, the FTS5 escaping (`or`, `NEAR`, a stray quote or colon) and the title scan;
        // a second implementation in the window would have to get all of it right twice.
        for file in try Self.swiftFiles() {
            for (offset, line) in file.lines.enumerated() {
                for own in ["meetings_fts", "MATCH ?", "instr(lower(", "bm25(", "ftsQuery(", "Match.score("] {
                    #expect(!line.contains(own), """
                        \(file.name):\(offset + 1) searches on its own terms (\(own)). Search is \
                        `MeetingStore.search`, the one the CLI calls; anything else is a second \
                        set of semantics for the same box.
                        """)
                }
            }
        }
    }

    /// The palette's read runs *after* the keystroke, not inside it.
    ///
    /// `searchQuery`'s `didSet` is the setter SwiftUI's `TextField` writes through, so calling
    /// `runSearch()` from it put an FTS read, a `snippet()` per hit and a re-render of the list
    /// inside AppKit's text-input event with the field mid-edit — and the field was re-set from the
    /// binding between two characters. Typing `or` searched `ro`, which in a store holding "Testing
    /// Meetings app with Or" and "Problem Solving (Intern/Graduate) interview with Revolut" returns
    /// the interview and not the meeting whose name you typed. The store was answering correctly
    /// the whole time; it was being asked a query nobody typed.
    ///
    /// There is no test target for `MeetingsApp` and no way to press a key at one, so what is
    /// checked is the shape: the setter schedules, and `runSearch` reads the field when it runs.
    @Test func theSearchRunsAfterTheKeystrokeRatherThanInsideIt() throws {
        let model = try Self.source("AppModel.swift")
        let didSet = try #require(model.range(of: "var searchQuery = \"\" {"))
        // The property's own body: everything up to the blank line that ends it.
        let end = model.range(of: "\n\n", range: didSet.upperBound..<model.endIndex)?.lowerBound
        let body = String(model[didSet.upperBound..<(end ?? model.endIndex)])
        #expect(body.contains("scheduleSearch()") && !body.contains("runSearch()"), """
            The palette searches from inside the text field's own setter. The read, the snippet and \
            the re-render then all land in the middle of AppKit's text input, and the query the \
            store is handed stops being the text the user typed.
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

    /// **One editor, no toggle**, and both fields with two writers mount the same one.
    ///
    /// There was a seam here — `MEETINGS_EDITOR=engine|native` — while the library and the
    /// hand-built editor were being photographed side by side. Keeping it past that decision would
    /// mean two editors to fix every bug in, and a variable that silently changes which one shipped.
    /// The mount stays inside `SharedFieldEditor` for the reason it always did: the summary and the
    /// pre-notes are one field with two writers, and an editor chosen per call site is two answers
    /// that drift.
    @Test func thereIsOneEditorAndItIsMountedOnce() throws {
        let app = try Self.source("MeetingsApp.swift")
        #expect(!app.contains("MEETINGS_EDITOR"), """
            The editor switch is back. There is one editor; a variable that picks between two is a \
            second code path nobody photographs before shipping.
            """)

        let editor = try Self.source("PreNotesEditor.swift")
        let mount = try #require(editor.range(of: "private var editor: some View"),
                                 "the one mount has to stay inside the one shared editor")
        let body = String(editor[mount.upperBound...].prefix(120))
        #expect(body.contains("LiveMarkdownEditor(text: $text, documentId: identity)"),
                "and it is the engine-backed editor, handed the field's identity as its document")
        #expect(!editor.contains("editorEngine"), "with nothing branching on which editor to use")
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
        let editor = try Self.source("MarkdownEditor.swift")
        #expect(editor.contains("heightBehavior: .fitsContent"), """
            `.scrolls` is the library's default. Taking it puts an NSScrollView inside the page's \
            own ScrollView, which is two surfaces and one ambiguous trackpad drag.
            """)
        #expect(editor.contains("scrollers: .hidden"),
                "and a scroller on a view that does not scroll is a control that does nothing")
        #expect(editor.contains("readingWidth: nil") || !editor.contains("readingWidth:"), """
            The measure is SharedFieldEditor.column, applied by the frame outside the editor. A \
            reading column inside that frame is two answers to one question.
            """)

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

        // The checkbox itself belongs to the engine now, and that is the whole point: it draws the
        // box inside the NSTextLayoutFragment, with the draw site and the hit-test site calling one
        // shared TaskCheckboxGeometry. The last bug this app shipped was the other arrangement — an
        // overlay view computing its own positions, which drifted four hundred points down the
        // page. Nothing in this app may start drawing one again.
        for file in try Self.swiftFiles() {
            let text = file.lines.joined(separator: "\n")
            #expect(!text.contains("NSButton.checkboxSquare") && !text.contains("checkboxRect"), """
                \(file.name) is computing checkbox geometry. The engine draws the box inside its \
                own layout fragment; a second set of coordinates is the bug that put the glyphs \
                four hundred points below their text.
                """)
        }

        // And the one command the engine's bus has no verb for still reaches the document, because
        // an action item is the construct `meetings actions list` reads back out of the write-up.
        let editor = try Self.source("MarkdownEditor.swift")
        #expect(editor.contains("case .taskList:") && editor.contains(#"replaceCharacters(in: caret, with: "[ ] ")"#), """
            /todo has no verb on the MarkdownEditorBus. It asks for a bullet and types the box into \
            the line the engine just made — through shouldChangeText/didChangeText, so it is \
            undoable and it autosaves.
            """)
    }

    /// The write-up renders its markdown as it is typed, and the value of record stays a `String`.
    ///
    /// This used to pin the hand-built `MarkdownTextView` by name, then its TextKit-2 internals.
    /// Both are gone: `swift-markdown-engine` owns the text view, the styling, the typing rules and
    /// the checkbox. What must not change is the seam — the store holds the plain `String` the CLI
    /// writes, and the editor is a lens over it. Everything above the editor (autosave, the
    /// two-writer banner, the oversize guard, `meetings summary get`, the exporter) is built on that
    /// and an editor that started holding the truth in an attributed form would take all of it.
    @Test func theEditorRendersMarkdownWithoutASecondTextModel() throws {
        let editor = try Self.source("MarkdownEditor.swift")
        #expect(editor.contains("@Binding var text: String"),
                "the store still holds the string the CLI writes, not an attributed one")
        #expect(editor.contains("NativeTextViewWrapper("),
                "and the engine is the library's, not a second text stack of our own")

        let pane = try Self.source("PreNotesEditor.swift")
        #expect(pane.contains("SharedFieldEdit.receive("),
                "the conflict decision belongs to MeetingsCore, where it is tested")
        #expect(pane.contains("static let editLimit = 200_000"),
                "and the oversize guard still keeps a ten-megabyte file out of a text view")
    }

    /// The editor's rules live in the engine, and this app keeps **no second copy of them**.
    ///
    /// Two implementations of "what does Return at the end of a bullet do" is one more than can be
    /// reasoned about, and the loser is whichever one the document is not actually going through.
    /// So the transforms were deleted rather than left beside the library: `MarkdownEditing` is a
    /// catalogue and a placement rule now, and every edit is a verb posted on the engine's own bus.
    @Test func theTypingRulesAreTheEnginesAndThereIsNoSecondCopy() throws {
        let editing = try Self.source("MarkdownEditing.swift", in: "Sources/MeetingsCore")
        for gone in ["func followUp(", "func toggleTask(", "func applyBlock(", "func toggle(",
                     "func isActive(", "struct Edit"] {
            #expect(!editing.contains(gone), """
                \(gone) is back in MeetingsCore. The engine holds the document and applies these \
                itself; a second implementation here is a rule that disagrees with the one running.
                """)
        }
        #expect(editing.contains("public static func floating("),
                "what survives is the placement the engine ships nothing for")
        #expect(editing.contains("public static let slashCommands"),
                "and the slash catalogue, which the engine also ships nothing for")

        // Every command reaches the engine through the bus, and nothing in the app splices markdown
        // characters into the document behind it.
        let editor = try Self.source("MarkdownEditor.swift")
        #expect(editor.contains("MarkdownEditorBus("),
                "the menu and the toolbar drive the engine through its own bus")
        for hardcoded in ["\"## \"", "\"# \"", "\"> \"", "\"- \""] {
            #expect(!editor.contains(hardcoded), """
                \(hardcoded) is being spliced in by the app. What a heading or a list does to a \
                line is the engine's answer, asked for by name on the bus.
                """)
        }
    }

    /// Nothing in this app may hold a second opinion about where the text is drawn.
    ///
    /// The engine's markers, gutter, reveal and checkbox are all inside its own layout fragment.
    /// A styling pass of ours over the same storage is the arrangement that shipped markers and
    /// text in different places, so the types that made it possible are gone and stay gone.
    @Test func theAppDrawsNoneOfTheDocumentItself() throws {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Self.appSources.path)
            .filter { $0.hasSuffix(".swift") }
        for gone in ["MarkdownTextView.swift", "MarkdownCheckboxOverlay.swift"] {
            #expect(!names.contains(gone), """
                \(gone) is back. One editor: the engine draws the document, and a second view over \
                the same storage is how a checkbox came to sit four hundred points below its text.
                """)
        }
        for file in try Self.swiftFiles() {
            let text = file.lines.joined(separator: "\n")
            #expect(!text.contains(": NSTextView {"), """
                \(file.name) subclasses NSTextView. The engine's own NativeTextView is the text \
                view; a second one is a second set of layout answers.
                """)
        }
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
        // `bodyEdge` is gone with the gutter it measured: the engine draws no marker column, so
        // prose starts at the column's own edge and nothing has an indent to line up with.
        #expect(!pane.contains("bodyEdge"),
                "a gutter measurement over an editor that has no gutter is a number about nothing")

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

    /// Both floating surfaces hang off a rect **measured against the layout that is on screen**,
    /// and land inside the part of the editor that is on screen.
    ///
    /// A menu that opens at the top-left while you are typing on line forty is a menu about
    /// somewhere else — and this app has now been there twice. First through a lazy layout
    /// estimate, which answers before the text has been laid out and never revises itself. Then
    /// through a placement clamped to the editor's *frame*: the editor is as tall as its document
    /// inside a page that scrolls, so "is there room above the caret" was always yes and the 299 pt
    /// slash menu was drawn 305 pt up — off the top of the viewport entirely.
    @Test func theMenuAndTheToolbarAnchorToWhereTheTextActuallyIs() throws {
        let editor = try Self.source("MarkdownEditor.swift")
        #expect(editor.contains("layout.enumerateTextSegments(in: span, type: .standard"), """
            The anchor has to come from the engine's own layout manager — the layout that is \
            drawn, rather than a re-derivation of it.
            """)
        #expect(editor.contains("probe.convert(measured, from: tv)"), """
            Text-view coordinates in, probe coordinates out, through the real view tree — so the \
            engine's reading-column centring, its header band and any scroll offset are AppKit's \
            arithmetic and not a second copy of it here. And no window in the chain: the floating \
            notes panel is a second editor in a second window, and the mount test has none at all.
            """)
        #expect(!editor.contains("convertFromScreen"), """
            Going out to the screen and back needs a window, which made this untestable and made \
            the panel's second window a coordinate space nobody could check.
            """)
        // **No anchor, no surface.** Falling back to the origin is worse than not opening: a menu
        // 1000 pt from the caret reads as a placement bug and costs a day, where a menu that does
        // not open is found in a minute. The gate is one function in MeetingsCore now, so both
        // surfaces are governed by it and it can be tested.
        let editing = try Self.source("MarkdownEditing.swift", in: "Sources/MeetingsCore")
        #expect(editing.contains("guard focused, let anchor,"),
                "no anchor, no focus, no surface — and never a fallback position")
        #expect(editor.contains("MarkdownEditing.surface("),
                "and the app asks that one question rather than writing two `if`s in two views")

        // **Where** it lands is a decision with tests behind it, not arithmetic buried in an
        // `alignmentGuide` closure nothing could reach. It was the latter, and it was unbounded:
        // a 280 pt toolbar centred on a selection at the left edge of the text computed a negative
        // origin, which is outside the document column and past the left edge of the split view's
        // detail pane — and an NSSplitView pane clips.
        let panel = try Self.source("EditorSurfacePanel.swift")
        #expect(panel.contains("MarkdownEditing.floating("), """
            Both surfaces go through the one placement — MeetingsCore's, where the clamp and the \
            flip are tested — so they cannot disagree about what "over the text" means.
            """)
        #expect(editing.contains("case .menu: .below") && editing.contains("case .toolbar: .above"), """
            …and which side each prefers is part of that one decision: a menu belongs under the \
            caret, a toolbar over the selection.
            """)

        // And it is applied to a **window**, not to an overlay. The placement was measured correct
        // in the running app — 1854 pt down a 2230 pt editor, caret at 2159 — and the menu still
        // drew inline with the first heading, because a SwiftUI overlay inside scrolling content
        // does not draw where it is told. Seven fixes to the guides said the same thing.
        for gone in [".overlay(alignment: .topLeading)", "alignmentGuide("] {
            #expect(!editor.contains(gone), """
                \(gone) is back. The surfaces are a child window positioned in screen coordinates; \
                an overlay inside the page's scroll view is the arrangement that could not be made \
                to land, however right the numbers going into it were.
                """)
        }
        #expect(panel.contains("window.addChildWindow(panel, ordered: .above)"), """
            A child window travels with the editor's window and closes with it — including when \
            that window is the floating notes panel.
            """)
        #expect(panel.contains("override var canBecomeKey: Bool { false }"), """
            The surface must never take key focus: typing has to keep going into the text view \
            while the menu filters, and the selection must survive the toolbar appearing.
            """)
        #expect(panel.contains(".nonactivatingPanel"),
                "and a click on it must not deactivate the app behind it")
        #expect(panel.contains("panel.sharingType = window.sharingType"), """
            The notes panel is hidden from screen sharing, which is a privacy feature. A menu \
            opened inside it that a Zoom share could see would be a hole in it.
            """)
        #expect(panel.contains("window.convertToScreen(probe.convert(probe.bounds, to: nil))"), """
            The conversion chain in full: the anchor is in probe coordinates, the probe converts to \
            window coordinates, and the window converts to the screen the panel is framed in.
            """)

        // Which side of the caret a surface goes on is answered against the editor's **visible
        // slice**, and that slice is the window's content area converted into the probe's space.
        // Three derivations from SwiftUI's scroll view were tried and all three lied: with the page
        // scrolled 1661 pt, `HostingScrollView` reported an offset of −53.
        #expect(editor.contains("probe.window.map { probe.convert($0.contentLayoutRect, from: nil) }"), """
            The viewport has to be the window's own content area. Everything derived from \
            SwiftUI's scroll view described a page that was not on screen.
            """)
        #expect(editor.contains("?? probe.visibleRect"), """
            …with `visibleRect` still behind it for an editor with no window at all — the mount \
            tests have none, and a nil viewport would place nothing.
            """)
        #expect(editor.contains("NSView.boundsDidChangeNotification"), """
            And it has to follow the scroll. A viewport read once and kept is a viewport that \
            disagrees with the screen the moment the page moves under an open menu.
            """)
        for moved in ["NSWindow.didMoveNotification", "NSWindow.didResizeNotification",
                      "NSWindow.didResignKeyNotification"] {
            #expect(editor.contains(moved), """
                A surface positioned in screen coordinates has to follow \(moved) as well — it is \
                not inside the window any more, so nothing moves it but this.
                """)
        }

        // An anchor is only as good as its freshness: published from the selection alone it goes
        // stale on any layout change — a resized pane, a rewrapped document, or a selection made
        // before the text was laid out at all, which leaves it nil forever.
        for trigger in ["NSTextView.didChangeSelectionNotification", "NSText.didChangeNotification",
                        "NSView.frameDidChangeNotification"] {
            #expect(editor.contains(trigger), """
                The anchor has to be recomputed on \(trigger) as well, or the toolbar hangs off \
                where the text used to be — or off nothing.
                """)
        }
    }

    /// The menu's keys are taken **before** the text view sees them.
    ///
    /// A build before this one used SwiftUI's `onKeyPress` and hoped it would win the race against a
    /// focused `NSTextView` for Return and the arrows. It does not. The engine's own `doCommandBy`
    /// interception is gated on its wiki-link preview and is not open to an embedder, so a local
    /// event monitor — which runs ahead of the responder chain — is the interception point left.
    @Test func theSlashMenuTakesItsKeysAheadOfTheTextView() throws {
        let editor = try Self.source("MarkdownEditor.swift")
        #expect(editor.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"),
                "the menu's keys have to be taken somewhere that outranks a focused NSTextView")
        #expect(editor.contains("tv.window?.firstResponder === tv"),
                "and the monitor has to be inert unless this editor is the one being typed into")
        #expect(editor.contains("let open = openQuery else"),
                "and inert unless its menu is open, or it eats Return for the whole app")
        #expect(!editor.contains(".onKeyPress("),
                "onKeyPress on a focused text view is a race, not a binding")
    }

    /// One catalogue behind every surface that turns a line into a heading or a list, and one route
    /// from a chosen row to the document.
    ///
    /// A menu that builds its own `"## "` and a toolbar that builds another is two definitions of
    /// Heading 2 that will disagree the first time either grows a rule. Both now name a
    /// ``MarkdownEditing/Action`` and post it on the engine's bus, which is the only thing holding
    /// the document.
    @Test func everyBlockTransformGoesThroughTheOneImplementation() throws {
        let chrome = try Self.source("MarkdownEditorChrome.swift")
        #expect(chrome.contains("MarkdownEditing.SlashCommand"),
                "the menu draws the commands MeetingsCore defines, it does not list its own")
        for hardcoded in ["\"## \"", "\"- [ ] \"", "\"# \""] {
            #expect(!chrome.contains(hardcoded),
                    "\(hardcoded) is built in the view instead of asked for on the bus")
        }
        #expect(chrome.contains("MarkdownEditing.blockCommands"),
                "the turn-into buttons are the commands MeetingsCore defines")

        // The toolbar's pressed state is the engine's own answer, posted after every selection
        // change — the same answer ⌘B uses to decide which way it is going, so a button cannot say
        // "on" while the shortcut turns it on again.
        let editor = try Self.source("MarkdownEditor.swift")
        #expect(editor.contains("selectionBoldDidChange: name(\"isBold\")")
                && editor.contains("selectionItalicDidChange: name(\"isItalic\")"), """
            The pressed state has to come off the engine's bus. Re-deriving it here is a second \
            markdown parser disagreeing with the one holding the document.
            """)

        // And each editor owns its own notification names, because the engine subscribes with
        // `object: nil`: one shared name means ⌘B in the floating notes panel also emboldens the
        // write-up behind it.
        #expect(editor.contains(#"Notification.Name("meetings.editor.\(id).\(verb)")"#), """
            The bus names have to be unique per mounted editor. The engine observes them with \
            object: nil, so a shared name is a format request delivered to every editor on screen.
            """)

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


    // MARK: - The transcription engine choice

    /// The API key must never reach the settings table, in either surface that collects one.
    ///
    /// This is a shape check because the failure is a shape: `setSetting(.transcribeRemoteKeyRef,
    /// key)` compiles perfectly and writes a secret into a plain SQLite row that `meetings config
    /// get` will then print. The key may be handed to exactly one function.
    @Test func theRemoteAPIKeyOnlyEverGoesToTheKeychain() throws {
        let fields = try Self.source("RemoteTranscriptionFields.swift")
        #expect(fields.contains("MeetingsKeychain.setSecret(key, account: keyRef)"))
        // `key` is the secret and `keyRef` is the account name. The secret must not be written to
        // any settings row, under any key.
        for line in fields.components(separatedBy: "\n") where line.contains("setSetting(") {
            #expect(!line.contains(", key)"),
                    "the API key was written into the settings table: \(line.trimmingCharacters(in: .whitespaces))")
        }
        #expect(fields.contains("SecureField(\"API key\""), "the key field has to stay obscured")
    }

    /// Verification is offered, is the default, and is a real request rather than a shape check.
    @Test func theRemoteEndpointIsVerifiedBeforeTheWizardWillMoveOn() throws {
        let fields = try Self.source("RemoteTranscriptionFields.swift")
        #expect(fields.contains("TranscriptionVerify.remote(store: store)"),
                "the button has to run the real check, not a local validation")
        // Verifying has to happen before the key can be judged: a key typed and not submitted is not
        // in the Keychain, and the check would report it missing while it sits on screen.
        #expect(fields.contains("saveKey()"))
        #expect(fields.contains("uploaded"),
                "the pane has to say plainly that audio leaves the machine")

        let wizard = try Self.source("OnboardingView.swift")
        #expect(wizard.contains("remoteUnverified"), "the wizard has to know when nothing is proven")
        #expect(wizard.contains("Verify and continue"), "Continue has to become the verify action")
        #expect(wizard.contains("Continue without verifying"),
                "an unreachable endpoint still needs a way past, or the wizard is a trap")
    }

    /// Every gate that used to assume models on disk. Each of these would, left alone, tell a
    /// correctly configured cloud user that recording was broken.
    @Test func everyModelPresenceGateIsEngineAware() throws {
        let prerequisites = try Self.source("Prerequisites.swift")
        #expect(prerequisites.contains("store.transcriptionEngine()"),
                "the recording blocker has to ask which engine before demanding a download")
        #expect(prerequisites.contains("openTranscriptionSettings"),
                "a misconfigured endpoint needs its own fix, not a Download button")

        // The wizard and Settings both drive the download through the service, which is where the
        // engine-awareness lives. A view calling the model statics directly would bypass it.
        for name in ["OnboardingView.swift", "SettingsView.swift"] {
            let source = try Self.source(name)
            #expect(!source.contains("FluidAudioStreamingTranscriber.prepareModels"),
                    "\(name) must download through TranscriptionService, which knows about the engine")
        }
    }

    /// Switching engine has to drop the engine the service cached, or the change takes effect next
    /// launch and not before — which reads exactly like the setting having been ignored.
    @Test func changingTheEngineInvalidatesTheCachedOne() throws {
        for name in ["OnboardingView.swift", "SettingsView.swift"] {
            let source = try Self.source(name)
            #expect(source.contains("forgetResolvedEngine()"),
                    "\(name) changes the engine setting without dropping the resolved engine")
        }
    }

    /// The picker is data, not branches. A new tier is an element of
    /// `LocalTranscriptionOption.all`; if a view names an option by id, adding one means editing
    /// the view, which is the thing this design exists to avoid.
    @Test func theModelPickerIsDrivenByTheCatalogueAndNotByIdentity() throws {
        for name in ["OnboardingView.swift", "SettingsView.swift"] {
            let source = try Self.source(name)
            #expect(source.contains("LocalTranscriptionOption.all"),
                    "\(name) has to render the catalogue")
            for id in LocalTranscriptionOption.all.map(\.id) {
                #expect(!source.contains("\"\(id)\""),
                        "\(name) hardcodes the option id \(id); the list has to stay data-driven")
            }
        }
    }
}
