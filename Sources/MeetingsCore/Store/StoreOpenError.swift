import Foundation
import GRDB

extension SettingKey {
    /// Stamped by ``MeetingsDatabase/repairOrphans(at:)``: when the store was last repaired on open
    /// and how many rows went. Absent in a store that has never been damaged.
    public static let storeLastRepair = SettingKey("store.lastRepair")
}

/// Why the store would not open, in the words of the person looking at it.
///
/// Every case here was reproduced against a real store before it was written. The rule for all of
/// them is the same: name the thing that is actually wrong, name what to do about it, and never
/// print the database's own contents while doing it — the raw GRDB error for a foreign-key
/// violation embeds the offending row, transcript text and all, and that string was going straight
/// onto the app's launch screen.
public enum StoreOpenError: Error, LocalizedError {
    /// `MEETINGS_HOME`/`MEETINGS_DB` name a relative path.
    case relativePath([String])
    /// The directory the store lives in cannot be created or is not a directory.
    case homeUnusable(path: String, reason: String)
    /// The volume is full. SQLite cannot open a database it cannot write a journal beside, so this
    /// fails reads too.
    case diskFull(path: String)
    /// Not a database, a torn one, or a page that no longer decodes.
    case damaged(path: String, detail: String, snapshot: URL?)
    /// Written by a build that knows migrations this one does not.
    case fromNewerBuild(path: String, unknown: [String])

    public var errorDescription: String? {
        switch self {
        case .relativePath(let keys):
            let names = keys.joined(separator: " and ")
            return """
                \(names) names a relative path. It resolves to a different store in every process \
                that reads it. Use an absolute path.
                """

        case .homeUnusable(let path, let reason):
            return "The store directory \(path) cannot be used: \(reason)"

        case .diskFull(let path):
            return """
                The volume holding \(path) is full. SQLite writes a journal beside the database \
                even to read it, so nothing can be opened until there is space. Free some and try \
                again. Nothing has been lost.
                """

        case .damaged(let path, let detail, let snapshot):
            return "The meeting store at \(path) is damaged (\(detail)). \(Self.recovery(path: path, snapshot: snapshot))"

        case .fromNewerBuild(let path, let unknown):
            return """
                The store at \(path) was written by a newer version of Meetings \
                (it has migration\(unknown.count == 1 ? "" : "s") \(unknown.sorted().joined(separator: ", ")), \
                which this build does not know). It has not been opened or changed. Install the \
                newer version again, or restore an older snapshot from the backups directory beside \
                the store.
                """
        }
    }

    /// The one paragraph that turns "your store is damaged" into something a person can do. The
    /// `-wal` and `-shm` removal is not optional and not decoration: SQLite has no way to tell that
    /// a leftover write-ahead log belongs to the *previous* database file, and will happily replay
    /// it over the snapshot you just restored.
    private static func recovery(path: String, snapshot: URL?) -> String {
        guard let snapshot else {
            return """
                Nothing has been changed. There are no automatic snapshots beside it. The newest \
                .meetingbundle export you have is the remaining copy.
                """
        }
        return """
            Nothing has been changed. The newest automatic snapshot is \(snapshot.lastPathComponent). \
            To restore it:
              mv "\(path)" "\(path).damaged"
              rm -f "\(path)-wal" "\(path)-shm"
              cp "\(snapshot.path)" "\(path)"
            """
    }

    // MARK: - Diagnosis

    /// Turns whatever SQLite said into one of the cases above, or gives up and hands the original
    /// error back. Only ever called on a failure, so a healthy open pays nothing for it.
    static func diagnose(_ error: Error, url: URL) -> Error {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()

        // A read-only volume or a directory somebody chmod'ed reports as a lock, a readonly
        // database, or nothing recognisable at all, depending on which write SQLite tried first.
        // Checking the permissions is the only way to name it.
        if manager.fileExists(atPath: directory.path), !manager.isWritableFile(atPath: directory.path) {
            return homeUnusable(
                path: directory.path,
                reason: """
                    it is not writable, and SQLite has to write a -wal and a -shm beside the \
                    database even to read it. Restore write permission there, or point \
                    MEETINGS_HOME at a directory you own
                    """
            )
        }
        for companion in [url.path, url.path + "-wal", url.path + "-shm"]
        where manager.fileExists(atPath: companion) && !manager.isWritableFile(atPath: companion) {
            return homeUnusable(path: companion, reason: "it is not writable, and SQLite has to write to it to open the store")
        }

        guard let db = error as? DatabaseError else { return error }
        // Never the raw one. GRDB's description for a constraint failure quotes the offending row in
        // full — `in [id:1 meeting_id:"…" text:"…"]` — which is how a store with one orphaned
        // segment came to print that segment's transcript at whoever opened the app. Reaching here
        // means the repair above did not clear it, so this is the last word on it.
        if db.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
            return damaged(
                path: url.path,
                detail: "a row points at another row that is gone, and it could not be repaired",
                snapshot: newestSnapshot(besides: url)
            )
        }
        switch db.resultCode {
        case .SQLITE_FULL:
            return diskFull(path: url.path)
        case .SQLITE_NOTADB, .SQLITE_CORRUPT:
            return damaged(path: url.path, detail: db.message ?? "\(db.resultCode)", snapshot: newestSnapshot(besides: url))
        case .SQLITE_CANTOPEN:
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return homeUnusable(path: url.path, reason: "there is a directory there, and the store has to be a file")
            }
            return error
        default:
            return error
        }
    }

    /// The backups directory lives beside the store rather than at `Paths.backupsRoot`, so a store
    /// reached through `MEETINGS_DB` points at its own snapshots and not at some other home's.
    static func newestSnapshot(besides url: URL) -> URL? {
        let directory = url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        return (try? StoreBackup.list(in: directory))?.first
    }
}
