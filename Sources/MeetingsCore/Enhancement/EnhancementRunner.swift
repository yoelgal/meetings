import Foundation

/// Which of the three enhancement modes is armed.
///
/// `manual` is the default and fires nothing: the meeting reaches `ready` and waits for the user to
/// drive their own agent session. That is the mode the whole product is shaped around, and
/// the other two exist because some people want the trade the other way.
public enum AIMode: String, Sendable, CaseIterable, Identifiable {
    case manual, localAgent, cloud

    public var id: String { rawValue }

    /// The stored value, tolerant of anything a hand-edited settings row might hold. An
    /// unrecognised mode reads as `manual` — the mode that spends nothing and surprises nobody.
    public init(stored: String?) {
        self = AIMode(rawValue: stored ?? "") ?? .manual
    }
}

/// What one attempt at enhancing a meeting did.
public enum EnhancementResult: Sendable, Equatable {
    /// Nothing was attempted, on purpose: Mode A, or a write-up already in flight for this meeting.
    /// Nothing ran, nothing was spent, and there is nothing for the user to fix.
    case disabled(String)
    /// The meeting is not at `ready`. Enhancement fires on that transition and nowhere else.
    case notReady
    /// Mode B: the command was launched and exited. A non-zero `exitCode` is still a run — the agent
    /// was spawned and the user's subscription was spent, which the UI has to be able to say.
    case ran(Run)
    /// Mode C: the provider answered and the summary was written.
    ///
    /// Carries nothing, because a cloud call has nothing a ``Run`` describes: no argv, no exit
    /// status, no captured output. Inventing an exit code for it would put a number on screen that
    /// no process ever returned, and the write itself is the outcome the user is looking for.
    case wroteSummary
    /// The armed mode was tried and produced no write-up: the agent binary never started, the
    /// provider refused, or the mode is chosen but not configured. One sentence, already worded for
    /// a user, because this is displayed unattended when a meeting finishes.
    case failed(String)

    public struct Run: Sendable, Equatable {
        /// The argv actually executed, after substitution. Shown in full in Settings, which is the
        /// mitigation for "the command template is arbitrary shell execution".
        public let command: [String]
        public let exitCode: Int32
        /// The tail of the process's combined output, capped. Enough to explain a failure without
        /// holding a transcript's worth of agent chatter in memory.
        public let output: String
    }
}

