import Foundation
import Testing

@testable import MeetingsCore

/// The general rule about help, proved across the whole write surface rather than asserted.
///
/// Wave 3 fixed `-h` and claimed the fix was general. It was not: `askedForHelp` scanned the command
/// line for `--help` at any index, so a positional whose text is exactly `--help` — an ordinary thing
/// to paste into a summary, and the literal spelling of the thing an agent has just been reading
/// about — printed root usage and exited **0**, on seven write commands, having written nothing.
/// Exit 0 means "it worked" to everything that branches on it.
///
/// So the claim is made properly this time: every write command in the tree, against every shape of
/// text that has ever been mistaken for an option, in plain mode and in `--json`.
///
/// The rule under test, in one sentence: **a help token is a help request only at the one index a
/// help request can occupy — immediately after the command name — and is that positional's text
/// everywhere else.**
@Suite final class CLIHelpPositionTests {
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

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    func run(_ arguments: [String]) throws -> Run {
        try #require(FileManager.default.fileExists(atPath: Self.cli.path),
                     "the meetings CLI is not built at \(Self.cli.path)")
        let process = Process()
        let out = Pipe()
        let err = Pipe()
        process.executableURL = Self.cli
        process.arguments = arguments
        process.environment = ["MEETINGS_HOME": directory.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = out
        process.standardError = err
        // A command that fell through to reading stdin would otherwise hang the suite, and `-` is
        // one of the probes.
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    // MARK: - The probes

    /// Every shape of text that the argument parser has ever mistaken for something else. Each one
    /// is a perfectly ordinary thing for a human or an agent to type into a note, a summary, a
    /// folder name or a setting.
    static let probes: [String] = [
        "-h",                 // the short help spelling
        "--help",             // the long one — the finding
        "help",               // the word, which is also a root subcommand
        "-",                  // stdin, when it stands where a file goes
        "--",                 // the argument terminator itself
        "",                   // empty
        "   ",                // whitespace only
        "-10:00",             // a leading-dash value
        "-notes.md",          // a dash-led filename
        "before -- after",    // text carrying the terminator inside it
        "--range -10:00",     // an option and its dash-led value, as one token
    ]

    /// The two spellings the parser owns wherever it is allowed to see them. The bare word `help`
    /// is deliberately not here: ArgumentParser only makes `help` a subcommand of a command that
    /// *has* subcommands, so at a leaf — which every write command below is — it is a positional
    /// like any other, and `meetings folder create help` really does make a folder called help.
    static func isHelpToken(_ probe: String) -> Bool {
        probe == "-h" || probe == "--help"
    }

    /// Whether this probe is text the command could use at all, before any command-specific rule.
    ///
    /// Three shapes are not: nothing (empty or whitespace), `-` where the command reads stdin and
    /// there is none, and a long token the parser owns — `--range -10:00` is an unknown option, and
    /// must come back as one rather than being quietly swallowed as somebody's notes. `--help` is
    /// the deliberate exception, and the whole point: it is text like anything else.
    static func isUsableText(_ probe: String, readsStdin: Bool) -> Bool {
        usableText(probe, readsStdin: readsStdin)
    }

    /// One write command, and how to see what it did.
    struct WriteCase {
        let name: String
        /// The subcommand words: `["prenotes", "add"]`.
        let words: [String]
        /// Run before every probe. Returns the positionals that sit between the command and the
        /// text argument, and leaves the store in a state where this probe has not been written
        /// yet — so the plain run and the `--json` run of the same probe cannot see each other.
        let prepare: (String) throws -> [String]
        /// Options that follow the text argument.
        var trailing: [String] = []
        /// What the store holds for this probe now.
        let stored: (String, [String]) throws -> String?
        /// Whether this command should have accepted the probe, and what it should hold afterwards.
        let outcome: (String) -> (succeeds: Bool, stored: String?)
    }


    /// Every command in the tree that writes a positional the caller typed.
    ///
    /// `actions set` takes JSON rather than prose, so none of the probes is usable text there and
    /// it never reaches the success branch — which is itself worth walking, because "unusable" is
    /// exactly the input that used to come back as help.
    func writeCases() -> [WriteCase] {
        func freshMeeting() throws -> String {
            try store.createMeeting(TestStore.meeting(title: "Detector housing design review")).id
        }
        func meetingCase(
            _ name: String,
            _ words: [String],
            trailing: [String] = [],
            outcome: @escaping (String) -> (Bool, String?) = prose,
            read: @escaping (Meeting) -> String?
        ) -> WriteCase {
            WriteCase(
                name: name,
                words: words,
                prepare: { _ in [try freshMeeting()] },
                trailing: trailing,
                stored: { [store] _, leading in
                    try store.meeting(id: leading[0]).flatMap(read)
                },
                outcome: outcome
            )
        }

        return [
            meetingCase("prenotes add", ["prenotes", "add"]) { $0.preNotes.isEmpty ? nil : $0.preNotes },
            meetingCase("prenotes set", ["prenotes", "set"]) { $0.preNotes.isEmpty ? nil : $0.preNotes },
            // `summary set` is the one command where empty input is a documented operation rather
            // than a mistake: it clears the summary and walks the meeting back from complete to
            // ready. So `""`, whitespace and an empty stdin succeed, having stored nothing — and
            // they say "Cleared the summary" while they do it, which is the difference between an
            // exit 0 that means something and the one this suite exists to catch.
            meetingCase("summary set", ["summary", "set"], outcome: { probe in
                if usableText(probe, readsStdin: true) { return (true, probe) }
                let blank = probe.trimmingCharacters(in: .whitespaces).isEmpty || probe == "-"
                return blank ? (true, nil) : (false, nil)
            }) { $0.summary },
            WriteCase(
                name: "note add",
                words: ["note", "add"],
                prepare: { _ in [try freshMeeting()] },
                trailing: ["--at", "0:03"],
                stored: { [store] _, leading in try store.notes(meetingID: leading[0]).last?.text },
                outcome: prose
            ),
            WriteCase(
                name: "actions set",
                words: ["actions", "set"],
                prepare: { _ in [try freshMeeting()] },
                stored: { [store] _, leading in
                    try store.meeting(id: leading[0])?.actions?.first?.text
                },
                // Takes JSON rather than prose, and no probe is valid JSON — so every run must
                // refuse, which is exactly the input that used to come back as help.
                outcome: { _ in (false, nil) }
            ),
            WriteCase(
                name: "folder create",
                words: ["folder", "create"],
                prepare: { [store] probe in
                    if let folder = try store.folder(named: probe) { _ = try store.deleteFolder(id: folder.id) }
                    return []
                },
                stored: { [store] probe, _ in try store.folder(named: probe)?.name },
                outcome: { usableText($0, readsStdin: false) ? (true, $0) : (false, nil) }
            ),
            WriteCase(
                name: "vocab add",
                words: ["vocab", "add"],
                prepare: { [store] probe in
                    for term in try store.vocabularyTerms(term: probe) {
                        if let id = term.id { _ = try store.deleteVocabularyTerm(id: id) }
                    }
                    return []
                },
                stored: { [store] probe, _ in try store.vocabularyTerms(term: probe).first?.term },
                // Plus the one rule this command has of its own: a term the recogniser would ignore
                // is refused rather than stored (`CLIVocabularyTests`).
                outcome: { probe in
                    let usable = usableText(probe, readsStdin: false)
                        && probe.count >= VocabularyBiasing.minimumTermLength
                    return usable ? (true, probe) : (false, nil)
                }
            ),
            WriteCase(
                name: "config set",
                words: ["config", "set"],
                prepare: { [store] _ in
                    try store.setSetting(.aiCloudModel, nil)
                    return ["ai.cloud.model"]
                },
                stored: { [store] _, _ in try store.setting(.aiCloudModel) },
                // A setting's value is a plain string: `-` is not stdin here, and empty is a value.
                // `--` is the argument terminator in every CLI there is, so `config set <key> --`
                // is a key with no value at all, which this command reads as "restore the default".
                outcome: { probe in
                    if probe == "--" { return (true, nil) }
                    return usableText(probe, readsStdin: false) || probe.trimmingCharacters(in: .whitespaces).isEmpty
                        ? (true, probe)
                        : (false, nil)
                }
            ),
        ]
    }

    // MARK: - The walk

    /// The whole matrix: every write command against every probe, in both output modes.
    ///
    /// Two things are asserted of every single run, and they are the two halves of the rule:
    ///
    /// 1. **Help is answered only where a help request can sit.** At that index, help is still help
    ///    — exit 0, usage on stdout. At any other index the same token is text, and usage must not
    ///    appear on stdout, because usage on stdout with exit 0 is indistinguishable from the work
    ///    having been done.
    /// 2. **A run that exits 0 wrote what it was given.** Not "did not crash" — the exact text is
    ///    read back out of the store. A run that exits non-zero wrote nothing and said 64.
    @Test func everyWriteCommandTreatsEveryProbeAsTextExceptAtTheHelpPosition() throws {
        for probe in Self.probes {
            for writeCase in writeCases() {
                for json in [false, true] {
                    let leading = try writeCase.prepare(probe)
                    // `--` swallows everything after it, so in JSON mode the flag has to come
                    // before it. Everywhere else it goes where a caller would type it — at the end
                    // — which is also what keeps `<cmd> --help` a help request on a command whose
                    // text is its first positional.
                    var argv = writeCase.words + leading
                    if json, probe == "--" { argv.append("--json") }
                    argv += [probe] + writeCase.trailing
                    if json, probe != "--" { argv.append("--json") }

                    let spelled = "meetings \(argv.joined(separator: " "))"
                    let result = try run(argv)

                    // The one index at which the token standing in the text's place is a help
                    // request: the command took no positional before it, so nothing was displaced.
                    if leading.isEmpty, Self.isHelpToken(probe) {
                        #expect(result.status == 0, "\(spelled) is a help request and must succeed")
                        #expect(result.stdout.contains("OVERVIEW:"), "\(spelled) must answer with help")
                        continue
                    }

                    #expect(!result.stdout.contains("OVERVIEW:"),
                            "\(spelled) answered with help — on stdout that reads as the answer")

                    let expected = writeCase.outcome(probe)
                    if expected.succeeds {
                        #expect(result.status == 0, "\(spelled) exited \(result.status)")
                        #expect(try writeCase.stored(probe, leading) == expected.stored,
                                "\(spelled) exited 0 without writing what it was given")
                    } else {
                        #expect(result.status == 64,
                                "\(spelled) exited \(result.status) — an unusable command line is a usage error")
                        #expect(try writeCase.stored(probe, leading) == nil,
                                "\(spelled) failed and wrote something anyway")
                        if json {
                            // The mode agents branch on: a failure has to arrive as an envelope
                            // carrying a failing code, never as prose with an empty stdout.
                            let envelope = try #require(
                                try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
                                "\(spelled) failed without a JSON envelope — stdout was \(result.stdout.debugDescription)")
                            let error = try #require(envelope["error"] as? [String: Any])
                            #expect((error["code"] as? Int) == 64)
                        }
                    }
                }
            }
        }
    }

    /// The escape hatch, which is what makes the rule above liveable: a command whose *first*
    /// positional is the text cannot tell `folder create -h` from a request for help, so `--` is
    /// how you say you meant the two characters.
    @Test func theTerminatorStillWritesAHelpTokenAsText() throws {
        #expect(try run(["folder", "create", "--", "-h"]).status == 0)
        #expect(try store.folder(named: "-h") != nil)
        #expect(try run(["vocab", "add", "--", "--help"]).status == 0)
        #expect(try store.vocabularyTerms(term: "--help").count == 1)
    }

    /// And the other direction, at every depth of the tree: a help request where one can sit is
    /// still answered, in all three spellings. Losing this would be trading one broken command line
    /// for another.
    @Test func aHelpRequestAtTheHelpPositionIsStillHelp() throws {
        let lines: [[String]] = [
            [], ["-h"], ["--help"], ["help"],
            ["show", "-h"], ["show", "--help"],
            ["prenotes", "-h"], ["prenotes", "add", "-h"], ["prenotes", "add", "--help"],
            ["summary", "set", "--help"], ["note", "add", "--help"], ["actions", "set", "--help"],
            ["folder", "create", "--help"], ["vocab", "add", "--help"], ["config", "set", "--help"],
            ["transcript", "--help"], ["transcript-edit", "--help"], ["import", "--help"],
            ["export", "--help"], ["create", "--help"], ["backup", "--help"], ["move", "--help"],
        ]
        for line in lines {
            let result = try run(line)
            #expect(result.status == 0, "meetings \(line.joined(separator: " ")) exited \(result.status)")
            #expect(result.stdout.contains("OVERVIEW:"),
                    "meetings \(line.joined(separator: " ")) did not answer with help")
        }
    }

    /// A dash-led value behind an option that takes one still reaches the option rather than
    /// becoming a stray positional — the other half of the same rescue, on a read and on a write.
    @Test func anOptionsDashLedValueStillReachesTheOption() throws {
        let meeting = try store.createMeeting(TestStore.meeting(title: "Detector housing"))
        try store.insertSegments([
            TestStore.segment(meetingID: meeting.id, from: 0, to: 9_000,
                              text: "Right, the flange tolerance.", pass: .final),
        ])
        let transcript = try run(["transcript", meeting.id, "--range", "-5:00"])
        #expect(transcript.status == 0)
        #expect(transcript.stdout.contains("flange tolerance"))

        _ = try store.createFolder(Folder(name: "-hardware"))
        #expect(try run(["move", meeting.id, "--folder", "-hardware"]).status == 0)
        #expect(try store.meeting(id: meeting.id)?.folderID == store.folder(named: "-hardware")?.id)
    }
}

/// Whether this probe is text the command could use at all, before any command-specific rule.
///
/// Three shapes are not: nothing (empty or whitespace), `-` where the command reads stdin and there
/// is none, and a long token the parser owns — `--range -10:00` is an unknown option and must come
/// back as one rather than being quietly swallowed as somebody's notes. `--help` is the deliberate
/// exception, and the whole point: it is text like anything else.
private func usableText(_ probe: String, readsStdin: Bool) -> Bool {
    if probe.trimmingCharacters(in: .whitespaces).isEmpty { return false }
    if probe == "-", readsStdin { return false }
    if probe.hasPrefix("--"), probe != "--help" { return false }
    return true
}

/// The rule for a command that takes prose and reads `-` as stdin: usable text round-trips, and
/// anything else is refused. Nothing in between.
private func prose(_ probe: String) -> (Bool, String?) {
    usableText(probe, readsStdin: true) ? (true, probe) : (false, nil)
}
