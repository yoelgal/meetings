import Foundation
import Testing

@testable import MeetingsCore

/// Every case runs against a throwaway `home`, never the real one — this is code whose whole job is
/// writing into `~/.claude`.
@Suite struct SkillInstallTests {
    private func withHome<T>(_ body: (URL) throws -> T) rethrows -> T {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SkillInstallTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        return try body(home)
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func writesTheSkillIntoClaudeCode() throws {
        try withHome { home in
            let results = try SkillInstall.install(content: "# one", home: home)
            let claude = try #require(results.first { $0.tool == "Claude Code" })

            #expect(claude.outcome == .installed)
            #expect(claude.path == home.appendingPathComponent(".claude/skills/meetings/SKILL.md").path)
            #expect(read(URL(fileURLWithPath: claude.path)) == "# one")
            #expect(claude.backupPath == nil)
        }
    }

    /// The file is rewritten on update, and a stale copy never silently persists.
    @Test func overwritesAStaleCopyAndKeepsItAsABackup() throws {
        try withHome { home in
            _ = try SkillInstall.install(content: "# old", home: home)
            let results = try SkillInstall.install(content: "# new", home: home)
            let claude = try #require(results.first { $0.tool == "Claude Code" })

            #expect(claude.outcome == .replaced)
            #expect(read(URL(fileURLWithPath: claude.path)) == "# new")
            let backup = try #require(claude.backupPath)
            #expect(read(URL(fileURLWithPath: backup)) == "# old")
        }
    }

    /// A second run must not duplicate the file, append to it, or leave two skills side by side.
    @Test func runningTwiceLeavesOneFile() throws {
        try withHome { home in
            _ = try SkillInstall.install(content: "# one", home: home)
            _ = try SkillInstall.install(content: "# one", home: home)

            let directory = home.appendingPathComponent(".claude/skills/meetings")
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(contents == ["SKILL.md"])
            #expect(read(directory.appendingPathComponent("SKILL.md")) == "# one")
        }
    }

    /// The app calls this on every launch, so the common case has to cost a read and nothing else.
    @Test func identicalContentIsLeftAlone() throws {
        try withHome { home in
            _ = try SkillInstall.install(content: "# one", home: home)
            let file = home.appendingPathComponent(".claude/skills/meetings/SKILL.md")
            let before = try #require(try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)

            let results = try SkillInstall.install(content: "# one", home: home)
            #expect(results.first?.outcome == .unchanged)
            #expect(results.first?.backupPath == nil)

            let after = try #require(try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            #expect(before == after)
        }
    }

    /// A hand-edited file is still overwritten — but it is never lost.
    @Test func aHandEditIsBackedUpRatherThanRefused() throws {
        try withHome { home in
            _ = try SkillInstall.install(content: "# shipped", home: home)
            let file = home.appendingPathComponent(".claude/skills/meetings/SKILL.md")
            try "# mine, hand written".write(to: file, atomically: true, encoding: .utf8)

            let results = try SkillInstall.install(content: "# shipped", home: home)
            #expect(results.first?.outcome == .replaced)
            #expect(read(file) == "# shipped")
            #expect(read(home.appendingPathComponent(".claude/skills/meetings/SKILL.md.bak"))
                == "# mine, hand written")
        }
    }

    @Test func skipsAToolThatIsNotInstalled() throws {
        try withHome { home in
            let results = try SkillInstall.install(content: "# one", home: home)
            let opencode = try #require(results.first { $0.tool == "opencode" })

            #expect(opencode.outcome == .skipped)
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/opencode").path))
        }
    }

    @Test func writesToOpencodeWhenItsConfigDirectoryExists() throws {
        try withHome { home in
            let config = home.appendingPathComponent(".config/opencode", isDirectory: true)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

            let results = try SkillInstall.install(content: "# one", home: home)
            let opencode = try #require(results.first { $0.tool == "opencode" })

            #expect(opencode.outcome == .installed)
            #expect(opencode.path == config.appendingPathComponent("skill/meetings/SKILL.md").path)
            #expect(read(URL(fileURLWithPath: opencode.path)) == "# one")
        }
    }

    @Test func dryRunReportsThePlanAndWritesNothing() throws {
        try withHome { home in
            let results = try SkillInstall.install(content: "# one", home: home, dryRun: true)

            #expect(results.first?.outcome == .installed)
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        }
    }

    @Test func dryRunOverAnExistingFileLeavesItUntouched() throws {
        try withHome { home in
            _ = try SkillInstall.install(content: "# old", home: home)
            let results = try SkillInstall.install(content: "# new", home: home, dryRun: true)

            #expect(results.first?.outcome == .replaced)
            #expect(read(home.appendingPathComponent(".claude/skills/meetings/SKILL.md")) == "# old")
            #expect(!FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".claude/skills/meetings/SKILL.md.bak").path))
        }
    }

    /// `FileManager.homeDirectoryForCurrentUser` reads `getpwuid` and ignores `$HOME`, which would
    /// send an acceptance run into the operator's real `~/.claude`.
    @Test func homeDirectoryFollowsTheEnvironment() {
        let home = SkillInstall.homeDirectory()
        if let env = ProcessInfo.processInfo.environment["HOME"] {
            #expect(home.path == (env as NSString).expandingTildeInPath)
        } else {
            #expect(home == FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    /// The default content is the bundled asset, and it resolves through `BundleResources` so the
    /// same call works from inside `Meetings.app`.
    @Test func defaultsToTheBundledSkill() throws {
        try withHome { home in
            _ = try SkillInstall.install(home: home)
            let written = read(home.appendingPathComponent(".claude/skills/meetings/SKILL.md"))
            #expect(written == (try BundleResources.skillMarkdown()))
        }
    }
}
