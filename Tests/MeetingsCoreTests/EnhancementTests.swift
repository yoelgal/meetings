import Foundation
import GRDB
import Testing

@testable import MeetingsCore

/// Mode B. **Nothing in this file executes a real agent CLI** — that would spend the
/// operator's subscription. The template is pointed at `/bin/echo`, at `/usr/bin/sqlite3`, and at
/// throwaway scripts, which is enough to prove every rule the runner owes: that it stays off unless
/// armed, that substitution and quoting land, that `MEETINGS_DB` reaches the child, and that a write
/// the child makes is visible to the store afterwards.
@Suite(.serialized)
struct EnhancementTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    private func runner() -> EnhancementRunner {
        // A deliberately bare environment: the runner has to add MEETINGS_DB and widen PATH itself.
        EnhancementRunner(store: store, environment: ["HOME": directory.path])
    }

    // MARK: - Tokenising and substitution

    @Test func tokenisesTheShippedDefaultTemplate() {
        let command = EnhancementRunner.command(
            template: SettingKey.aiLocalAgentRunCommand.defaultValue ?? "",
            meetingID: "abc-123"
        )
        #expect(command == ["claude", "-p", "/meetings abc-123"])
    }

    /// The two commands are not interchangeable, and the split is only worth anything if each
    /// default is right for its own job: `argv[0]` here has to be a binary, and the pasted one has
    /// to be the slash command the installed skill actually answers to.
    @Test func theExecutedDefaultIsABinaryAndThePastedDefaultIsASlashCommand() {
        let executed = EnhancementRunner.command(
            template: SettingKey.aiLocalAgentRunCommand.defaultValue ?? "",
            meetingID: "abc-123"
        )
        #expect(executed.first == "claude", "argv[0] has to be something exec can launch")
        #expect(SettingKey.aiManualPasteCommand.defaultValue == "/meetings {meeting_id}")
    }

    /// The store carries a customised Mode B command across the split rather than dropping it —
    /// dropping it would turn Mode B off with nothing on screen to say why.
    @Test func aCustomisedOldTemplateSurvivesTheSplit() throws {
        let directory = try TestStore.makeDirectory()
        let path = directory.appendingPathComponent("legacy.db").path

        // A store as it stood before the split: migrated only as far as v3, with the value under the
        // retired key. Built at v3 on purpose — a store opened normally is already at v4, so it has
        // nothing left to migrate and would pass this test without the migration existing at all.
        try {
            let pool = try DatabasePool(path: path)
            try Schema.migrator.migrate(pool, upTo: "v3")
            try pool.write { db in
                try db.execute(
                    sql: "INSERT INTO settings (key, value) VALUES (?, ?)",
                    arguments: [
                        SettingKey.legacyAICommandTemplate.rawValue,
                        "/usr/local/bin/my-agent {meeting_id}",
                    ]
                )
            }
            try pool.close()
        }()

        let migrated = MeetingStore(dbPool: try MeetingsDatabase.open(at: URL(fileURLWithPath: path)))
        #expect(try migrated.setting(.aiLocalAgentRunCommand) == "/usr/local/bin/my-agent {meeting_id}")
        #expect(try migrated.setting(.legacyAICommandTemplate) == nil)
        #expect(EnhancementRunner.commandTemplate(in: migrated) == "/usr/local/bin/my-agent {meeting_id}")
    }

    /// Substitution happens after the split, so an id can never become a second argument, a
    /// redirect, or a second command however it is quoted.
    @Test func aMeetingIDCannotIntroduceATokenBoundary() {
        let command = EnhancementRunner.command(
            template: "echo {meeting_id}",
            meetingID: "x y; rm -rf /"
        )
        #expect(command == ["echo", "x y; rm -rf /"])
    }

    @Test func tokeniserHandlesQuotesEscapesAndEmptyArguments() {
        #expect(EnhancementRunner.tokenize("  a   b  ") == ["a", "b"])
        #expect(EnhancementRunner.tokenize(#"a "b c" 'd e'"#) == ["a", "b c", "d e"])
        #expect(EnhancementRunner.tokenize(#"a\ b"#) == ["a b"])
        #expect(EnhancementRunner.tokenize(#"say ""#) == ["say", ""])
        #expect(EnhancementRunner.tokenize("") == [])
    }

    // MARK: - The off switch

    @Test func doesNothingInTheDefaultManualMode() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.setSetting(.aiLocalAgentRunCommand, "/bin/echo ran")

        let result = await runner().enhanceOnReady(meetingID: meeting.id)
        guard case .disabled = result else {
            Issue.record("manual mode must not run anything, got \(result)")
            return
        }
    }

    @Test func doesNotRunForAMeetingThatIsNotReady() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try store.setSetting(.aiMode, AIMode.localAgent.rawValue)
        try store.setSetting(.aiLocalAgentRunCommand, "/bin/echo ran")

        #expect(await runner().enhanceOnReady(meetingID: meeting.id) == .notReady)
    }

    // MARK: - Running

    @Test func runsTheTemplateWithTheMeetingIDSubstituted() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.setSetting(.aiMode, AIMode.localAgent.rawValue)
        try store.setSetting(.aiLocalAgentRunCommand, #"/bin/echo "notes for {meeting_id}""#)

        guard case .ran(let run) = await runner().enhanceOnReady(meetingID: meeting.id) else {
            Issue.record("expected the command to run")
            return
        }
        #expect(run.exitCode == 0)
        #expect(run.output == "notes for \(meeting.id)")
        #expect(run.command == ["/bin/echo", "notes for \(meeting.id)"])
    }

    @Test func exportsTheDatabasePathToTheChildProcess() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.setSetting(.aiMode, AIMode.localAgent.rawValue)
        try store.setSetting(.aiLocalAgentRunCommand, "/bin/sh -c 'printf %s \"$MEETINGS_DB\"'")

        guard case .ran(let run) = await runner().enhanceOnReady(meetingID: meeting.id) else {
            Issue.record("expected the command to run")
            return
        }
        #expect(run.output == store.dbPool.path)
    }

    /// The whole point of Mode B: the spawned process writes back and the app sees it. `sqlite3`
    /// stands in for the agent's `meetings summary set` — a second process on the same file, which
    /// is the part that can actually break.
    @Test func aWriteFromTheSpawnedProcessIsVisibleAfterwards() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.setSetting(.aiMode, AIMode.localAgent.rawValue)

        let script = directory.appendingPathComponent("write-summary.sh")
        try """
            #!/bin/sh
            set -e
            /usr/bin/sqlite3 "$MEETINGS_DB" \
              "UPDATE meetings SET summary = 'Written by the agent', state = 'complete' WHERE id = '$1';"
            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try store.setSetting(.aiLocalAgentRunCommand, "\(script.path) {meeting_id}")

        guard case .ran(let run) = await runner().enhanceOnReady(meetingID: meeting.id) else {
            Issue.record("expected the script to run")
            return
        }
        #expect(run.exitCode == 0, "script said: \(run.output)")

        let after = try #require(try store.meeting(id: meeting.id))
        #expect(after.summary == "Written by the agent")
        #expect(after.state == .complete)
    }

    @Test func reportsANonZeroExitWithItsOutputRatherThanSwallowingIt() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.setSetting(.aiMode, AIMode.localAgent.rawValue)
        try store.setSetting(.aiLocalAgentRunCommand, "/bin/sh -c 'echo no model configured >&2; exit 3'")

        guard case .ran(let run) = await runner().enhanceOnReady(meetingID: meeting.id) else {
            Issue.record("expected the command to run")
            return
        }
        #expect(run.exitCode == 3)
        #expect(run.output == "no model configured")
    }

    @Test func aMissingBinaryFailsToLaunchRatherThanHanging() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.setSetting(.aiMode, AIMode.localAgent.rawValue)
        try store.setSetting(.aiLocalAgentRunCommand, "meetings-no-such-agent-binary {meeting_id}")

        // `env` reports the missing binary itself and exits 127 — a run that happened and failed,
        // which is the honest description and is what the UI shows.
        guard case .ran(let run) = await runner().enhanceOnReady(meetingID: meeting.id) else {
            Issue.record("expected env to report the missing binary")
            return
        }
        #expect(run.exitCode == 127)
    }

    @Test func widensPATHSoAnAgentInstalledOutsideTheFinderPATHIsFound() async {
        let environment = await runner().environment(for: "abc")
        let path = environment["PATH"] ?? ""
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("\(directory.path)/.local/bin"))
        #expect(environment["MEETINGS_DB"] == store.dbPool.path)
    }

    // MARK: - Mode C

    /// Mode C is the only place in the product a prompt exists (see `CloudPrompt`),
    /// and the prompt itself carries the rule that the user's own notes steer the write-up.
    @Test func theCloudPromptRefusesToInventWhatTheMeetingDidNotCover() {
        #expect(CloudPrompt.system.contains("Not covered"))
    }

    @Test func cloudPromptCarriesNotesAndTranscriptWithChannelLabels() throws {
        var meeting = TestStore.meeting(state: .ready, preNotes: "Ask about the pilot")
        meeting.attendees = [Attendee(name: "Sofia Nunes", email: "sofia@example.com")]
        let created = try store.createMeeting(meeting)
        try store.insertSegments([
            TestStore.segment(meetingID: created.id, channel: .mic, from: 0, to: 1000, text: "Hello", pass: .final),
            TestStore.segment(meetingID: created.id, channel: .system, from: 1000, to: 2000, text: "Hi there", pass: .final),
        ])
        let note = try store.addNote(meetingID: created.id, tOffsetMs: 1500, text: "pilot not raised")

        let prompt = CloudPrompt.user(
            meeting: created,
            notes: [note],
            segments: try store.segments(meetingID: created.id)
        )
        #expect(prompt.contains("Ask about the pilot"))
        #expect(prompt.contains("Sofia Nunes"))
        #expect(prompt.contains("[00:00] You: Hello"))
        #expect(prompt.contains("[00:01] Others: Hi there"))
        #expect(prompt.contains("[00:01] pilot not raised"))
    }

    /// The whole point of Mode C, and the thing that was wired to nothing: a meeting reaches `ready`
    /// with cloud armed, and the provider's answer lands in `summary` with the state moved on.
    @Test func cloudModeWritesTheSummaryAndMovesTheMeetingOn() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.insertSegments([
            TestStore.segment(
                meetingID: meeting.id, channel: .mic, from: 0, to: 1000,
                text: "We should run the pilot", pass: .final
            ),
        ])
        configureCloud()

        let provider = FakeProvider.returning("We agreed to run the pilot.")
        #expect(await cloudRunner(provider).enhanceOnReady(meetingID: meeting.id) == .wroteSummary)

        let after = try #require(try store.meeting(id: meeting.id))
        #expect(after.summary == "We agreed to run the pilot.")
        #expect(after.state == .complete)

        // Sent to the configured endpoint, carrying the transcript — a write-up assembled from
        // nothing would still have produced a summary-shaped string.
        let request = try #require(await provider.seen.first)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("We should run the pilot"))
    }

    /// The `ready` guard is shared, not repeated per mode, so it has to hold for cloud too: a
    /// meeting still recording must not be sent anywhere.
    @Test func cloudModeDoesNotSendAMeetingThatIsNotReady() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        configureCloud()

        let provider = FakeProvider.returning("Written too early.")
        #expect(await cloudRunner(provider).enhanceOnReady(meetingID: meeting.id) == .notReady)
        #expect(await provider.seen.isEmpty)
    }

    /// "You never finished setting this up" is a different fix from "your provider said no", and
    /// this is the one the user cannot see: nothing was sent, so there is no provider error to read.
    /// The sentence names the missing row, in the verify button's own words.
    @Test func anUnconfiguredCloudModeNamesTheMissingRowAndSendsNothing() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.setSetting(.aiMode, AIMode.cloud.rawValue)
        try store.setSetting(.aiCloudBaseURL, "https://api.example.com/v1")
        try store.setSetting(.aiCloudKeyRef, "cloud")
        // No model row, which is the half-configured state Settings lets you leave behind.

        let refuse: HTTPTransport = { _ in
            Issue.record("a half-configured provider must not be contacted")
            throw URLError(.badURL)
        }
        let runner = EnhancementRunner(
            store: store,
            environment: ["HOME": directory.path],
            transport: refuse,
            keychain: { _ in "sk-live-secret" }
        )

        guard case .failed(let message) = await runner.enhanceOnReady(meetingID: meeting.id) else {
            Issue.record("an unconfigured cloud mode has to say so")
            return
        }
        #expect(message == "Cloud mode is not set up. No model is set, so nothing was sent.")
    }

    /// A provider that refuses is reported in its own words — and without the key it just rejected.
    /// OpenAI's 401 body quotes the key straight back, and this failure is written to the window
    /// with nobody watching, which is the copy most likely to end up in a screenshot.
    @Test func aRejectedKeyIsReportedInTheProvidersWordsWithoutTheKey() async throws {
        let key = "sk-proj-0123456789abcdefghij"
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        configureCloud()

        let provider = FakeProvider(
            status: 401,
            body: #"{"error":{"message":"Incorrect API key provided: sk-proj-0123456789abcdefghij."}}"#
        )
        guard case .failed(let message) = await cloudRunner(provider, key: key)
            .enhanceOnReady(meetingID: meeting.id)
        else {
            Issue.record("a refused provider has to say so")
            return
        }
        #expect(message.hasPrefix("api.example.com rejected the API key"))
        #expect(!message.contains(key))
        #expect(!message.contains("sk-proj-0123"))

        // Left exactly as it was, so the copyable command on the Needs write-up card is still the
        // way out. Nothing is retried: a revoked key would otherwise bill on every meeting.
        let after = try #require(try store.meeting(id: meeting.id))
        #expect(after.summary == nil)
        #expect(after.state == .ready)
    }

    // MARK: - Mode C's stand-ins

    private func configureCloud() {
        try? store.setSetting(.aiMode, AIMode.cloud.rawValue)
        try? store.setSetting(.aiCloudBaseURL, "https://api.example.com/v1")
        try? store.setSetting(.aiCloudModel, "gpt-4o-mini")
        try? store.setSetting(.aiCloudKeyRef, "cloud")
    }

    /// The key is handed in rather than read: a test must never touch the login Keychain, and the
    /// runner takes the lookup as a seam for exactly that reason.
    private func cloudRunner(_ provider: FakeProvider, key: String = "sk-live-secret") -> EnhancementRunner {
        EnhancementRunner(
            store: store,
            environment: ["HOME": directory.path],
            transport: provider.transport,
            keychain: { _ in key }
        )
    }
}

/// A provider that never was. Holds what the write-up sent so a test can prove it went to the right
/// endpoint with the right body, and opens no socket doing it.
private actor FakeProvider {
    private(set) var seen: [URLRequest] = []
    let status: Int
    let body: String

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    static func returning(_ summary: String) -> FakeProvider {
        FakeProvider(status: 200, body: #"{"choices":[{"message":{"content":"\#(summary)"}}]}"#)
    }

    nonisolated var transport: HTTPTransport {
        { request in
            await self.record(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: self.status,
                httpVersion: nil,
                headerFields: nil
            )
            return (Data(self.body.utf8), response ?? URLResponse())
        }
    }

    private func record(_ request: URLRequest) {
        seen.append(request)
    }
}
