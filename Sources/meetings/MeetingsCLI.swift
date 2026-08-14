import ArgumentParser
import Foundation
import MeetingsCore

/// The command tree. The read path came first; the write path (pre-notes, notes, summary, actions,
/// folders, vocabulary, config) sits alongside it, and export/import are added as they land. The
/// store, the ref resolver, the error-to-exit-code mapping and `--json` live in `CLISupport.swift`.
struct MeetingsCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meetings",
        abstract: "Your local meeting store, one shell command away.",
        discussion: """
            Every command takes --json and prints exactly one JSON value on stdout; logs, warnings \
            and errors in plain mode go to stderr.

            Exit codes: 0 ok, 1 unexpected failure, 2 not found, 3 invalid state for the operation, \
            4 ambiguous, 64 usage error.

            A <ref> is either a meeting id or cal:<eventIdentifier> for a calendar event that has no \
            row yet.
            """,
        subcommands: [
            StatusCommand.self,
            ListCommand.self,
            ShowCommand.self,
            TranscriptCommand.self,
            SearchCommand.self,
            UpcomingCommand.self,
            PreNotesCommand.self,
            NoteCommand.self,
            SummaryCommand.self,
            ActionsCommand.self,
            FolderCommand.self,
            MoveCommand.self,
            DeleteCommand.self,
            VocabCommand.self,
            ConfigCommand.self,
            FitCommand.self,
            AICommand.self,
            TranscriptEditCommand.self,
            ExportCommand.self,
            ImportCommand.self,
            CreateCommand.self,
            BackupCommand.self,
            SkillCommand.self,
        ]
    )

    /// The one place that sees raw argv, and the only place two spellings the parser cannot express
    /// get turned into ones it can. Both rewrites are shape-only: no command is chosen here.
    static func normalisedArguments(_ arguments: [String]) -> [String] {
        rescuingDashLedText(spellingTranscriptEdit(arguments))
    }

    /// The transcript correction is spelled `meetings transcript edit <ref>`, and ArgumentParser
    /// cannot express that: `transcript` takes a positional `<ref>`, and positionals are filled
    /// before subcommand names are looked for, so `edit` would be read as the ref and `--segment`
    /// would come back as an unknown option.
    private static func spellingTranscriptEdit(_ arguments: [String]) -> [String] {
        guard arguments.count >= 2, arguments[0] == "transcript", arguments[1] == "edit" else {
            return arguments
        }
        return ["transcript-edit"] + arguments.dropFirst(2)
    }

    /// The long options this CLI declares as `@Flag`. A flag never takes a value, so a dash-led
    /// token sitting behind one is text rather than that flag's argument. Listing the flags rather
    /// than the options is the safe direction: a name missing from here only means a rescue is
    /// skipped, never that a real option loses its value.
    private static let flagNames: Set<String> = [
        "--add-vocab", "--all", "--dry-run", "--force", "--global", "--help", "--json",
        "--notes", "--open", "--summary", "--transcript", "--with-audio", "--yes",
    ]

    /// This CLI declares no short options — every option in the tree is a long one, and `-h` is the
    /// only single-dash token ArgumentParser owns. So a single-dash token that is not `-` (which
    /// means stdin) is never an option here: it is text whose first character happens to be a dash.
    /// Long tokens are left alone in every case, so a mistyped `--fldr` still comes back as
    /// "unknown option" rather than being quietly swallowed as somebody's pre-notes.
    ///
    /// `-h` is included, and where it is allowed to mean help is decided by position — see
    /// ``helpPosition(in:)``.
    static func isDashLedText(_ token: String) -> Bool {
        token.hasPrefix("-") && !token.hasPrefix("--") && token != "-"
    }

    /// The three spellings of a help request. None of them is a help request everywhere: each is
    /// answered only at ``helpPosition(in:)``, and is ordinary text at every other index.
    static func isHelpToken(_ token: String) -> Bool {
        token == "-h" || token == "--help" || token == "help"
    }

    /// The deepest command the leading tokens name, and how many tokens that took: `list` is one,
    /// `prenotes add` is two, `--json` alone is zero.
    ///
    /// Read off the command tree itself rather than from a second list that would have to be kept in
    /// step with it — a subcommand added anywhere is known here the moment it is registered.
    static func commandPath(_ arguments: [String]) -> (length: Int, command: ParsableCommand.Type?) {
        var tree = configuration.subcommands
        var deepest: ParsableCommand.Type?
        var length = 0
        for token in arguments {
            guard let match = tree.first(where: { $0.configuration.commandName == token }) else { break }
            deepest = match
            tree = match.configuration.subcommands
            length += 1
        }
        return (length, deepest)
    }

    /// The one index at which `-h`, `--help` or `help` can mean "show me the help": immediately
    /// after the command name, before any positional has been given.
    ///
    /// This is what tells a help request from a positional whose text is exactly `-h`. Both are
    /// perfectly ordinary things to type — `meetings show -h` wants help, `meetings prenotes add
    /// <ref> "-h"` is somebody appending two characters to their notes — and nothing but where the
    /// token sits distinguishes them.
    ///
    /// `--help` is held to exactly the same rule, and wave 3 was wrong to exempt it on the grounds
    /// that ArgumentParser owns the spelling everywhere. Owning it everywhere is the defect: seven
    /// write commands answered `prenotes add <ref> -- --help` — sorry, `prenotes add <ref> "--help"`
    /// — with root usage and exit 0, having written nothing. A positional is whatever the shell
    /// handed us, and `--help` is as ordinary a thing to paste into a summary as `-h` is.
    static func helpPosition(in arguments: [String]) -> Int {
        commandPath(arguments).length
    }

    /// ArgumentParser reads any token starting with `-` as a cluster of short options, so
    /// `prenotes add <ref> "- push back on March"` became a request for `-p -u -s -h …` — and `-h`
    /// is help, which prints usage and exits **0** having written nothing. A markdown bullet is the
    /// single most likely thing anyone appends to pre-notes, so the natural invocation has to work.
    ///
    /// Two rewrites, both driven only by shape:
    ///
    /// - A dash-led value behind a value-taking option is joined to it (`--range -10:00` becomes
    ///   `--range=-10:00`), which is the form the parser already accepts and the skill documents.
    /// - Anything else dash-led that is not option-shaped is a positional, so it moves behind a `--`
    ///   terminator at the end of the line, where the parser reads it as the literal text it is.
    ///
    /// A command line that already carries its own `--` is left exactly as the caller wrote it.
    static func rescuingDashLedText(_ arguments: [String]) -> [String] {
        guard !arguments.contains("--") else { return arguments }
        let help = helpPosition(in: arguments)
        var head: [String] = []
        var positionals: [String] = []
        for (index, token) in arguments.enumerated() {
            // A help token where a help request can legally sit is left for the parser to answer.
            // One anywhere else is standing in a positional's place, so it is that positional's
            // text — and `--help` has to be rescued here explicitly, because it is the one long
            // spelling the parser would otherwise claim from under a positional.
            guard !(isHelpToken(token) && index == help),
                  isDashLedText(token) || token == "--help" else {
                head.append(token)
                continue
            }
            if let previous = head.last, previous.hasPrefix("--"), !previous.contains("="),
               !flagNames.contains(previous) {
                head[head.count - 1] = previous + "=" + token
            } else {
                positionals.append(token)
            }
        }
        return positionals.isEmpty ? head : head + ["--"] + positionals
    }

    /// Did the caller actually ask for help? Only then may a run print usage and exit 0.
    ///
    /// Takes the **normalised** command line, so anything already moved behind a `--` terminator is
    /// text and is not read here at all. All three spellings — `-h`, `--help`, `help` — count at
    /// ``helpPosition(in:)`` and nowhere else, because at any other index they are a positional's
    /// text and answering them with help would be a run that exited 0 having written nothing.
    static func askedForHelp(_ arguments: [String]) -> Bool {
        if arguments.isEmpty { return true }
        let options = Array(arguments.prefix { $0 != "--" })
        let position = helpPosition(in: arguments)
        guard options.indices.contains(position) else { return false }
        return isHelpToken(options[position])
    }

    /// A command group named without one of its subcommands: `meetings summary`, `meetings skill`.
    ///
    /// ArgumentParser answers that with usage, which says everything except what went wrong. Nothing
    /// on the line is malformed — it stops one word short — so the message has to say that and name
    /// the words that finish it. A group with a default subcommand never lands here: `meetings
    /// config` is a complete command line.
    static func missingSubcommand(_ arguments: [String]) -> (path: String, subcommands: [String])? {
        let (length, command) = commandPath(arguments)
        guard length > 0, let command, command.configuration.defaultSubcommand == nil else { return nil }
        var subcommands: [String] = []
        for subcommand in command.configuration.subcommands {
            if let name = subcommand.configuration.commandName { subcommands.append(name) }
        }
        guard !subcommands.isEmpty else { return nil }
        // A non-option token after the command path is an argument the group did not want, which is
        // a different mistake with its own message. Options are kept: `meetings summary --json` is
        // still a missing subcommand, and an agent in JSON mode has to be told which one.
        guard arguments.dropFirst(length).allSatisfy({ $0.hasPrefix("-") }) else { return nil }
        return (arguments.prefix(length).joined(separator: " "), subcommands)
    }
}

