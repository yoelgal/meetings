import Foundation
import GRDB

/// `VACUUM INTO` a dated snapshot, seven kept, oldest pruned.
///
/// This is **corruption protection and nothing else**, and it is deliberately not the same
/// mechanism as ``MeetingBundle``: a snapshot is a whole store on this disk, so it survives a bad
/// write and does not survive the disk. Bundles are the machine-loss answer. Keeping the two
/// apart is deliberate, and so is this file.
///
/// `VACUUM INTO` rather than a file copy: a copy of a WAL-mode database taken while another process
/// is mid-transaction is a torn file, and copying `store.db` without `store.db-wal` loses every
/// committed write still sitting in the log. SQLite writes a consistent, already-checkpointed
/// snapshot for us.
public enum StoreBackup {
    /// Seven kept, literally.
    public static let keep = 7

    /// Writes a snapshot and prunes the directory it wrote into. Returns the snapshot.
    ///
    /// `url` defaults to `<root>/backups/store-<yyyy-MM-dd-HHmmss>.db`.
    @discardableResult
    public static func run(
        store: MeetingStore,
        to url: URL? = nil,
        keeping: Int = keep,
        now: Date = Date()
    ) throws -> URL {
        let destination = url ?? Paths.backupsRoot.appendingPathComponent(filename(now))
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // VACUUM INTO refuses to overwrite, which is the behaviour you want for a backup — except
        // when the caller named the path themselves and meant it.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        // Outside a transaction: VACUUM cannot run inside one.
        do {
            try store.dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [destination.path])
            }
        } catch {
            // A VACUUM that runs out of disk leaves the file it had started behind, and a
            // zero-byte `store-<date>.db` is a snapshot as far as ``list(in:)`` is concerned: it
            // sorts newest, so it becomes the file a damaged store tells you to restore from, and
            // the next prune drops a real snapshot to make room for it.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // Only the backups directory is pruned. A `--out` the user named is their directory, and
        // deleting files out of it because they happen to match `store-*.db` would be a surprise
        // with no undo.
        if url == nil {
            try prune(in: destination.deletingLastPathComponent(), keeping: keeping)
        }
        return destination
    }

    /// The launch-time sweep ("runs on launch"). Never throws: a machine with a full disk
    /// should still open its meetings. Returns the snapshot, or nil with the reason logged nowhere
    /// noisier than the return value.
    @discardableResult
    public static func runOnLaunch(store: MeetingStore) -> URL? {
        do {
            return try run(store: store)
        } catch {
            // Not fatal, but not silent either: "the disk was full so I stopped taking snapshots"
            // is exactly the sentence you want to have seen, six weeks before you need one.
            FileHandle.standardError.write(Data(
                "Meetings: could not snapshot the store: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }

    /// Deletes all but the newest `keeping` snapshots and returns what is left, newest first.
    ///
    /// Ordered by the timestamp in the filename, not by mtime: a restore, an rsync or a Time Machine
    /// round trip rewrites mtimes, and pruning by mtime would then delete the wrong week.
    @discardableResult
    public static func prune(in directory: URL, keeping: Int = keep) throws -> [URL] {
        let snapshots = try list(in: directory)
        for old in snapshots.dropFirst(max(0, keeping)) {
            try FileManager.default.removeItem(at: old)
            // Opening a snapshot to read it — which is the whole point of having one — leaves a
            // WAL, a shared-memory file and GRDB's lock beside it. Deleting the database and
            // leaving those behind turns the backups directory into a junk drawer.
            for suffix in ["-wal", "-shm", ".lock"] {
                let companion = URL(fileURLWithPath: old.path + suffix)
                if FileManager.default.fileExists(atPath: companion.path) {
                    try? FileManager.default.removeItem(at: companion)
                }
            }
        }
        return Array(snapshots.prefix(max(0, keeping)))
    }

    /// Snapshots in `directory`, newest first.
    ///
    /// Empty files are not snapshots. A VACUUM killed part-way — the process, or the disk running
    /// out underneath it — leaves one, and it would otherwise sort to the front and be offered as
    /// the newest thing to restore from.
    // ponytail: size is the whole check. Proving a snapshot is intact means opening it, and the
    // only caller that would act on the answer is a message telling a human which file to copy.
    public static func list(in directory: URL = Paths.backupsRoot) throws -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("store-") && $0.pathExtension == "db" }
            .filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func filename(_ date: Date) -> String {
        "store-\(stamp.string(from: date)).db"
    }

    /// Sortable as a string, which is what makes ``prune(in:keeping:)`` a `sorted()` and not a date
    /// parse.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
