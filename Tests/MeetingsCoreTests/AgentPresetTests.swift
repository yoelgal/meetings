import Foundation
import Testing

@testable import MeetingsCore

/// The pre-filled agent commands. **Nothing here executes an agent CLI** — the point of the suite is
/// the shape of the strings, because the failure a wrong preset causes is silent: the command runs,
/// exits, and no summary appears. There is no assertion that a vendor's flag is still that vendor's
/// flag; only their docs can say so, and the provenance of each is recorded in ``AgentPreset``'s doc
/// comment. What is checked here is every rule the app itself relies on.
@Suite struct AgentPresetTests {
    private let directory: URL

    init() throws {
        directory = try TestStore.makeDirectory()
    }

    /// A directory containing executable stand-ins for the named agents, and nothing else. Detection
    /// is pointed at exactly this so a suite run never depends on what the machine has installed.
    private func bin(containing names: String...) throws -> String {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names {
            let file = folder.appendingPathComponent(name)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return folder.path
    }

    // MARK: - Every preset has to be launchable

    /// `argv[0]` is what `/usr/bin/env` looks for, and ``AgentPreset/detected(searchPath:)`` decides
    /// a preset is available by resolving ``AgentPreset/executable``. If those two disagree, the
    /// setup step offers an agent it has confirmed is installed and then runs something else.
    @Test func theFirstTokenIsTheExecutableThatWasCheckedFor() {
        for preset in AgentPreset.all {
            #expect(EnhancementRunner.tokenize(preset.runCommand).first == preset.executable,
                    "\(preset.name)'s command must start with the binary detection looks for")
        }
    }

    /// Both commands are templates. One without the placeholder would run the agent against no
    /// meeting at all — a real spend, unattended, producing nothing.
    @Test func bothCommandsCarryThePlaceholder() {
        for preset in AgentPreset.all {
            #expect(preset.runCommand.contains("{meeting_id}"), "\(preset.name) run command")
            #expect(preset.pasteCommand.contains("{meeting_id}"), "\(preset.name) paste command")
        }
    }