/// The entry point is spelled out rather than left to `@main` on the command itself because `--json`
/// has to answer with JSON even when the failure happens in the parser, before any command runs. An
/// agent that asked for JSON and got `Error: unknown option '--fldr'` as prose has to go back to
/// matching strings, which is exactly what the flag exists to avoid.
@main
enum Main {
    static func main() async {
        let raw = Array(CommandLine.arguments.dropFirst())
        let arguments = MeetingsCLI.normalisedArguments(raw)
        do {
            var command = try await MeetingsCLI.asyncParseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            // A command that already reported its own failure throws a bare ExitCode; reporting it
            // again here would print the error twice.
            if let exit = error as? ExitCode {
                Foundation.exit(exit.rawValue)
            }
            let help = MeetingsCLI.askedForHelp(arguments)
            // A group named without one of its subcommands. Checked ahead of everything else
            // because ArgumentParser reports it two different ways — usage for `meetings summary`,
            // "unknown option '--json'" for `meetings summary --json` — and neither names the one
            // thing that is actually missing.
            if !help, let missing = MeetingsCLI.missingSubcommand(arguments) {
                let spelled = missing.subcommands.map { "meetings \(missing.path) \($0)" }
                usageFailure(
                    "\(missing.path) needs a subcommand, so nothing ran and nothing was written. "
                        + "Use one of: \(spelled.joined(separator: ", ")).",
                    arguments: arguments,
                    detail: MeetingsCLI.message(for: error)
                )
            }
            // Help is exit 0, and ArgumentParser answers some unreadable command lines with a help
            // request rather than an error. Exit 0 means "it worked" to everything that branches on
            // it, so a run that printed usage instead of doing the job would be reporting success
            // for a write that never happened. Help nobody asked for is a usage error.
            if MeetingsCLI.exitCode(for: error).rawValue == CLIExit.ok, !help {
                usageFailure(
                    "I could not read that command line, so nothing ran and nothing was written. "
                        + "Text beginning with a dash has to come after --, in --file <path>, or on "
                        + "stdin with -.",
                    arguments: arguments,
                    detail: MeetingsCLI.message(for: error)
                )
            }
            if CommandLine.arguments.contains("--json"), !(error is CleanExit) {
                let code = MeetingsCLI.exitCode(for: error).rawValue
                Out.errorJSON(code: code, message: MeetingsCLI.message(for: error))
                Foundation.exit(code)
            }
            MeetingsCLI.exit(withError: error)
        }
    }

    /// Exit 64 with one sentence saying what went wrong, in whichever shape the caller asked for.
    /// `detail` is ArgumentParser's own text, which is worth printing under the sentence for a human
    /// and worth leaving out of a JSON envelope that is parsed rather than read.
    private static func usageFailure(_ message: String, arguments: [String], detail: String) -> Never {
        if arguments.contains("--json") {
            Out.errorJSON(code: CLIExit.usage, message: message)
        } else {
            Out.note("meetings: " + message)
            Out.note(detail)
        }
        Foundation.exit(CLIExit.usage)
    }
}
