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
        .calendarLookAheadDays: "7",
        .exportMarkdownOnComplete: "false",
        .onboardingCompleted: "false",
        // On, because an update notice nobody switches on protects nobody, and the check reveals
        // nothing about you. Settings › General turns it off and the README says it is here.
        .updateCheckEnabled: "true",
    ]

    public var defaultValue: String? { Self.defaults[self] }
}