/// The automatic write-up: on reaching `ready`, whichever mode is armed writes the meeting up.
///
/// Mode B spawns the user's own agent binary, handed nothing but `MEETINGS_DB` and the meeting id;
/// it reads the transcript and notes through the CLI and writes back with `meetings summary set`.
/// That is the whole contract, and it is why the app contains no prompt for that mode. Mode C sends
/// one request to the user's provider instead (``CloudEnhancer``), which is the only place in the
/// product a prompt exists.
///
/// **Off by default.** Both modes spend money or subscription usage without asking and run where you
/// cannot watch them, so nothing here happens unless `ai.mode` was changed from `manual`.
public actor EnhancementRunner {
    private let store: MeetingStore
    private let baseEnvironment: [String: String]
    /// How Mode C sends its request and reads its key. Injected so a test can drive the whole cloud
    /// write-up without a socket or the login Keychain — the alternative is a path that is only ever
    /// exercised against a real provider, which is to say never, which is how it came to be wired to
    /// nothing at all.
    private let transport: HTTPTransport
    private let keychain: @Sendable (String) -> String?
    /// One write-up per meeting at a time. `ready` can be reached twice in a session — a
    /// re-transcription after a correction — and two writers of the same summary race each other.
    private var running: Set<String> = []

    public init(store: MeetingStore) {
        self.init(store: store, environment: ProcessInfo.processInfo.environment)
    }

    /// Test seam. A test must never execute a real agent CLI, call a real provider, or read the
    /// login Keychain, so it supplies `/bin/echo` or a throwaway script as the template, a clean
    /// environment, and stand-ins for the other two.
    init(
        store: MeetingStore,
        environment: [String: String],
        transport: @escaping HTTPTransport = AIVerify.liveTransport,
        keychain: @escaping @Sendable (String) -> String? = MeetingsKeychain.secret(account:)
    ) {
        self.store = store
        self.baseEnvironment = environment
        self.transport = transport
        self.keychain = keychain
    }

    public var mode: AIMode {
        AIMode(stored: (try? store.setting(.aiMode)) ?? nil)
    }

    /// The command Mode B runs, as configured, falling back to the shipped default.
    ///
    /// `ai.localAgent.runCommand`, never `ai.manual.pasteCommand`: the latter is a slash command
    /// meant for a session that is already open, and exec'ing it would launch nothing.
    public var commandTemplate: String { Self.commandTemplate(in: store) }

    /// The same read, without an actor to await. `AIVerify` needs the template while a run may be
    /// in flight, and hopping onto this actor to read one settings row would make a verify button
    /// sit there for as long as an agent takes to write a summary.
    public static func commandTemplate(in store: MeetingStore) -> String {
        ((try? store.setting(.aiLocalAgentRunCommand)) ?? nil)
            ?? SettingKey.aiLocalAgentRunCommand.defaultValue
            ?? ""
    }

    /// The exact argv this meeting would run. Settings shows it, and the `ready` detail view copies
    /// it, so what is on screen is what would actually be executed.
    public func plannedCommand(meetingID: String) -> [String] {
        Self.command(template: commandTemplate, meetingID: meetingID)
    }

    /// Called when a meeting reaches `ready`. The one dispatch point: every mode's guards are these
    /// guards, and only the last step differs.
    ///
    /// The two checks are shared rather than repeated per mode because they are the same rule for
    /// each — a meeting that is not finished must not be written up, and two writers must not race
    /// the same summary. Mode C used to be excluded by a guard here that only let Mode B past, which
    /// is how a mode you could select, configure and verify came to do nothing at all.
    @discardableResult
    public func enhanceOnReady(meetingID: String) async -> EnhancementResult {
        guard let meeting = try? store.meeting(id: meetingID), meeting.state == .ready else {
            return .notReady
        }
        guard !running.contains(meetingID) else {
            return .disabled("a write-up is already running for this meeting")
        }
        running.insert(meetingID)
        defer { running.remove(meetingID) }

        switch mode {
        case .manual:
            return .disabled("AI mode is manual, so nothing runs when a meeting finishes")
        case .localAgent:
            return await runLocalAgent(meetingID: meetingID)
        case .cloud:
            return await runCloud(meetingID: meetingID)
        }
    }

    /// Mode B: spawn the user's own binary and let it write back through the CLI.
    private func runLocalAgent(meetingID: String) async -> EnhancementResult {
        let command = plannedCommand(meetingID: meetingID)
        guard !command.isEmpty else {
            return .failed("The command template is empty, so nothing ran.")
        }

        do {
            let run = try await Self.execute(command, environment: environment(for: meetingID))
            // The agent wrote through the CLI, which posts its own change notification — but a
            // template that writes some other way (a script, `sqlite3`) does not, and the window
            // that armed this is the one thing that has to notice either way.
            StoreChange.post(storePath: store.dbPool.path, meetingID: meetingID)
            return .ran(run)
        } catch {
            return .failed("The agent command could not start: \(AIVerify.sentence(for: error)).")
        }
    }

    /// Mode C: one request to the user's provider, which writes the summary itself.
    ///
    /// Nothing is retried and nothing is queued. This fires unattended when a meeting finishes, so a
    /// revoked key or a provider that is down would otherwise turn every finished meeting into a
    /// loop of billable calls nobody is watching. The sentence goes to the window instead, and the
    /// meeting stays at `ready` with its copyable command, which is the manual way out.
    ///
    /// No `StoreChange.post` here: the write goes through `store.updateMeeting`, which posts for
    /// itself. Posting again would be a second redraw of the same change.
    private func runCloud(meetingID: String) async -> EnhancementResult {
        let keyRef = (try? store.setting(.aiCloudKeyRef)) ?? nil
        let configuration: CloudEnhancer.Configuration
        switch AIVerify.cloudSetup(
            baseURL: (try? store.setting(.aiCloudBaseURL)) ?? nil,
            model: (try? store.setting(.aiCloudModel)) ?? nil,
            keyRef: keyRef,
            key: keyRef.flatMap(keychain)
        ) {
        case .missing(let sentence):
            // "You never finished setting this up" and "your provider said no" are different
            // problems with different fixes, so they are different sentences. Told only that the
            // write-up failed, a user has to open Settings to find out which one they have.
            return .failed("Cloud mode is not set up. \(sentence)")
        case .ready(let resolved):
            configuration = resolved
        }

        do {
            try await CloudEnhancer(configuration: configuration, transport: transport)
                .enhance(meetingID: meetingID, store: store)
            return .wroteSummary
        } catch {
            return .failed(AIVerify.cloudFailure(error, configuration: configuration))
        }
    }

    // MARK: - The command

    /// Tokenise first, substitute second.
    ///
    /// The default template embeds a quoted slash command — `claude -p "/meetings {id}"` — so
    /// the template genuinely needs shell-style quoting to split correctly. It does *not* need a
    /// shell: substituting after the split means a meeting id can never introduce a token boundary,
    /// a redirect or a second command, and the process is exec'd directly with no `sh -c` in the
    /// middle. An arbitrary user-authored template is accepted; that does not mean handing it
    /// interpolated data as well.
    static func command(template: String, meetingID: String) -> [String] {
        tokenize(template).map { $0.replacingOccurrences(of: "{meeting_id}", with: meetingID) }
    }

    /// Whitespace-separated, with `'…'` and `"…"` grouping and `\` escaping the next character.
    /// Deliberately not a shell parser: no expansion, no globbing, no substitution of anything but
    /// `{meeting_id}`, which the caller does afterwards.
    static func tokenize(_ template: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false

        for character in template {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                // A backslash inside single quotes is literal, exactly as a shell has it.
                escaped = true
                started = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { tokens.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { tokens.append(current) }
        return tokens
    }

    /// `MEETINGS_DB` is the contract with the spawned agent: it must open the same store
    /// this app has open, including under an acceptance run pointed at a throwaway directory.
    ///
    /// PATH is widened because a GUI app launched from Finder inherits `/usr/bin:/bin:/usr/sbin:
    /// /sbin` and nothing else, so `claude` — installed in `~/.local/bin` or Homebrew — is simply
    /// not found. That failure looks like "Mode B does nothing" and is miserable to diagnose.
    func environment(for meetingID: String) -> [String: String] {
        var environment = baseEnvironment
        environment["MEETINGS_DB"] = store.dbPool.path
        environment["MEETINGS_MEETING_ID"] = meetingID
        environment["PATH"] = Self.searchPath(in: environment)
        return environment
    }

    /// The PATH a spawned agent is actually launched with, and therefore the only PATH a verify may
    /// search. Checking the app's own PATH instead would report `claude` missing on exactly the
    /// Finder launch where the widening here is the thing that finds it.
    public static func searchPath(in environment: [String: String]) -> String {
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/bin",
        ]
        let existing = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init)
        return (existing + extra.filter { !existing.contains($0) }).joined(separator: ":")
    }

    /// Runs to completion and returns the exit code with the tail of its output.
    ///
    /// `/usr/bin/env` is the launcher so a bare `claude` resolves against the PATH above rather than
    /// needing an absolute path in the template. The blocking read happens on a global queue, not on
    /// the actor or the cooperative pool: an agent run is minutes long and would otherwise park a
    /// thread that the rest of the app needs.
    static func execute(
        _ command: [String],
        environment: [String: String],
        outputLimit: Int = 8_192
    ) async throws -> EnhancementResult.Run {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = command
                process.environment = environment
                // No stdin: an agent that decides to ask a question gets EOF and exits rather than
                // hanging forever on a terminal that is not there.
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()
                let text = String(decoding: data.suffix(outputLimit), as: UTF8.self)
                continuation.resume(returning: EnhancementResult.Run(
                    command: command,
                    exitCode: process.terminationStatus,
                    output: text.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }
}
