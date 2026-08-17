import Foundation
import Testing

@testable import MeetingsCore

/// The PATH a spawned agent gets, and the reported bug that made it worth widening further.
///
/// The failure being defended against: the operator's `omp` was installed by `bun` into
/// `~/.bun/bin`, which is not in the hardcoded list, so Settings said "omp is not on the PATH
/// Meetings searches" about a binary that worked fine in a terminal. Nothing in this suite spawns
/// the machine's real login shell — the answer would then depend on the rc files of whoever runs the
/// tests, which is the opposite of a test.
@Suite struct SearchPathTests {
    /// The environment a GUI app launched from Finder actually gets. Four directories, and the
    /// user's agent CLI is in none of them.
    private let finderEnvironment = [
        "HOME": "/Users/tester",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    /// What the hardcoded list alone produces for ``finderEnvironment``, which is the behaviour that
    /// shipped before the shell was ever asked and is therefore the fallback every failure lands on.
    private let hardcodedOnly = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        + ":/Users/tester/.local/bin:/Users/tester/.claude/local:/Users/tester/bin"

    private func entries(_ path: String) -> [String] {
        path.split(separator: ":").map(String.init)
    }

    /// A shell that answers with `path`, wrapped in the markers exactly as the real one does.
    private func shell(saying path: String) -> LoginShellPath.Lookup {
        { "\(LoginShellPath.marker)\(path)\(LoginShellPath.marker)" }
    }

    // MARK: - The reported bug

    /// The reported failure, in one assertion: a directory only the shell knows about ends up on the
    /// PATH a verify searches.
    @Test func theShellsOwnDirectoriesAreSearched() {
        let path = EnhancementRunner.searchPath(
            in: finderEnvironment,
            shellLookup: shell(saying: "/Users/tester/.bun/bin:/usr/bin")
        )
        #expect(entries(path).contains("/Users/tester/.bun/bin"))
    }

    /// And the hardcoded list is why it had to be asked for: `~/.bun/bin` is not in it, so no amount
    /// of the old behaviour would ever have found `omp`.
    @Test func theHardcodedListAloneWouldNotHaveFoundIt() {
        #expect(!entries(hardcodedOnly).contains("/Users/tester/.bun/bin"))
    }

    // MARK: - Falling back

    /// Every way the shell can refuse to answer collapses to the same behaviour: the PATH that
    /// shipped before it was ever asked. A widening step that could break the write-up path would be
    /// a worse bug than the one it fixes.
    @Test(arguments: [
        LoginShellPath.Failure.timedOut,
        LoginShellPath.Failure.exited(1),
        LoginShellPath.Failure.noOutput,
    ])
    func aShellThatWillNotAnswerLeavesTheHardcodedList(failure: LoginShellPath.Failure) {
        let path = EnhancementRunner.searchPath(in: finderEnvironment) { throw failure }
        #expect(path == hardcodedOnly)
    }

    /// Empty output and truncated output are both "no answer". A shell terminated at the deadline
    /// can easily have printed the opening marker and nothing after it, and half a PATH resolves the
    /// wrong binary.
    @Test(arguments: ["", "__MEETINGS_PATH__", "a banner with no markers at all", "__MEETINGS_PATH____MEETINGS_PATH__"])
    func unusableOutputLeavesTheHardcodedList(raw: String) {
        let path = EnhancementRunner.searchPath(in: finderEnvironment) { raw }
        #expect(path == hardcodedOnly)
    }

    // MARK: - Order and duplicates

    /// Order is a precedence decision, not formatting: `/usr/bin/env` launches the first match. The
    /// PATH this process inherited keeps its own order and stays in front, because a user who
    /// launched the app from a shell that puts a wrapper ahead of the real binary meant the wrapper.
    @Test func theInheritedPathKeepsItsPrecedence() throws {
        let path = EnhancementRunner.searchPath(
            in: ["HOME": "/Users/tester", "PATH": "/Users/tester/wrappers:/usr/bin"],
            shellLookup: shell(saying: "/opt/homebrew/bin:/usr/bin")
        )
        let list = entries(path)
        #expect(list.first == "/Users/tester/wrappers")
        let inherited = try #require(list.firstIndex(of: "/usr/bin"))
        let fromShell = try #require(list.firstIndex(of: "/opt/homebrew/bin"))
        #expect(inherited < fromShell, "a shell entry must not jump ahead of an inherited one")
    }

    /// The shell's PATH overlaps the hardcoded list on every normal Mac, and repeats itself on any
    /// Mac whose rc file is sourced twice. Without de-duplication the result is the same directory
    /// four times over — and this string is shown to the user.
    @Test func directoriesAppearOnce() {
        let path = EnhancementRunner.searchPath(
            in: ["HOME": "/Users/tester", "PATH": "/usr/bin:/opt/homebrew/bin"],
            shellLookup: shell(saying: "/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/bin")
        )
        let list = entries(path)
        #expect(list.count == Set(list).count)
        #expect(list.filter { $0 == "/opt/homebrew/bin" }.count == 1)
    }

    /// A directory the shell also reports must not move — de-duplication keeps the first appearance,
    /// so the union only ever appends.
    @Test func nothingTheShellSaysReordersWhatWasAlreadyThere() {
        let path = EnhancementRunner.searchPath(
            in: finderEnvironment,
            shellLookup: shell(saying: "/opt/homebrew/bin:/sbin")
        )
        #expect(path.hasPrefix("/usr/bin:/bin:/usr/sbin:/sbin:"))
    }

    /// The four-directory default is what a Finder launch inherits, and a process with no PATH at
    /// all has to be treated the same way rather than starting from nothing.
    @Test func anEnvironmentWithNoPathStillGetsTheDefaults() {
        let path = EnhancementRunner.searchPath(in: ["HOME": "/Users/tester"]) { throw LoginShellPath.Failure.timedOut }
        #expect(path == hardcodedOnly)
    }
}

/// The shell lookup itself, driven against throwaway scripts standing in for a login shell.
///
/// These *do* spawn a process, because what is worth proving here are the process rules: that a slow
/// rc file cannot hang the Settings window, that a broken one is not believed, and that a chatty one
/// does not corrupt the answer. None of them runs the operator's own shell.
@Suite struct LoginShellPathTests {
    private let directory: URL

