import Foundation

/// Every file the app touches resolves through here. Two processes — the app and the CLI — have to
/// agree on one store, and acceptance runs have to be able to point the whole thing at a throwaway
/// directory, so no path is ever written literally anywhere else.
public enum Paths {
    /// `$MEETINGS_HOME`, else `~/Library/Application Support/Meetings`.
    public static var root: URL {
        if let override = env("MEETINGS_HOME") {
            return URL(fileURLWithPath: expand(override), isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Meetings", isDirectory: true)
    }

    /// `$MEETINGS_DB`, else `<root>/store.db`. The app exports this to the Mode-B agent process so a
    /// spawned agent reads the same store the app is looking at.
    public static var databaseURL: URL {
        if let override = env("MEETINGS_DB") {
            return URL(fileURLWithPath: expand(override))
        }
        return root.appendingPathComponent("store.db")
    }

    public static var audioRoot: URL { root.appendingPathComponent("audio", isDirectory: true) }

    public static func audioDirectory(meetingID: String) -> URL {
        audioRoot.appendingPathComponent(meetingID, isDirectory: true)
    }

    public static var backupsRoot: URL { root.appendingPathComponent("backups", isDirectory: true) }

    /// Where the one-way markdown export lands. `$MEETINGS_MD_ROOT`, else `~/Meetings`.
    public static var markdownRoot: URL {
        if let override = env("MEETINGS_MD_ROOT") {
            return URL(fileURLWithPath: expand(override), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    /// Fixture calendar, set only by acceptance runs. Absent in normal operation, which is when the
    /// real EventKit source is used.
    public static var calendarFixtureURL: URL? {
        env("MEETINGS_CALENDAR_FIXTURE").map { URL(fileURLWithPath: expand($0)) }
    }

    /// The store-path overrides that name a relative path, if any.
    ///
    /// `URL(fileURLWithPath:)` resolves a relative path against the process's working directory,
    /// and the app's is `/` while a shell's is wherever you happen to be standing. So
    /// `MEETINGS_HOME=meetings` is not one store: it is a different store for every directory the
    /// CLI is run from, and a third one for the app — each of them created on the spot and each
    /// looking healthy. ``MeetingsDatabase/open(at:)`` refuses rather than silently forking.
    ///
    /// `MEETINGS_MD_ROOT` is not checked: it is an output directory, and a relative one lands
    /// somewhere visible rather than splitting the data in two.
    static var relativeOverrides: [String] {
        ["MEETINGS_HOME", "MEETINGS_DB"].filter { key in
            guard let value = env(key) else { return false }
            return !expand(value).hasPrefix("/")
        }
    }

    /// Create the directory tree the store and recorder assume exists.
    public static func ensureDirectories() throws {
        for url in [root, audioRoot, backupsRoot] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: -

    private static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    private static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
