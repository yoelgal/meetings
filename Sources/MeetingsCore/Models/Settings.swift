import Foundation

/// A key in the `settings` table. Not an enum, because `meetings config set <key> <value>` accepts
/// any string and an enum would make an unrecognised key unrepresentable rather than merely
/// undocumented.
///
/// API keys never live here. The row holds a Keychain account name (`*.keyRef`); the secret itself
/// is a `kSecClassGenericPassword` item under service `com.yoelgal.Meetings`.
public struct SettingKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let audioRetentionDays = SettingKey("audio.retentionDays")
    public static let aiMode = SettingKey("ai.mode")

    /// **Mode A, displayed.** The line the Needs-write-up card offers to copy, for pasting into an
    /// agent session you already have open. It is never executed, so a slash command belongs here.
    public static let aiManualPasteCommand = SettingKey("ai.manual.pasteCommand")

    /// **Mode B, executed.** Tokenised and exec'd by ``EnhancementRunner``, so `argv[0]` has to be a
    /// real binary on PATH. A slash command here would launch nothing.
    ///
    /// These two were one setting, `ai.commandTemplate`, and one value cannot do both jobs: the
    /// executable form (`claude -p …`) starts a *fresh headless run*, which is precisely what
    /// somebody pasting into their own session is avoiding, and the pasteable form (`/meetings …`)
    /// is not a path and execs nothing. They are named apart so they are not merged back together.
    /// A store carrying the old key is moved to this one by Schema's v4 migration.
    public static let aiLocalAgentRunCommand = SettingKey("ai.localAgent.runCommand")

    /// Retired by Schema's v4 migration. Declared only so the migration and its test can name it
    /// once; it is not in ``SettingKey/known`` and `meetings config` no longer accepts it.
    public static let legacyAICommandTemplate = SettingKey("ai.commandTemplate")

    public static let aiCloudBaseURL = SettingKey("ai.cloud.baseURL")
    public static let aiCloudModel = SettingKey("ai.cloud.model")
    public static let aiCloudKeyRef = SettingKey("ai.cloud.keyRef")
    /// Where transcription runs: `fluidaudio` (this Mac) or `remote` (an OpenAI-compatible
    /// endpoint). Read through ``MeetingStore/transcriptionEngine()``.
    public static let transcribeBatchEngine = SettingKey("transcribe.batchEngine")

    public static let transcribeRemoteBaseURL = SettingKey("transcribe.remote.baseURL")
    public static let transcribeRemoteModel = SettingKey("transcribe.remote.model")
    public static let transcribeRemoteKeyRef = SettingKey("transcribe.remote.keyRef")
    /// How far ahead Upcoming looks, in days. Both front ends read it through
    /// ``CalendarSync/lookAheadDays(in:)``, so the window and `meetings upcoming` cannot disagree
    /// about what "coming up" means — and it decides which events get a store row, so a person who
    /// widens it is also asking for rows further out.
    public static let calendarLookAheadDays = SettingKey("calendar.lookAheadDays")
    public static let exportMarkdownOnComplete = SettingKey("export.markdownOnComplete")
    public static let exportMarkdownRoot = SettingKey("export.markdownRoot")
    public static let onboardingCompleted = SettingKey("onboarding.completed")

    /// Whether the app may ask GitHub, once a day, if there is a newer release.
    ///
    /// The only request Meetings makes that the user did not ask for by configuring a cloud mode, so
    /// it is a setting rather than a constant, and the README says it exists. It sends nothing about
    /// you: a `GET` of a public release feed, no account, no identifier, no meeting data.
    public static let updateCheckEnabled = SettingKey("update.checkEnabled")

    /// Unix seconds of the last attempt, successful or not. Bookkeeping for the once-a-day rule, so
    /// it is not in ``SettingKey/known`` — there is nothing here for a person to set.
    public static let updateLastCheckedAt = SettingKey("update.lastCheckedAt")

    /// A key absent from this table has no default and reads as nil.
    public static let defaults: [SettingKey: String] = [
        .audioRetentionDays: "30",
        .aiMode: "manual",
        // The skill installs at skills/meetings, so the slash command is `/meetings`. It used to
        // read `/meeting-notes`, carried over from an older project, which matched nothing in any
        // agent — the copy button handed out a command that could only fail.
        .aiManualPasteCommand: "/meetings {meeting_id}",
        .aiLocalAgentRunCommand: #"claude -p "/meetings {meeting_id}""#,
        .transcribeBatchEngine: "fluidaudio",
        // No `transcribe.localModel` row: which local model runs is derived from this Mac's
        // language on every read (``LocalTranscriber/current``) rather than stored, so an install
        // cannot end up pinned to a model this build no longer ships, and no surface has to decide
        // what an unrecognised value means.
        //
        // Two weeks, not one. A week ahead is shorter than the notice most meetings are booked
        // with, so the list somebody opens on Monday to see what is coming routinely did not
        // contain the thing they opened it for.
        .calendarLookAheadDays: "14",
        .exportMarkdownOnComplete: "false",
        .onboardingCompleted: "false",
        // On, because an update notice nobody switches on protects nobody, and the check reveals
        // nothing about you. Settings › General turns it off and the README says it is here.
        .updateCheckEnabled: "true",
    ]

    public var defaultValue: String? { Self.defaults[self] }

    /// The two rows that decide where this Mac's own content goes: meeting audio
    /// (``transcribeRemoteBaseURL``) and the transcript a write-up is generated from
    /// (``aiCloudBaseURL``).
    public static let egressURLs: Set<SettingKey> = [.aiCloudBaseURL, .transcribeRemoteBaseURL]

    /// Why `value` must not be stored on `key`, or nil when it may be. **`https`, or a loopback
    /// host.** Every other key takes anything.
    ///
    /// `http` used to be accepted, which made one unprompted write enough to send every future
    /// meeting's audio somewhere in the clear — and `SKILL.md` hands an agent the `meetings config`
    /// surface while telling it to read transcripts, which are attacker-influenced content: anyone
    /// on the call, or an imported bundle, can write the sentence that asks for the redirect.
    /// Refusing cleartext does not stop a redirect, but it stops a silent one being readable by
    /// anything between here and the endpoint.
    ///
    /// Loopback keeps its `http`: a self-hosted whisper.cpp or Ollama on `127.0.0.1` is exactly the
    /// configuration this app is *for*, it never leaves the machine, and it has no certificate to
    /// present.
    ///
    /// **Here rather than in the CLI, because both front ends write these rows.** It lived in
    /// `meetings config set`, so the Settings window went on accepting on every keystroke what the
    /// command line refused — a rule one of two doors enforces is a detour, not a rule.
    ///
    /// ponytail: a scheme check, not an egress policy, and it is a *write* gate — a value already in
    /// the table is still read and used, by design, because an app that refused to run over a row it
    /// once accepted would strand somebody mid-meeting. Settings says so where the value is shown.
    public static func egressRefusal(_ value: String, for key: SettingKey) -> String? {
        guard egressURLs.contains(key) else { return nil }
        let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
           scheme == "https" || (scheme == "http" && loopback.contains(url.host()?.lowercased() ?? "")) {
            return nil
        }
        return """
            \(key.rawValue) is an https base URL. This is where \
            \(key == .transcribeRemoteBaseURL ? "the audio of every meeting" : "your transcripts") \
            gets sent, and http sends it in the clear. Only a loopback endpoint you are running \
            yourself (http://localhost:… or http://127.0.0.1:…) may use http.
            """
    }
}
