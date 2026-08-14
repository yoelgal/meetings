import ArgumentParser
import Foundation
import MeetingsCore

/// The settings table. Small, string-valued, and deliberately closed: an unrecognised key
/// is a typo far more often than it is a new feature.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and write settings.",
        discussion: """
            An API key never lives here. A *.keyRef setting holds the Keychain account name the \
            secret is stored under; the secret itself goes in the Keychain, from the app's Settings.

            meetings config set <key> with no value restores that key's default.
            """,
        subcommands: [ConfigGet.self, ConfigSet.self],
        defaultSubcommand: ConfigGet.self
    )
}

struct ConfigGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print one setting, or all of them."
    )

    @Argument(help: "The setting key. Left off, every known key is printed.")
    var key: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let stored = try context.store.storedSettings()
            let keys = try key.map { [try ConfigKeys.known($0)] } ?? ConfigKeys.all

            let entries = try keys.map { key in
                ConfigEntryJSON(
                    key: key.rawValue,
                    // The effective value: what is stored, else the documented default. Defaults are
                    // never written into the table, so `set` is the only thing that fills `stored`.
                    value: try ConfigKeys.effectiveValue(key, in: context.store),
                    isDefault: stored[key.rawValue] == nil,
                    keychainAccount: key.isKeyReference
                )
            }

            if global.json {
                // One key asked for, one object back: an agent doing `config get ai.mode --json`
                // should not have to index into a list to read one string.
                if key != nil, let entry = entries.first {
                    try Out.json(entry)
                } else {
                    try Out.json(ConfigListJSON(settings: entries))
                }
                return
            }
            if key != nil, let entry = entries.first {
                Out.line(entry.value ?? "")
                return
            }
            Out.line(Format.columns(entries.map { entry in
                [entry.key, entry.isDefault ? "(default)" : "(set)", entry.value ?? "-"]
            }).joined(separator: "\n"))
        }
    }
}

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Write a setting, or restore its default."
    )

    @Argument(help: "The setting key.")
    var key: String

    @Argument(help: "The value. Left off, the key goes back to its default.")
    var value: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let setting = try ConfigKeys.known(key)
            let value = try value.map { try ConfigKeys.validate($0, for: setting) }
            let context = try CLIContext.open()
            // A nil value deletes the row, which restores the default rather than storing "".
            try context.store.setSetting(setting, value)

            let entry = ConfigEntryJSON(
                key: setting.rawValue,
                value: try ConfigKeys.effectiveValue(setting, in: context.store),
                isDefault: value == nil,
                keychainAccount: setting.isKeyReference
            )
            if global.json {
                try Out.json(entry)
                return
            }
            Out.line("\(entry.key) = \(entry.value ?? "-")\(entry.isDefault ? " (default)" : "")")
        }
    }
}

extension SettingKey {
    /// The floating notes panel's two rows, spelled exactly as `Sources/MeetingsApp/NotesPanel.swift`
    /// spells them — the app writes these keys, so a second spelling here would be a second setting.
    ///
    /// They are declared in the app module, which MeetingsCore cannot see, so they cannot be in
    /// `SettingKey.known`. They are still ordinary rows in the same `settings` table, and the
    /// panel's own design note calls each one "a visible, named setting", so the CLI reads and
    /// writes them like every other setting rather than leaving them reachable only from a window.
    static let notesPanelHiddenFromCapture = SettingKey("panel.hideFromScreenSharing")
    static let notesPanelFloats = SettingKey("panel.keepAboveOtherApps")
}

enum ConfigKeys {
    /// Every key `meetings config` will read or write, in the order it prints them.
    static let all: [SettingKey] = SettingKey.known + [.notesPanelHiddenFromCapture, .notesPanelFloats]

    /// Defaults the CLI supplies because `SettingKey.defaults` cannot: an unset panel key has to
    /// read back as what the app actually does with it (`AppModel` — both on), or `config get` would
    /// report the panel as not hiding itself from screen sharing when it does.
    static let localDefaults: [SettingKey: String] = [
        .notesPanelHiddenFromCapture: "true",
        .notesPanelFloats: "true",
    ]

    /// What is stored, else the documented default.
    static func effectiveValue(_ key: SettingKey, in store: MeetingStore) throws -> String? {
        try store.setting(key) ?? localDefaults[key]
    }

