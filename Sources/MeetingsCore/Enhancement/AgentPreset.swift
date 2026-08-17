import Foundation

/// One coding agent, and the two command forms it needs.
///
/// Data, deliberately: adding an agent is an element of ``all`` and nothing else. Neither the
/// Settings window nor the wizard branches on which agent this is, so the day a new CLI matters the
/// change is one struct literal rather than a new case in three switch statements.
///
/// The two commands are not interchangeable, which is the whole reason both are here:
///
/// - ``runCommand`` is **executed** by ``EnhancementRunner``, unattended, when a meeting reaches
///   `ready`. `argv[0]` has to be a real binary and the invocation has to be the agent's
///   *non-interactive* one, because there is no terminal on the other end. An agent that opens an
///   interactive session instead sits there until it is killed, having written nothing.
/// - ``pasteCommand`` is **displayed**, for pasting into a session the user already has open. It is
///   never executed, so a slash command belongs here and only here.
///
/// ## Where these flags came from
///
/// A wrong flag here does not error — it produces a run that writes no summary, which surfaces to
/// the user as "the write-up just doesn't happen". So the provenance of every one is recorded, and
/// none of it is from memory:
///
/// | Agent | Non-interactive flag | How it was established |
/// |---|---|---|
/// | Claude Code | `-p` | `claude --help` on this Mac, 2026-08-17: "starts an interactive session by default, use -p/--print for non-interactive output". |
/// | Codex | `exec` (positional prompt) | `openai/codex` source, `codex-rs/exec/src/cli.rs`, 2026-08-17: `override_usage = "codex exec [OPTIONS] [PROMPT]"`. **`-p` is `--profile` here**, so `codex -p "…"` swallows the prompt as a profile name. |
/// | Cursor Agent | `-p` + positional prompt | cursor.com/docs/cli/reference/parameters and /cli/headless, 2026-08-17. `-p/--print` is a boolean switch; the prompt stays positional. |
/// | Gemini CLI | `-p` | geminicli.com/docs/cli/cli-reference, 2026-08-17: "Forces non-interactive mode". A bare positional query stays *interactive* in a TTY. |
/// | opencode | `run` (positional prompt) | opencode.ai/docs/cli, 2026-08-17: `opencode run [message..]`. **`-p` is `--password`** on `run`. |
/// | omp | `-p` | `omp --help` on this Mac, 2026-08-17: "-p, --print  Non-interactive mode: process prompt and exit". This is the invocation the operator was already using. |
///
/// ## What is deliberately missing, and why
///
/// Most of these CLIs gate tool use behind an approval, and headless is exactly where that gate has
/// nobody to answer it: Gemini's docs say an `ask_user` "in non-interactive mode is treated as
/// `deny`", `codex exec` pins its approval policy to never-ask and runs read-only, and Cursor's
/// print mode only *proposes* edits. Every one has a flag that turns the gate off — `--approval-mode=yolo`,
/// `--sandbox danger-full-access`, `--force`, `opencode --auto` — and **none of them is pre-filled here.**
///
/// That is this repo's existing posture, not a new opinion: the shipped Claude Code default has
/// never carried its equivalent, and ``EnhancementRunner`` is off by default precisely because these
/// modes "spend money or subscription usage without asking and run where you cannot watch them".
/// Pre-arming a process that fires unattended on a `ready` transition with blanket permission to do
/// anything is a decision for the person whose Mac it is. The field is editable, and each agent's
/// flag is named in the paragraph above so it is one paste away.
///
/// The consequence is honest and worth stating: on the agents that gate writes, this command may
/// come back having written nothing until the user adds their agent's flag. That is a visible
/// "no summary appeared" with a fix the user chose, rather than an invisible "your unattended
/// agent has full disk access" they did not.
///
/// One flag *is* pre-filled, and it is not a permission. `codex exec` checks it is inside a Git
/// working tree and calls `exit(1)` before any model call when it is not
/// (`codex-rs/exec/src/lib.rs`, 2026-08-17); a GUI app's working directory is `/`, which never is
/// one. `--skip-git-repo-check` is the difference between running and not running, which is a
/// different question from what the run may touch.
///
/// ## The slash command
///
/// `meetings skill install` writes the skill to `skills/meetings`, so the slash command is
/// `/meetings`. It writes it for **Claude Code and opencode only** — every other tool's config
/// directory is gated on already existing and is not one of ``SkillInstall/targets(home:)``. For the
/// other agents here, ``pasteCommand`` is the form their own documentation says a skill of that name
/// is invoked with, and it answers once the user has put the skill where that agent looks. Codex is
/// the one agent with no `/name` form at all: its skills are mentioned with `$`
/// (learn.chatgpt.com/docs/build-skills, 2026-08-17), and its `/prompts:name` alternative is marked
/// deprecated, so the `$` form is what is offered.
public struct AgentPreset: Identifiable, Sendable, Hashable {
    /// The name is the identity: two presets for the same agent would be a bug, and the UI lists
    /// these by name anyway.
    public var id: String { name }
    /// "Claude Code" — what the user recognises, spelled the way the vendor spells it.
    public let name: String
    /// `argv[0]`; what has to be on PATH for ``runCommand`` to launch.
    public let executable: String
    /// Mode B, executed. Contains `{meeting_id}`.
    public let runCommand: String
    /// Mode A, pasted into a session already open. Contains `{meeting_id}`.
    public let pasteCommand: String

