import ArgumentParser
import Foundation
import MeetingsCore

/// `meetings skill install`. The command surface is deliberately one verb: the skill is
/// either the version this build ships or it is wrong, and there is nothing else to ask about it.
struct SkillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Install the bundled agent skill so `meetings` works from any directory.",
        subcommands: [Install.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Write SKILL.md into the agent tools installed on this Mac.",
            discussion: """
                Always writes to ~/.claude/skills/meetings/SKILL.md, and to the equivalent path for \
                any other agent tool whose config directory already exists. A tool's config \
                directory is never created.

                The file is overwritten every run. If what is already there differs, it is copied \
                to SKILL.md.bak alongside first and the backup is named in the output. A copy that \
                already matches is left alone and reported as unchanged.
                """
        )

        @Flag(name: .long, help: "Show what would be written without writing anything.")
        var dryRun = false

        @OptionGroup var global: GlobalOptions

        func run() async throws {
            try await emitting(json: global.json) {
                let results = try SkillInstall.install(dryRun: dryRun)

                if global.json {
                    try Out.json(SkillInstallJSON(dryRun: dryRun, targets: results))
                    return
                }

                // Ahead of the plan rather than after it: stderr is unbuffered and stdout is not,
                // so a trailing caveat arrives first the moment the output is piped anywhere.
                if dryRun {
                    Out.note("--dry-run: this is the plan, nothing is written.")
                }

                Out.line(Format.columns(results.map { result in
                    [label(for: result.outcome), result.tool, detail(for: result)]
                }).joined(separator: "\n"))
            }
        }

        /// Past tense for what happened, conditional for a dry run — the one word at the start of
        /// the line has to be true.
        private func label(for outcome: SkillInstall.Outcome) -> String {
            switch (outcome, dryRun) {
            case (.installed, false): "installed"
            case (.installed, true): "would install"
            case (.replaced, false): "replaced"
            case (.replaced, true): "would replace"
            case (.unchanged, _): "unchanged"
            case (.skipped, _): "skipped"
            }
        }

        private func detail(for result: SkillInstall.Result) -> String {
            switch result.outcome {
            case .skipped:
                return result.note ?? "not installed here"
            case .replaced:
                let backup = result.backupPath.map { " (previous copy kept at \($0))" } ?? ""
                return result.path + backup
            case .installed, .unchanged:
                return result.path
            }
        }
    }
}

private struct SkillInstallJSON: Encodable {
    let dryRun: Bool
    let targets: [SkillInstall.Result]
}
