import Foundation

/// Writes the bundled agent skill into the agent tools installed on this Mac.
///
/// One entry point for both callers: `meetings skill install` and the app, which runs it at launch
/// so a skill file never goes stale behind an app update. The app path is the reason `install` is
/// content-addressed rather than unconditional — it reads a few kilobytes, compares, and returns
/// `.unchanged` without touching the disk on every launch but the first after an update.
///
/// **Overwrite policy: always overwrite, back up first if the file on disk is not what we shipped.**
/// A stale copy must never silently persist, so refusing to
/// write is not an option — a refusal is exactly the silent stale copy the criterion forbids. And a
/// `--force` flag only earns its place if something can refuse; nothing here does. Hand edits are
/// not lost either: anything that differs from the current content is copied to `SKILL.md.bak`
/// beside it and named in the output, which costs one file and no decisions.
public enum SkillInstall {
    /// One tool's skill directory.
    public struct Target: Sendable {
        /// How the tool is named in the output the user reads.
        public let tool: String
        /// `…/skills/meetings`, created on demand.
        public let directory: URL
        /// A directory that must already exist for this target to apply. Never create a tool's
        /// config root: its presence is how we know the user has that tool at all, and inventing
        /// `~/.config/opencode` on a Mac with no opencode is litter.
        public let requires: URL?

        public var fileURL: URL { directory.appendingPathComponent("SKILL.md") }
        public var backupURL: URL { directory.appendingPathComponent("SKILL.md.bak") }
    }

    public enum Outcome: String, Sendable, Codable {
        /// Nothing was there before.
        case installed
        /// Something was there and differed; it was backed up and overwritten.
        case replaced
        /// Byte-identical to what we ship. Nothing written.
        case unchanged
        /// The tool is not installed on this Mac.
        case skipped
    }

    public struct Result: Sendable, Codable {
        public let tool: String
        public let path: String
        public let outcome: Outcome
        public let backupPath: String?
        /// A human sentence for the cases where the outcome alone does not explain itself.
        public let note: String?
    }

    /// `$HOME` wins over `getpwuid`, which is what `FileManager.homeDirectoryForCurrentUser` reads.
    /// Without this an acceptance run with a throwaway `HOME` would still write into the real
    /// `~/.claude`, and the first thing this code does is write into a directory full of the user's
    /// own configuration.
    public static func homeDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Claude Code is unconditional — it is the tool the skill is written for, and `~/.claude` is
    /// created on demand rather than gated, so `meetings skill install` works before the user has
    /// ever installed a skill. Everything else is gated on already being there.
    public static func targets(home: URL = homeDirectory()) -> [Target] {
        let opencode = home.appendingPathComponent(".config/opencode", isDirectory: true)
        return [
            Target(
                tool: "Claude Code",
                directory: home.appendingPathComponent(".claude/skills/meetings", isDirectory: true),
                requires: nil
            ),
            Target(
                tool: "opencode",
                directory: opencode.appendingPathComponent("skill/meetings", isDirectory: true),
                requires: opencode
            ),
        ]
    }

    /// Installs the bundled `SKILL.md` into every applicable target.
    ///
    /// - Parameters:
    ///   - content: the markdown to write. Defaults to the bundled asset, read through
    ///     ``BundleResources`` because `Bundle.module` does not resolve inside `Meetings.app`.
    ///   - dryRun: work out and report the same plan, write nothing.
    @discardableResult
    public static func install(
        content: String? = nil,
        home: URL = homeDirectory(),
        dryRun: Bool = false,
        fileManager: FileManager = .default
    ) throws -> [Result] {
        let markdown = try content ?? BundleResources.skillMarkdown()
        return try targets(home: home).map { target in
            try apply(markdown, to: target, dryRun: dryRun, fileManager: fileManager)
        }
    }

    private static func apply(
        _ markdown: String,
        to target: Target,
        dryRun: Bool,
        fileManager: FileManager
    ) throws -> Result {
        if let requires = target.requires, !fileManager.fileExists(atPath: requires.path) {
            return Result(
                tool: target.tool,
                path: target.fileURL.path,
                outcome: .skipped,
                backupPath: nil,
                note: "\(requires.path) is not on this Mac"
            )
        }

        let existed = fileManager.fileExists(atPath: target.fileURL.path)
        // An unreadable file counts as different: it is certainly not what we shipped, and the
        // backup-then-overwrite path is the right answer for it too.
        let existing = existed ? try? String(contentsOf: target.fileURL, encoding: .utf8) : nil
        if existing == markdown {
            return Result(
                tool: target.tool, path: target.fileURL.path,
                outcome: .unchanged, backupPath: nil, note: nil
            )
        }

        let backup = existed ? target.backupURL : nil
        if !dryRun {
            try fileManager.createDirectory(at: target.directory, withIntermediateDirectories: true)
            if let backup {
                try? fileManager.removeItem(at: backup)
                try fileManager.copyItem(at: target.fileURL, to: backup)
            }
            try markdown.write(to: target.fileURL, atomically: true, encoding: .utf8)
        }

        return Result(
            tool: target.tool,
            path: target.fileURL.path,
            outcome: existed ? .replaced : .installed,
            backupPath: backup?.path,
            note: existed ? "the copy that was there differed from this version" : nil
        )
    }
}