    init() throws {
        directory = try TestStore.makeDirectory()
    }

    /// Writes an executable stand-in for a login shell and returns the environment naming it. It is
    /// handed `-ilc` and the script exactly as a real shell would be, so `"$2"` is the command.
    private func fakeShell(_ body: String) throws -> [String: String] {
        let path = directory.appendingPathComponent("fake-shell-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return ["SHELL": path.path, "HOME": directory.path]
    }

    /// The everyday case, and it pins two traps at once.
    ///
    /// The markers: an rc file is allowed to print a version-manager banner — and on a real Mac zsh's
    /// own shell integration prints OSC escape sequences before anything else — so the PATH has to be
    /// read out from between the markers rather than off the last line.
    ///
    /// The braces: this runs the shell against the *real* probe string, which is the only thing that
    /// catches `"$PATH\(marker)"` being parsed as one variable name because the marker begins with an
    /// underscore. That version returns the opening marker and nothing else, on every machine, and
    /// looks exactly like a shell that declined to answer.
    @Test func theAnswerSurvivesAChattyRcFile() throws {
        let environment = try fakeShell("""
            echo 'nvm: now using node v22'
            PATH=/opt/bun/bin:/usr/bin; export PATH
            exec /bin/sh -c "$2"
            """)
        let raw = try LoginShellPath.read(environment: environment)
        #expect(LoginShellPath.extract(raw) == "/opt/bun/bin:/usr/bin")
    }

    /// The bounded wait, which is the whole reason a verify button may call this at all. An rc file
    /// that queries git or initialises conda can take seconds; the window must not wait for it.
    @Test func aSlowRcFileHitsTheDeadlineRatherThanHanging() throws {
        let environment = try fakeShell("sleep 30")
        let started = Date()
        #expect(throws: LoginShellPath.Failure.timedOut) {
            try LoginShellPath.read(environment: environment, timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 5, "the deadline has to be the deadline")
    }

    /// A shell that failed is not believed even if it printed something first. A syntax error in an
    /// rc file can leave PATH half-built, and half a PATH resolves the wrong binary.
    @Test func aNonZeroExitIsNotBelieved() throws {
        let environment = try fakeShell("""
            printf '%s' "__MEETINGS_PATH__/opt/half/bin__MEETINGS_PATH__"
            exit 1
            """)
        #expect(throws: LoginShellPath.Failure.exited(1)) {
            try LoginShellPath.read(environment: environment)
        }
    }

    /// A shell that says nothing at all is a failure, not an empty PATH — an empty PATH would be
    /// indistinguishable from a successful answer of "nowhere", and would be believed.
    @Test func silenceIsAFailure() throws {
        let environment = try fakeShell("exit 0")
        #expect(throws: LoginShellPath.Failure.noOutput) {
            try LoginShellPath.read(environment: environment)
        }
    }

    /// A shell that is not there throws rather than trapping, so the caller falls back. This is the
    /// `SHELL` pointing at an uninstalled shell case, which a migrated home directory produces.
    @Test func aMissingShellIsJustAnEmptyAnswer() {
        let missing = ["SHELL": directory.appendingPathComponent("no-such-shell").path]
        #expect(LoginShellPath.entries { try LoginShellPath.read(environment: missing) }.isEmpty)
    }

    /// End to end through the widening: a real (fake) shell reports a directory the hardcoded list
    /// does not have, and it lands on the PATH.
    @Test func aRealShellsAnswerReachesTheSearchPath() throws {
        let environment = try fakeShell("""
            PATH=/opt/bun/bin; export PATH
            exec /bin/sh -c "$2"
            """)
        let path = EnhancementRunner.searchPath(in: environment) {
            try LoginShellPath.read(environment: environment)
        }
        #expect(path.split(separator: ":").contains("/opt/bun/bin"))
    }
}
