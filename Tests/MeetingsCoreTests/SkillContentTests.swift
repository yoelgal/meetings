import Foundation
import Testing

@testable import MeetingsCore

/// Seven things the bundled skill must contain. They are the difference between an
/// agent that writes notes onto the right meeting and one that guesses, so they are asserted rather
/// than trusted to survive the next edit of a 300-line markdown file.
@Suite struct SkillContentTests {
    private let skill = try! BundleResources.skillMarkdown()

    @Test func hasFrontmatterWithATriggerHeavyDescription() throws {
        #expect(skill.hasPrefix("---\n"))
        let frontmatter = try #require(skill.components(separatedBy: "\n---\n").first)
        #expect(frontmatter.contains("name: meetings"))
        #expect(frontmatter.contains("description:"))

        // Bare attendee names and the words a user actually says.
        for trigger in ["meeting", "call", "standup", "1:1", "sync", "catch-up", "Will"] {
            #expect(frontmatter.localizedCaseInsensitiveContains(trigger), "no trigger for \(trigger)")
        }
    }

    @Test func saysTheStoreIsGlobal() {
        #expect(skill.contains("global, not per-project"))
        #expect(skill.contains("from any working"))
    }

    /// Item 2: a write against a `cal:` ref materialises the row.
    @Test func explainsRefResolution() {
        #expect(skill.contains("cal:<eventIdentifier>"))
        #expect(skill.contains("materialises the row"))
    }

    /// Item 3, and the one to be most emphatic about.
    @Test func forbidsAutoPickingTheTopMatch() {
        #expect(skill.contains("never auto-pick the top `--match` result"))
    }

    /// Item 4: the three core workflows.
    @Test func carriesTheThreeCoreWorkflows() {
        #expect(skill.contains("## Workflow 1: notes before a meeting"))
        #expect(skill.contains("## Workflow 2: writing up after a meeting"))
        #expect(skill.contains("## Workflow 3: querying a past meeting"))
    }

    /// Item 5: the user's own notes steer the summary, and unaddressed pre-note points are reported.
    @Test func makesTheUsersNotesSteerTheSummary() {
        #expect(skill.contains("The user's own notes steer the summary"))
        #expect(skill.contains("Not covered"))
    }

    /// Item 6: over forty minutes is map-reduced, never loaded whole.
    @Test func carriesTheMapReducePathForLongMeetings() {
        #expect(skill.contains("Over 40 minutes, never read the transcript in"))
        #expect(skill.contains("--chunks"))
        #expect(skill.contains("--range"))
    }

    /// Item 7: the migration workflow, including that the CLI infers nothing.
    @Test func carriesTheMigrationWorkflow() {
        #expect(skill.contains("## Workflow 4: migrating a backlog"))
        #expect(skill.contains("meetings create"))
        #expect(skill.contains("infers **nothing**"))
    }

    /// Agents branch on exit codes, so all six are spelled out.
    @Test func documentsEveryExitCode() {
        for code in ["| 0 |", "| 1 |", "| 2 |", "| 3 |", "| 4 |", "| 64 |"] {
            #expect(skill.contains(code), "exit code row \(code) is missing")
        }
    }

    /// Every read command that exists today is documented. A skill that omits one sends the agent
    /// down the expensive path instead.
    @Test func documentsTodaysReadCommands() {
        for command in ["meetings status", "meetings list", "meetings show", "meetings transcript",
                        "meetings search", "meetings upcoming", "meetings skill install"] {
            #expect(skill.contains(command), "\(command) is not documented")
        }
    }
}
