import Foundation

/// The PATH the user's own login shell has, read once per process.
///
/// This exists because of a reported failure with no good local fix. A GUI app launched from Finder
/// inherits `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else, so ``EnhancementRunner/searchPath(in:)``
/// has always widened it with a hardcoded list of the usual suspects — Homebrew, `~/.local/bin`,
/// `~/bin`. The operator's agent binary was `omp`, installed by `bun`, which puts its shims in
/// `~/.bun/bin`; Settings therefore reported "omp is not on the PATH Meetings searches" for a
/// binary that plainly worked in a terminal. Every agent CLI ships through a different package
/// manager — bun, npm, pipx, cargo, Homebrew, a vendor install script — so lengthening the
/// hardcoded list is a treadmill: the next agent installs somewhere new and the same bug is
/// reported again.
///
/// What all of those installers *do* have in common is that they append their directory to the
/// login shell's rc file. So the general fix is to ask the shell. Running `$SHELL -ilc` as a
/// login **and** interactive shell is what sources both `.zprofile`/`.zshenv` and `.zshrc`, which is
/// where the two halves of a real PATH end up; a login-only shell misses the `.zshrc` exports that
/// bun and nvm write, and an interactive-only shell misses the profile ones.
///
/// Three deliberate pieces of paranoia, because this runs a user-authored script inside a GUI app:
///
/// - **A marker, not the last line.** An rc file is allowed to be chatty — version-manager
///   banners, `fortune`, a motd — and that output is interleaved with ours on the same stream. The
///   PATH is printed wrapped in ``marker`` and read back out from between the two occurrences, so
///   the answer survives any amount of noise before or after it.
/// - **A temporary file, not a pipe.** A pipe's buffer is finite: an rc file that prints more than
///   the buffer holds would block on write while we block on `waitUntilExit`, and the two would sit
///   there forever. A file cannot fill up in a way that stalls the writer.
/// - **A deadline.** rc files do real work — they query git, poke at the network, initialise
///   conda. This is called from a verify button, so an unbounded wait is a hung Settings window.
///   Past the deadline the shell is terminated and the caller falls back to the hardcoded list,
///   which is exactly the behaviour that shipped before this file existed.
enum LoginShellPath {
    /// How the PATH text is obtained. A closure so tests can exercise every branch of the parsing
    /// and the fallback without spawning a shell, and — more to the point — without the result
    /// depending on whatever the machine running the tests happens to have in its rc files.
    typealias Lookup = () throws -> String

    /// Wraps the printed PATH so it can be found among an rc file's own output.
    ///
    /// Contains no character a shell treats specially, so it can be interpolated into the script
    /// below without any quoting question to get wrong.
    static let marker = "__MEETINGS_PATH__"

    /// `Equatable` so a test can assert *which* refusal happened rather than only that one did.
    /// The three have different causes, and a change that turned a timeout into a silent empty read
    /// would otherwise pass.
    enum Failure: Error, Equatable, Sendable {
        /// The shell was still running at the deadline and has been terminated.
        case timedOut
        /// The shell exited non-zero: a syntax error in an rc file, most likely.
        case exited(Int32)
        /// The shell exited cleanly but nothing between the two markers came back, so there is
        /// nothing to trust.
        case noOutput
    }

    /// This process's answer, computed on first use and never again.
    ///
    /// A `static let` rather than a hand-rolled cache: Swift initialises one exactly once, under a
    /// lock, for every thread that asks. That matters here beyond tidiness — the alternative is
    /// spawning the user's shell once per verify button press and once per agent launch.
    ///
    /// Empty on any failure, which the caller reads as "use the hardcoded list".
    static let cached: [String] = Self.entries {
        try Self.read(environment: ProcessInfo.processInfo.environment)
    }

    /// The lookup's answer split into directories, or `[]` if it could not be trusted.
    ///
    /// Failure is absorbed rather than propagated on purpose. Every caller's response to a shell
    /// that would not answer is the same — carry on with the hardcoded list — and a widening step
    /// that can fail the whole write-up path would be a worse bug than the one this fixes.
    static func entries(using lookup: Lookup) -> [String] {
        guard let raw = try? lookup(), let path = extract(raw) else { return [] }
        return path.split(separator: ":").map(String.init)
    }

    /// Pulls the PATH out from between the two markers.
    ///
    /// Returns nil for anything that is not a complete, non-empty wrapped value: a shell killed at
    /// the deadline can easily have printed the opening marker and nothing else, and half a PATH is
    /// not better than none.
    static func extract(_ raw: String) -> String? {
        guard let opening = raw.range(of: marker),
              let closing = raw.range(of: marker, range: opening.upperBound..<raw.endIndex)
        else { return nil }
        let path = raw[opening.upperBound..<closing.lowerBound]
        return path.isEmpty ? nil : String(path)
    }

    /// Runs the login shell and reads its PATH back, or throws before `timeout` elapses.
    ///
    /// `SHELL` is the shell the user actually chose, so it is the one whose rc files hold their
    /// PATH; `/bin/zsh` is the fallback because it is the macOS default login shell and has been
    /// since Catalina. No stdin — an interactive shell handed a terminal it does not have would
    /// otherwise be free to prompt and wait — and stderr is discarded, because an rc file
    /// complaining about a missing tty is not a failure of this lookup.
    ///
    /// **This parks the calling thread** for as long as the shell takes, up to `timeout`. That is
    /// affordable only because ``cached`` calls it at most once per process: a caller reaching this
    /// from a `Task.detached` parks one cooperative thread, once, for under two seconds, which is a
    /// cost the pool absorbs. It would not be affordable in a loop or on the main actor, and there
    /// is no async form of it because ``EnhancementRunner/searchPath(in:)`` is synchronous — the
    /// verify button and the environment a spawned agent gets both need an answer inline.
    static func read(environment: [String: String], timeout: TimeInterval = 2) throws -> String {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meetings-login-path-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Two details in this one line, both of which were wrong first time round:
        //
        // `${PATH}`, braced, and not `$PATH`. ``marker`` begins with an underscore, and an
        // underscore is a legal character in a shell variable name — so `"$PATH\(marker)"` asks the
        // shell for a variable called `PATH__MEETINGS_PATH__`, which does not exist. What comes back
        // is the opening marker, an empty expansion, and no closing marker: a lookup that reports
        // "the shell said nothing" on a machine where the shell said plenty. The braces end the name.
        //
        // `printf '%s'`, not `echo`: some echoes read a PATH entry beginning with `-` as a flag, and
        // `printf '%s'` appends no newline to trim back off.
        process.arguments = ["-ilc", "printf '%s' \"\(marker)${PATH}\(marker)\""]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice

        // Signalled from the termination handler rather than polling `isRunning`, so a shell that
        // answers in 20 ms costs 20 ms and not a poll interval.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            throw Failure.timedOut
        }
        guard process.terminationStatus == 0 else {
            throw Failure.exited(process.terminationStatus)
        }
        // Read after the writer exited, so what is on disk is all of it.
        guard let data = FileManager.default.contents(atPath: output.path), !data.isEmpty else {
            throw Failure.noOutput
        }
        return String(decoding: data, as: UTF8.self)
    }
}