    /// An unknown key is exit 64 with the list, never a silent write: a setting you thought you
    /// changed but did not is a bug you find weeks later, in the behaviour rather than in the error.
    static func known(_ raw: String) throws -> SettingKey {
        let key = SettingKey(raw)
        guard all.contains(key) else {
            throw CLIError.usage("""
                \(raw) is not a setting. Known keys:
                \(all.map(\.rawValue).joined(separator: "\n"))
                """)
        }
        return key
    }

    /// Values that have a shape are checked here rather than at the point somebody depends on them.
    /// A retention of "thirty" would otherwise read back as nil and quietly mean "keep forever".
    static func validate(_ value: String, for key: SettingKey) throws -> String {
        switch key {
        case .audioRetentionDays:
            guard let days = Int(value), days >= 0 else {
                throw CLIError.usage("audio.retentionDays is a number of days, or 0 to keep audio forever.")
            }
            return String(days)
        case .calendarLookAheadDays:
            // No zero here, unlike retention: a look-ahead of nothing is an Upcoming list that is
            // empty for a reason no surface explains, rather than a meaningful "keep forever".
            guard let days = Int(value), days >= 1 else {
                throw CLIError.usage("calendar.lookAheadDays is a number of days, one or more.")
            }
            return String(days)
        case .aiMode:
            return try oneOf(value, ["manual", "localAgent", "cloud"], key: key)
        case .transcribeBatchEngine:
            return try oneOf(value, TranscriptionEngineChoice.allCases.map(\.rawValue), key: key)
        case .transcribeLocalModel:
            // Straight off the catalogue, so a tier added to `LocalTranscriptionOption.all` is
            // settable here the moment it exists and a retired one stops being settable.
            return try oneOf(value, LocalTranscriptionOption.all.map(\.id), key: key)
        case .exportMarkdownOnComplete, .onboardingCompleted,
             .notesPanelHiddenFromCapture, .notesPanelFloats:
            guard let flag = boolean(value) else {
                throw CLIError.usage("\(key.rawValue) is true or false.")
            }
            return flag ? "true" : "false"
        case .aiCloudBaseURL, .transcribeRemoteBaseURL:
            guard let url = URL(string: value), url.scheme == "https" || url.scheme == "http" else {
                throw CLIError.usage("\(key.rawValue) is an http or https base URL.")
            }
            return value
        default:
            guard !key.isKeyReference else { return try keychainAccount(value, key: key) }
            return value
        }
    }

    /// The API key never enters this table. The row holds the Keychain account name.
    ///
    /// ponytail: a prefix-and-length heuristic, not a secret detector — it catches the pasted
    /// `sk-…` and the 40-character blob, which is what people actually do here, and says what to
    /// type instead. If real keys ever stop looking like that, this stops helping; it never blocks
    /// a plausible account name.
    private static func keychainAccount(_ value: String, key: SettingKey) throws -> String {
        let looksLikeASecret = value.hasPrefix("sk-") || value.hasPrefix("sk_") || value.count >= 40
        guard !looksLikeASecret else {
            throw CLIError.usage("""
                \(key.rawValue) holds the Keychain account name the key is stored under, not the \
                key itself. Store the secret in the Keychain (service com.yoelgal.Meetings) from \
                the app's Settings, then set this to that account name, e.g. openai-personal.
                """)
        }
        return value
    }

    private static func oneOf(_ value: String, _ allowed: [String], key: SettingKey) throws -> String {
        guard let match = allowed.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            throw CLIError.usage("\(key.rawValue) is one of: \(allowed.joined(separator: ", ")).")
        }
        return match
    }

    private static func boolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "1": true
        case "false", "no", "0": false
        default: nil
        }
    }
}

struct ConfigEntryJSON: Encodable {
    let key: String
    let value: String?
    /// True when nothing is stored and this is the documented default. Defaults are never written
    /// into the table, so a later change to one reaches an existing install.
    let isDefault: Bool
    /// True when the value is a Keychain account name rather than the value itself.
    let keychainAccount: Bool
}

private struct ConfigListJSON: Encodable {
    let settings: [ConfigEntryJSON]
}
