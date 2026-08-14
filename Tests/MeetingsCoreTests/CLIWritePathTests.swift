import Foundation
import Testing

@testable import MeetingsCore

/// The write path, driven as an agent drives it: the real binary, a real argv, a throwaway store.
///
/// These exist because of one shipped bug. `meetings prenotes add <ref> "- push back on the March
/// timeline"` printed **help** and exited **0**, having written nothing. ArgumentParser reads any
/// token starting with `-` as a cluster of short options, and that bullet contains an `h`, so it
/// became a request for help — and help is a success. A markdown bullet is the single most likely
/// thing anyone appends to pre-notes, so the most common write in the product silently lost data
/// and told the caller it had worked.
///
/// Nothing below can be tested in-process: the fault lived in argv splitting, ahead of every line
/// of our own code, and only a real `execve` reproduces it.
@Suite final class CLIWritePathTests {
    /// The CLI binary, built into the same directory as this target's resource bundle. `swift test`
    /// builds the whole package, so it is always there.
    static let cli: URL = Bundle.module.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("meetings")

    struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    let directory: URL
    let store: MeetingStore
    let meeting: Meeting

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
        meeting = try store.createMeeting(TestStore.meeting(title: "Detector housing design review"))
        try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 9_000,
                              text: "Right, the flange tolerance.", pass: .final),
            TestStore.segment(meetingID: meeting.id, channel: .system, from: 600_000, to: 609_000,
                              text: "Two millimetres out on the last three housings.", pass: .final),
        ])
    }

    deinit { TestStore.remove(directory) }

    @discardableResult
    func run(_ arguments: String...) throws -> Run {
        try run(arguments)
    }

    @discardableResult
    func run(_ arguments: [String], environment extra: [String: String] = [:]) throws -> Run {
        try #require(FileManager.default.fileExists(atPath: Self.cli.path),
                     "the meetings CLI is not built at \(Self.cli.path)")
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = Self.cli
        process.arguments = arguments
        // No calendar fixture and no real calendar unless a case asks for one, and then only the
        // JSON fixture: a test must never be able to read the operator's calendar.
        process.environment = ["MEETINGS_HOME": directory.path, "PATH": "/usr/bin:/bin"]
            .merging(extra) { _, override in override }
        process.standardOutput = out
        process.standardError = err
        // Nothing may block on a terminal: a write command that fell through to reading stdin would
        // otherwise hang the suite, and a hang is the one failure an exit code cannot describe.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    func reread() throws -> Meeting {
        try #require(try store.meeting(id: meeting.id))
    }

    // MARK: - A leading dash is text, on every command that takes text

    @Test func preNotesAddWritesAMarkdownBullet() throws {
        let bullet = "- push back on the March timeline"
        let result = try run("prenotes", "add", meeting.id, bullet)
        #expect(result.status == 0)
        #expect(try reread().preNotes == bullet)
    }

    @Test func preNotesSetWritesAMarkdownBullet() throws {
        let bullet = "- rewrite: who owns the migration"
        let result = try run("prenotes", "set", meeting.id, bullet)
        #expect(result.status == 0)
        #expect(try reread().preNotes == bullet)
    }

    @Test func summarySetWritesAMarkdownBullet() throws {
        let bullet = "- decided: shim for the demo, re-cut for production"
        let result = try run("summary", "set", meeting.id, bullet)
        #expect(result.status == 0)
        #expect(try reread().summary == bullet)
    }

    @Test func noteAddWritesAMarkdownBullet() throws {
        let bullet = "- the housing drawing is the blocker here"
        let result = try run("note", "add", meeting.id, bullet, "--at", "0:03")
        #expect(result.status == 0)
        #expect(try store.notes(meetingID: meeting.id).map(\.text) == [bullet])
    }

    @Test func folderCreateAcceptsALeadingDashName() throws {
        let result = try run("folder", "create", "-hardware-batch-3")
        #expect(result.status == 0)
        #expect(try store.folder(named: "-hardware-batch-3") != nil)
    }

    @Test func vocabAddAcceptsALeadingDashTerm() throws {
        let result = try run("vocab", "add", "-hplc-trace")
        #expect(result.status == 0)
        #expect(try store.vocabularyTerms(term: "-hplc-trace").count == 1)
    }

    @Test func configSetAcceptsALeadingDashValue() throws {
        let result = try run("config", "set", "ai.cloud.model", "-haiku-preview")
        #expect(result.status == 0)
        #expect(try store.setting(.aiCloudModel) == "-haiku-preview")
    }

    /// `--folder -x` is the other half of the same fault: a dash-led value behind an option that
    /// takes one. It has to reach the option, not become a stray positional.
    @Test func moveAcceptsALeadingDashFolderName() throws {
        _ = try store.createFolder(Folder(name: "-hardware"))
        let result = try run("move", meeting.id, "--folder", "-hardware")
        #expect(result.status == 0)
        #expect(try reread().folderID == store.folder(named: "-hardware")?.id)
    }

    /// Same shape, on a read: `--range -10:00` is the form the bundled skill documents, and it used
    /// to come back as "Missing value for '--range'".
    @Test func transcriptRangeAcceptsALeadingDashWindow() throws {
        let result = try run("transcript", meeting.id, "--range", "-5:00")
        #expect(result.status == 0)
        #expect(result.stdout.contains("flange tolerance"))
        #expect(!result.stdout.contains("Two millimetres"), "5:00 onwards is outside the window")
    }

    // MARK: - Nothing exits 0 having written nothing

    /// The general rule, checked across the whole write surface. Every case below is a command line
    /// whose text cannot be used. Each one must fail loudly; none may report success, and none may
    /// answer with help, because help is exit 0 and exit 0 means the write happened.
    @Test(arguments: [
        ["prenotes", "add"],
        ["prenotes", "set"],
        ["summary", "set"],
        ["note", "add"],
        ["actions", "set"],
    ])
    func aWriteWithNoTextIsAUsageErrorAndNotHelp(_ command: [String]) throws {
        let before = try reread()
        let spelled = command.joined(separator: " ")
        let result = try run(command + [meeting.id])
        #expect(result.status == 64, "\(spelled) exited \(result.status)")
        #expect(!result.stdout.contains("OVERVIEW:"), "help on stdout reads as the answer")
        #expect(result.stderr.contains("--file") || result.stderr.contains("stdin"),
                "\(spelled) has to say which forms are accepted")
        let after = try reread()
        #expect(after.preNotes == before.preNotes)
        #expect(after.summary == before.summary)
        #expect((after.actions ?? []).count == (before.actions ?? []).count)
    }

    /// `actions set` takes JSON, so a markdown bullet is genuinely unusable there — but it must be
    /// rejected as bad JSON, not accepted as help.
    @Test func actionsSetRejectsTextThatIsNotJSONInsteadOfPrintingHelp() throws {
        let result = try run("actions", "set", meeting.id, "- ship the housing")
        #expect(result.status == 64)
        #expect(!result.stdout.contains("OVERVIEW:"))
        #expect(try (reread().actions ?? []).isEmpty)
    }

    /// The rule in one place: a command line the CLI cannot carry out must not exit 0, and must not
    /// answer with help — help goes to stdout and exits 0, which is indistinguishable from the work
    /// having been done. Each probe below is unusable for a different reason.
    @Test(arguments: [
        ["prenotes", "add", "--file"],
        ["prenotes", "add", "--nosuchoption", "text"],
        ["summary", "set"],
        ["note", "add", "--at", "0:03"],
        ["list", "--state", "banana"],
        ["config", "set", "no.such.key", "1"],
    ])
    func anUnusableCommandLineNeverSucceedsAndNeverAnswersWithHelp(_ command: [String]) throws {
        let result = try run(command)
        #expect(result.status != 0, "\(command.joined(separator: " ")) exited 0")
        #expect(!result.stdout.contains("OVERVIEW:"), "help on stdout reads as the answer")
    }

    /// And with `--json`, because that is the mode agents branch on: the envelope has to carry a
    /// failing code, never `"code": 0` with a help string in the message.
    @Test func anUnusableCommandLineReportsAFailingCodeInJSON() throws {
        let result = try run("prenotes", "add", "--file", "--json")
        #expect(result.status != 0)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: Any])
        #expect((error["code"] as? Int) != 0)
    }

    /// Help asked for is still help: exit 0, on stdout, unchanged.
    @Test func askingForHelpStillSucceeds() throws {
        let result = try run("prenotes", "add", "--help")
        #expect(result.status == 0)
        #expect(result.stdout.contains("OVERVIEW:"))
    }

    // MARK: - A positional whose text is exactly `-h`

    /// The hole the general rule above still had. `askedForHelp` scanned the whole command line for
    /// `-h`, so text that *is* `-h` read as a request for help: usage on stdout, exit 0, nothing
    /// written — the exact failure the rule exists to make impossible, one command line further in.
    ///
    /// Position decides it now: `-h` means help only immediately after the command name, which is
    /// the one place a help request can sit.
    @Test func aPositionalThatIsExactlyDashHIsTextAndIsWritten() throws {
        let result = try run("prenotes", "add", meeting.id, "-h")
        #expect(result.status == 0)
        #expect(!result.stdout.contains("OVERVIEW:"), "help on stdout reads as the answer")
        #expect(try reread().preNotes == "-h")
    }

    /// Same shape on every other command that takes text, because the fix is one rule and not a
    /// case for `prenotes`.
    @Test func everyTextWriteTakesDashHAsText() throws {
        #expect(try run("prenotes", "set", meeting.id, "-h").status == 0)
        #expect(try reread().preNotes == "-h")
        #expect(try run("summary", "set", meeting.id, "-h").status == 0)
        #expect(try reread().summary == "-h")
        #expect(try run("note", "add", meeting.id, "-h", "--at", "0:03").status == 0)
        #expect(try store.notes(meetingID: meeting.id).map(\.text) == ["-h"])
        #expect(try run("config", "set", "ai.cloud.model", "-h").status == 0)
        #expect(try store.setting(.aiCloudModel) == "-h")
    }

    /// And `help` spelled as a word, which is a subcommand of the root and ordinary text anywhere
    /// else.
    @Test func aPositionalThatIsTheWordHelpIsText() throws {
        #expect(try run("prenotes", "add", meeting.id, "help").status == 0)
        #expect(try reread().preNotes == "help")
    }

    /// The other half of the same rule: `-h` where help can go is still help, at every depth of the
    /// command tree. Losing this would be trading one broken command line for another.
    @Test(arguments: [["-h"], ["show", "-h"], ["prenotes", "-h"], ["prenotes", "add", "-h"],
                      ["transcript", "-h"], ["config", "set", "-h"]])
    func dashHRightAfterTheCommandNameIsStillHelp(_ command: [String]) throws {
        let result = try run(command)
        #expect(result.status == 0, "\(command.joined(separator: " ")) exited \(result.status)")
        #expect(result.stdout.contains("OVERVIEW:"))
    }

    // MARK: - A command group named without a subcommand

    /// `meetings summary` used to answer "Text beginning with a dash has to come after --", which is
    /// about a problem that is not there: nothing on the line is malformed, it stops one word short.
    @Test(arguments: [("summary", "set"), ("skill", "install")])
    func aMissingSubcommandSaysSoAndNamesTheSubcommands(_ group: String, _ subcommand: String) throws {
        let result = try run([group])
        #expect(result.status == 64)
        #expect(result.stderr.contains("\(group) needs a subcommand"))
        #expect(result.stderr.contains("meetings \(group) \(subcommand)"))
        #expect(!result.stderr.contains("beginning with a dash"), "that was never the problem")
    }

    /// In `--json` too, because that is the mode an agent branches on — and in that mode the same
    /// command line used to come back as "Unknown option '--json'".
    @Test func aMissingSubcommandSaysSoInJSON() throws {
        let result = try run("summary", "--json")
        #expect(result.status == 64)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(envelope["error"] as? [String: Any])
        #expect((error["code"] as? Int) == 64)
        #expect((error["message"] as? String)?.contains("needs a subcommand") == true)
        #expect((error["message"] as? String)?.contains("dash") != true)
    }

    /// A group that has a default subcommand is a complete command line and must not be caught by
    /// the rule above.
    @Test func aGroupWithADefaultSubcommandStillRunsIt() throws {
        #expect(try run("config").status == 0)
        #expect(try run("folder").status == 0)
    }

    // MARK: - The notes panel's two settings, from the CLI

    /// Their own design note calls each one "a visible, named setting". They were reachable only
    /// from the app's Settings window, so a CLI-driven setup could not turn screen-share hiding off
    /// or on, and `config get` did not even list them.
    @Test(arguments: ["panel.hideFromScreenSharing", "panel.keepAboveOtherApps"])
    func theNotesPanelSettingsAreReadableAndWritableFromTheCLI(_ key: String) throws {
        let listed = try run("config", "get")
        #expect(listed.stdout.contains(key), "config get has to list every known key")

        // Unset reads as the app's own default rather than as nothing: the panel does hide itself.
        let unset = try run("config", "get", key)
        #expect(unset.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true")

        #expect(try run("config", "set", key, "false").status == 0)
        #expect(try store.settingBool(SettingKey(key)) == false, "the app reads this exact key")
        #expect(try run("config", "get", key).stdout.contains("false"))

        // And back to the default, which deletes the row rather than storing "true".
        #expect(try run("config", "set", key).status == 0)
        #expect(try store.storedSettings()[key] == nil)
        #expect(try run("config", "get", key).stdout.contains("true"))
    }

    @Test(arguments: ["panel.hideFromScreenSharing", "panel.keepAboveOtherApps"])
    func aNotesPanelSettingIsABoolean(_ key: String) throws {
        let result = try run("config", "set", key, "sometimes")
        #expect(result.status == 64)
        #expect(result.stderr.contains("true or false"))
        #expect(try store.storedSettings()[key] == nil, "a refused value is not written")
    }

    // MARK: - A half transcript, in the command that reads transcripts

    /// `show` and `list` say when a channel failed. `transcript` did not, in any format — and
    /// `transcript` is the command the bundled skill sends an agent to for anything over forty
    /// minutes, so the long-meeting write-up path read half a conversation with nothing in its
    /// output saying so.
    @Test func transcriptMarkdownSaysAChannelIsMissing() throws {
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .system,
            reason: "unreadable audio system.wav: the file ends mid-frame"))

        let result = try run("transcript", meeting.id)
        #expect(result.status == 0)
        // On stdout, because this output is markdown an agent reads and quotes from, and a warning
        // on stderr does not survive the `>` or the pipe that the skill's own examples use.
        #expect(result.stdout.contains("> The system channel could not be transcribed"))
        #expect(result.stdout.contains("ends mid-frame"))
        #expect(result.stdout.contains("flange tolerance"), "the transcript itself still comes out")
    }

    /// Chunked is the long-meeting form, which is the one that matters most here.
    @Test func transcriptChunksSayItToo() throws {
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .system, reason: "unreadable audio system.wav"))
        let result = try run("transcript", meeting.id, "--chunks", "5")
        #expect(result.stdout.contains("could not be transcribed"))
        #expect(result.stdout.contains("## chunk 1 of"))
    }

    @Test func transcriptJSONCarriesTheSameKeyShowAndListCarry() throws {
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .system, reason: "unreadable audio system.wav"))

        let result = try run("transcript", meeting.id, "--json")
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let issues = try #require(payload["transcriptIssues"] as? [[String: Any]])
        #expect(issues.count == 1)
        #expect(issues[0]["channel"] as? String == "system")
        #expect((issues[0]["reason"] as? String)?.contains("system.wav") == true)
    }

    /// `kind` was dropped from the CLI's JSON while the bundle shape carried it, so the one output
    /// that exists precisely so agents do not have to read English prose forced them to read English
    /// prose: a capture failure and a transcription failure differ only in the wording of `reason`
    /// and `sentence`, and they call for opposite advice — one is permanent, the other clears on a
    /// re-run. Every command that emits an issue has to carry it.
    @Test func everyJSONShapeCarriesTheKindOfEachTranscriptIssue() throws {
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .mic, kind: .capture,
            reason: "the microphone delivered digital silence for the whole recording"))
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .system, kind: .transcription,
            reason: "unreadable audio system.wav"))

        for command in [["show", meeting.id, "--json"], ["transcript", meeting.id, "--json"]] {
            let result = try run(command)
            let payload = try #require(
                try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
            // `show` nests the meeting; `transcript` puts the array at the top level.
            let container = (payload["meeting"] as? [String: Any]) ?? payload
            let issues = try #require(container["transcriptIssues"] as? [[String: Any]],
                                      "\(command.joined(separator: " ")) lost the issues")
            #expect(Set(issues.compactMap { $0["kind"] as? String }) == ["capture", "transcription"],
                    "\(command.joined(separator: " ")) did not carry kind")
        }

        let listed = try run("list", "--json")
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(listed.stdout.utf8)) as? [String: Any])
        let meetings = try #require(payload["meetings"] as? [[String: Any]])
        let issues = try #require(meetings.compactMap { $0["transcriptIssues"] as? [[String: Any]] }.first)
        #expect(Set(issues.compactMap { $0["kind"] as? String }) == ["capture", "transcription"])
    }

    /// SubRip holds exactly one kind of record — a numbered cue with a time span — so the only way
    /// to put this on stdout is to forge a cue, which would appear on screen as if somebody had said
    /// it and would renumber every real cue after it. It goes to stderr, and the file stays valid.
    @Test func transcriptSRTPutsTheWarningOffTheSubtitleFile() throws {
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .system, reason: "unreadable audio system.wav"))

        let result = try run("transcript", meeting.id, "--format", "srt")
        #expect(result.stderr.contains("The system channel could not be transcribed"))
        #expect(!result.stdout.contains("could not be transcribed"), "a forged cue would play on screen")
        #expect(result.stdout.hasPrefix("1\n00:00:00,000 --> "), "still a valid .srt")
    }

    /// A whole transcript says nothing at all, in any format: a key or a line that is nearly always
    /// there is one nobody reads.
    @Test func awholeTranscriptCarriesNoWarningAnywhere() throws {
        let markdown = try run("transcript", meeting.id)
        #expect(!markdown.stdout.contains("could not be transcribed"))
        #expect(!markdown.stderr.contains("could not be transcribed"))
        let json = try run("transcript", meeting.id, "--json")
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        #expect(payload["transcriptIssues"] == nil)
    }

    /// Both channels gone is the case with no transcript at all to print, and the one where the
    /// reason is the only thing there is to say.
    @Test func aTranscriptThatIsEntirelyMissingStillSaysWhy() throws {
        let empty = try store.createMeeting(TestStore.meeting(title: "Nothing came through"))
        for channel in [Channel.mic, .system] {
            try store.recordTranscriptIssue(TranscriptIssue(
                meetingID: empty.id, channel: channel, reason: "unreadable audio"))
        }
        let result = try run("transcript", empty.id)
        #expect(result.stdout.contains("The mic channel could not be transcribed"))
        #expect(result.stdout.contains("The system channel could not be transcribed"))
    }

    // MARK: - A refused write leaves no row behind

    /// `move` validated its folder before resolving the ref; `note add` and `transcript edit` did
    /// not, so a `cal:` ref materialised a `scheduled` meeting and *then* the command refused —
    /// leaving a meeting in the store, and in `meetings list`, for a write that never happened.
    ///
    /// Neither refusal was ever avoidable: a freshly materialised row is `scheduled`, and neither
    /// command works from `scheduled`.
    @Test(arguments: [
        ["note", "add", "cal:C41D9B02-WEEKLY-1000", "a note with nowhere to anchor"],
        ["transcript", "edit", "cal:C41D9B02-WEEKLY-1000", "--segment", "1", "--text", "corrected"],
    ])
    func aWriteThatCannotSucceedMaterialisesNothing(_ command: [String]) throws {
        let before = try store.allMeetings().count
        let result = try run(command, environment: ["MEETINGS_CALENDAR_FIXTURE": CalFixture.url.path])
        #expect(result.status == 3, "\(command.joined(separator: " ")) exited \(result.status)")
        #expect(result.stderr.contains("Torch0 weekly"), "the refusal names the meeting")
        #expect(try store.allMeetings().count == before, "a refused write left a row behind")
        #expect(try store.meeting(calendarEventID: "C41D9B02-WEEKLY-1000") == nil)
    }

    /// The offset is parsed before anything is resolved, so a misspelt `--at` cannot materialise a
    /// row either.
    @Test func anUnreadableOffsetMaterialisesNothing() throws {
        let before = try store.allMeetings().count
        let result = try run(["note", "add", "cal:C41D9B02-WEEKLY-1000", "x", "--at", "banana"],
                             environment: ["MEETINGS_CALENDAR_FIXTURE": CalFixture.url.path])
        #expect(result.status == 64)
        #expect(try store.allMeetings().count == before)
    }

    /// And the write that *can* succeed still materialises, which is the whole point.
    @Test func aWriteThatCanSucceedStillMaterialisesTheRow() throws {
        let result = try run(["note", "add", "cal:C41D9B02-WEEKLY-1000", "anchored", "--at", "0:10"],
                             environment: ["MEETINGS_CALENDAR_FIXTURE": CalFixture.url.path])
        #expect(result.status == 0)
        let created = try #require(try store.meeting(calendarEventID: "C41D9B02-WEEKLY-1000"))
        #expect(try store.notes(meetingID: created.id).map(\.text) == ["anchored"])
    }

    // MARK: - The look-ahead window is a setting, and --days overrides it for one run

    /// Both front ends read `calendar.lookAheadDays`, so this is half of "the window is honoured
    /// everywhere" — the other half is ``CalendarSyncTests``, which drives the same
    /// `CalendarSync.lookAheadDays` the window reads.
    ///
    /// The horizons are seven and fourteen days rather than one or two on purpose: the fixture's
    /// events sit at fixed times of day, so a window measured from *now* would include or exclude
    /// tomorrow's ten o'clock depending on what time the suite happened to run.
    @Test func theLookAheadSettingDecidesTheCLIsHorizon() throws {
        let environment = ["MEETINGS_CALENDAR_FIXTURE": CalFixture.url.path]
        #expect(try upcomingCount(run(["upcoming", "--json"], environment: environment)) == 3)

        try store.setSetting(.calendarLookAheadDays, "14")
        #expect(try upcomingCount(run(["upcoming", "--json"], environment: environment)) == 5)
    }

    /// The flag is for one invocation, in both directions, and never writes the setting back: an
    /// agent asking "what's on this fortnight" must not quietly change what the window shows.
    @Test func theDaysFlagOverridesTheSettingWithoutChangingIt() throws {
        let environment = ["MEETINGS_CALENDAR_FIXTURE": CalFixture.url.path]
        #expect(try upcomingCount(run(["upcoming", "--json", "--days", "14"], environment: environment)) == 5)

        try store.setSetting(.calendarLookAheadDays, "14")
        #expect(try upcomingCount(run(["upcoming", "--json", "--days", "7"], environment: environment)) == 3)
        #expect(try store.setting(.calendarLookAheadDays) == "14")
    }

    @Test func theLookAheadIsWritableAndRefusesAWindowOfNothing() throws {
        #expect(try run("config", "set", "calendar.lookAheadDays", "0").status == 64)
        #expect(try store.setting(.calendarLookAheadDays) == "7", "the refusal wrote nothing")

        #expect(try run("config", "set", "calendar.lookAheadDays", "21").status == 0)
        #expect(try store.setting(.calendarLookAheadDays) == "21")
    }

    private func upcomingCount(_ result: Run) throws -> Int {
        #expect(result.status == 0, "\(result.stderr)")
        let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        return ((json as? [String: Any])?["upcoming"] as? [Any])?.count ?? -1
    }

    // MARK: - A store nobody can write to

    /// SQLite writes its `-wal` and `-shm` companions on every connection, including one that only
    /// reads, so a read-only store fails `status` and `list` too. It failed in SQLite's own words —
    /// "database is locked", or a `CREATE TABLE grdb_issue_102` nobody wrote — both of which name
    /// something the user did not do and cannot act on.
    @Test(arguments: ["status", "list", "config"])
    func aReadOnlyStoreSaysWhatIsActuallyWrongAndWhere(_ command: String) throws {
        let readOnly = try TestStore.makeDirectory()
        defer {
            chmod(readOnly, 0o755, 0o644)
            TestStore.remove(readOnly)
        }
        // A real store first, then locked down. The shared-memory file matters most: a read-only
        // `-shm` is what turns an ordinary read into "database is locked".
        _ = try TestStore.open(readOnly)
        chmod(readOnly, 0o555, 0o444)

        let result = try run([command], environment: ["MEETINGS_HOME": readOnly.path])
        #expect(result.status != 0)
        #expect(result.stderr.contains(readOnly.path), "the message has to name the path")
        #expect(result.stderr.contains("not writable"))
        #expect(!result.stderr.contains("database is locked"))
        #expect(!result.stderr.contains("grdb_issue_102"))
    }

    /// Everything in the store directory, then the directory itself — the order matters going both
    /// ways, since a read-only directory is one nothing inside it can be chmodded through.
    private func chmod(_ directory: URL, _ directoryMode: Int, _ fileMode: Int) {
        let manager = FileManager.default
        _ = try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            _ = try? manager.setAttributes(
                [.posixPermissions: fileMode],
                ofItemAtPath: directory.appendingPathComponent(name).path
            )
        }
        _ = try? manager.setAttributes([.posixPermissions: directoryMode], ofItemAtPath: directory.path)
    }
}