    public init(name: String, executable: String, runCommand: String, pasteCommand: String) {
        self.name = name
        self.executable = executable
        self.runCommand = runCommand
        self.pasteCommand = pasteCommand
    }

    /// Ordered by how many people use the thing, most first, because ``detected(searchPath:)`` takes
    /// the first match and a Mac with several of these installed should land on the one the user
    /// most likely means. Claude Code leads on that count and is also the one whose skill
    /// `meetings skill install` always writes, so the common case is the case that works.
    ///
    /// The Claude Code entry is byte-identical to `SettingKey.aiLocalAgentRunCommand`'s shipped
    /// default, and has to stay that way: a fresh install's stored command is that default, and if
    /// it did not match a preset the picker would open on "Something else" for every new user.
    public static let all: [AgentPreset] = [
        AgentPreset(
            name: "Claude Code",
            executable: "claude",
            runCommand: #"claude -p "/meetings {meeting_id}""#,
            pasteCommand: "/meetings {meeting_id}"
        ),
        AgentPreset(
            name: "Codex",
            executable: "codex",
            runCommand: #"codex exec --skip-git-repo-check "/meetings {meeting_id}""#,
            pasteCommand: "$meetings {meeting_id}"
        ),
        AgentPreset(
            name: "Cursor Agent",
            executable: "cursor-agent",
            runCommand: #"cursor-agent -p "/meetings {meeting_id}""#,
            pasteCommand: "/meetings {meeting_id}"
        ),
        AgentPreset(
            name: "Gemini CLI",
            executable: "gemini",
            runCommand: #"gemini -p "/meetings {meeting_id}""#,
            pasteCommand: "/meetings {meeting_id}"
        ),
        AgentPreset(
            name: "opencode",
            executable: "opencode",
            runCommand: #"opencode run "/meetings {meeting_id}""#,
            pasteCommand: "/meetings {meeting_id}"
        ),
        AgentPreset(
            name: "omp",
            executable: "omp",
            runCommand: #"omp -p "/meetings {meeting_id}""#,
            pasteCommand: "/meetings {meeting_id}"
        ),
    ]

    /// The first preset whose executable resolves on the PATH a spawned agent actually gets, or nil
    /// when none of them is installed.
    ///
    /// The PATH matters more than it looks. Resolving against the app's *own* PATH would miss every
    /// agent on a Finder launch, which is the launch every real user does — that is the failure
    /// ``EnhancementRunner/searchPath(in:)`` exists to fix, and detection has to search the same
    /// widened PATH the run will use or it would offer a command that then cannot start.
    public static func detected(
        searchPath: String = EnhancementRunner.searchPath(in: ProcessInfo.processInfo.environment)
    ) -> AgentPreset? {
        all.first { AIVerify.executable($0.executable, searchPath: searchPath) != nil }
    }

    /// The preset a stored template came from, or nil — which the UI shows as "Something else".
    ///
    /// An exact match on the whole template, modulo surrounding whitespace. Anything looser would
    /// claim a user's hand-edited command as a preset and then quietly overwrite their edit the next
    /// time the picker was touched; "Something else" is the honest label for a command we did not
    /// write, and it is also the one that leaves it alone.
    public static func matching(runCommand: String) -> AgentPreset? {
        let wanted = runCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.runCommand == wanted }
    }
}