    /// Substitution happens after tokenising, so a placeholder split across two tokens would never
    /// be replaced. Every run command has to survive the round trip the runner actually performs.
    @Test func thePlaceholderSurvivesTokenising() {
        for preset in AgentPreset.all {
            let argv = EnhancementRunner.command(template: preset.runCommand, meetingID: "abc-123")
            #expect(argv.contains { $0.contains("abc-123") }, "\(preset.name)")
            #expect(!argv.contains { $0.contains("{meeting_id}") },
                    "\(preset.name) left an unsubstituted placeholder in argv")
        }
    }

    /// The two forms are not interchangeable: the executed one has to start with a binary, and the
    /// pasted one is typed into a session that is already open, so it must never be an invocation.
    /// One setting doing both jobs was a real bug, and the copy button handed out something that
    /// could only fail.
    @Test func thePastedFormIsNeverAnInvocation() {
        for preset in AgentPreset.all {
            #expect(!preset.pasteCommand.hasPrefix(preset.executable),
                    "\(preset.name)'s pasteable line must not be a command to run")
            #expect(preset.pasteCommand.first == "/" || preset.pasteCommand.first == "$",
                    "\(preset.name)'s pasteable line has to be the form its own session accepts")
        }
    }

    /// Names are the identity, so a duplicate would silently collapse two rows in the picker, and a
    /// duplicated executable would make detection's order meaningless.
    @Test func presetsAreDistinct() {
        #expect(Set(AgentPreset.all.map(\.id)).count == AgentPreset.all.count)
        #expect(Set(AgentPreset.all.map(\.executable)).count == AgentPreset.all.count)
    }

    // MARK: - Round-tripping a stored command

    /// The picker reads the stored template back through ``AgentPreset/matching(runCommand:)``, so
    /// every command it can write has to be one it recognises. A preset that did not round-trip
    /// would show as "Something else" the moment the window was reopened.
    @Test func everyPresetRoundTrips() {
        for preset in AgentPreset.all {
            #expect(AgentPreset.matching(runCommand: preset.runCommand) == preset, "\(preset.name)")
        }
    }

    /// A fresh install's stored command is the shipped default. If that did not match a preset, the
    /// picker would open on "Something else" for every new user — which is the label that says "you
    /// hand-wrote this", about a value they have never seen.
    @Test func theShippedDefaultIsAPreset() throws {
        let stored = try #require(SettingKey.aiLocalAgentRunCommand.defaultValue)
        #expect(AgentPreset.matching(runCommand: stored)?.name == "Claude Code")
    }

    /// The pasted default has to be a preset's pasted form too, for the same reason: the two cards
    /// in Settings would otherwise disagree about which agent is set up on a fresh install.
    @Test func theShippedPasteDefaultIsAPresetsPasteForm() throws {
        let stored = try #require(SettingKey.aiManualPasteCommand.defaultValue)
        #expect(AgentPreset.all.contains { $0.pasteCommand == stored })
    }

    /// Surrounding whitespace is not a different command — a text field hands back what was typed.
    @Test func whitespaceDoesNotBreakTheMatch() throws {
        let preset = try #require(AgentPreset.all.first)
        #expect(AgentPreset.matching(runCommand: "  \(preset.runCommand)\n") == preset)
    }

    /// Anything the app did not write is "Something else", including a preset the user then edited.
    /// Claiming an edited command as its preset would mean overwriting that edit the next time the
    /// picker was touched.
    @Test(arguments: [
        "/usr/local/bin/my-agent {meeting_id}",
        #"claude -p "/meetings {meeting_id}" --verbose"#,
        #"claude --print "/meetings {meeting_id}""#,
        "claude",
        "",
    ])
    func aHandWrittenCommandMatchesNothing(command: String) {
        #expect(AgentPreset.matching(runCommand: command) == nil)
    }

    // MARK: - Detection

    /// Detection resolves against the widened PATH rather than the app's own, which is the reported
    /// bug one layer up: the agent is installed where only the login shell knows about, and it still
    /// has to be found. Asserted through the resolver rather than through
    /// ``AgentPreset/detected(searchPath:)`` so the result cannot depend on what this Mac happens to
    /// have in `/opt/homebrew/bin`.
    @Test func anAgentIsFoundWhereverTheShellSaysItIs() throws {
        let bunBin = try bin(containing: "omp")
        let path = EnhancementRunner.searchPath(in: ["HOME": "/Users/tester", "PATH": "/usr/bin"]) {
            "\(LoginShellPath.marker)\(bunBin)\(LoginShellPath.marker)"
        }
        let resolved = try #require(AIVerify.executable("omp", searchPath: path))
        #expect(resolved.hasPrefix(bunBin), "it has to be the one the shell pointed at")
        #expect(resolved.hasSuffix("/omp"))
    }

    /// With several installed, order decides, and the order is the point: a Mac with both should
    /// land on the one the user most likely means rather than on whichever comes first
    /// alphabetically or on disk.
    @Test func theEarlierPresetWins() throws {
        let path = try bin(containing: "opencode", "claude", "omp")
        #expect(AgentPreset.detected(searchPath: path)?.name == "Claude Code")
    }

    /// Each preset is reachable — a preset nobody can ever be detected as would be dead weight in
    /// the picker, and this is how a typo in `executable` shows up.
    @Test func everyPresetCanBeDetected() throws {
        for preset in AgentPreset.all {
            let path = try bin(containing: preset.executable)
            #expect(AgentPreset.detected(searchPath: path) == preset, "\(preset.name)")
        }
    }

    /// Nil, not a guess. The wizard has something useful to say about "no agent found" and nothing
    /// useful to say about an agent it invented.
    @Test func nothingInstalledIsNil() throws {
        let empty = try bin()
        #expect(AgentPreset.detected(searchPath: empty) == nil)
    }

    /// A directory entry that is not executable is not an installed agent — a stray `claude` note in
    /// `~/bin` must not make the wizard offer Claude Code and then fail to launch it.
    @Test func aNonExecutableFileIsNotAnAgent() throws {
        let folder = directory.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "not a binary".write(
            to: folder.appendingPathComponent("claude"), atomically: true, encoding: .utf8
        )
        #expect(AgentPreset.detected(searchPath: folder.path) == nil)
    }
}
