import Foundation
import GRDB

/// Opens the store. `DatabasePool` rather than `DatabaseQueue` because WAL is not optional here:
/// the app and the CLI are two processes on one file, and without WAL a `meetings summary set`
/// while the app is reading blocks or fails outright.
public enum MeetingsDatabase {
    /// Long enough that a normal short transaction in the other process always wins the wait, short
    /// enough that a genuinely stuck writer surfaces as an error rather than a hang.
    public static let busyTimeout: TimeInterval = 5

    /// How long ``serialisedAcrossProcesses(for:_:)`` waits for the other process to finish opening.
    ///
    /// Not ``busyTimeout``, and not the same kind of number. That one bounds a short transaction;
    /// this one bounds *another process's whole open* — a `VACUUM INTO` of the entire store followed
    /// by a migration that rewrites every write-up, which is work proportional to the store rather
    /// than to one statement. Two minutes is generous for that on a large store on a slow or
    /// contended disk, and short enough that a genuinely wedged process produces a sentence rather
    /// than a launch that never finishes.
    public static let lockWait: TimeInterval = 120

    /// Opens (creating if absent) the store at `url`, creating the directory tree on the way and
    /// applying every migration before returning. A caller never sees an unmigrated database.
    ///
    /// Serialised across processes, because opening a store for the *first* time is not a read: it
    /// switches the journal to WAL and then runs the migration, and neither survives a race. The app
    /// and the CLI both starting on a new machine — the app's launch handler and a shell alias in a
    /// login script, say — reliably produced one of two failures, measured 20/20 on this machine:
    ///
    ///   SQLite error 5: database is locked - while executing `PRAGMA journal_mode = WAL`
    ///   SQLite error 1: table folders already exists - while executing `CREATE TABLE folders …`
    ///
    /// The busy timeout covers neither. The journal-mode switch needs the whole database and reports
    /// a lock rather than waiting for one, and the migration failure is SQLITE_ERROR — both processes
    /// read an empty `grdb_migrations` before either wrote to it, so the loser is not busy, it is
    /// wrong. A lock outside SQLite is what makes "open the store" atomic between processes.
    public static func open(at url: URL = Paths.databaseURL) throws -> DatabasePool {
        let relative = Paths.relativeOverrides
        guard relative.isEmpty else { throw StoreOpenError.relativePath(relative) }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreOpenError.homeUnusable(path: directory.path, reason: reason(for: error, at: directory))
        }
        return try serialisedAcrossProcesses(for: url) {
            do {
                return try migrated(url)
            } catch {
                // An orphan row is the one kind of damage that is repairable *by definition* — see
                // ``Schema/orphanRepairs``. Everything else gets named, not guessed at.
                //
                // `try?`: a repair that cannot run — a read-only volume, a full disk — is not the
                // thing to report. `diagnose` reads the same filesystem and says what is actually
                // stopping it, and it never lets the original constraint error through verbatim.
                guard isForeignKeyViolation(error), ((try? repairOrphans(at: url)) ?? 0) > 0 else {
                    throw StoreOpenError.diagnose(error, url: url)
                }
                do { return try migrated(url) } catch { throw StoreOpenError.diagnose(error, url: url) }
            }
        }
    }

    /// A migrated pool, or a refusal.
    ///
    /// The refusal is the point: a store carrying migrations this build has never heard of was
    /// written by a newer version, and opening it read-write would let this build insert rows that
    /// ignore whatever that migration added. GRDB itself is happy to run an older migrator against
    /// a newer database — it only ever looks for migrations that are *missing* — so nothing else
    /// notices the downgrade.
    private static func migrated(_ url: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        let applied = try pool.read { try Schema.migrator.appliedIdentifiers($0) }
        let unknown = applied.subtracting(Schema.migrator.migrations)
        guard unknown.isEmpty else {
            throw StoreOpenError.fromNewerBuild(
                path: url.path, unknown: Array(unknown), snapshot: StoreOpenError.newestSnapshot(besides: url))
        }
        if !Set(Schema.migrator.migrations).subtracting(applied).isEmpty, !applied.isEmpty {
            snapshot(pool, beside: url)
        }
        try Schema.migrator.migrate(pool)
        return pool
    }

    /// A copy of the store as it is *now*, taken because the next line rewrites it and there is no
    /// undo.
    ///
    /// A migration is not a schema change here. `v6` overwrote every `summary` in the store —
    /// somebody's prose, edited in place — and nothing had taken a copy first: ``StoreBackup/run``
    /// was reachable only from `meetings backup`, which is a command run by hand, so a user who had
    /// never heard of it had an empty backups directory. That is the same directory
    /// ``StoreOpenError`` tells a locked-out user to restore from, which made the advice on the
    /// launch screen false for exactly the people reading it.
    ///
    /// It lands under the store's own `backups/`, with the same `store-<date>.db` name every other
    /// snapshot has, so it *is* "the newest automatic snapshot" that message names, and the seven-kept
    /// prune applies to it rather than one file accumulating per release forever.
    ///
    /// **Best-effort, and that is deliberate**: a full disk, a read-only volume or a backups directory
    /// somebody chmod'ed must not stop the store from opening. Skipped when nothing is applied yet —
    /// that is a database being created, and there is nothing in it to copy.
    ///
    /// Best-effort is not the same as silent, and it used to be: two bare `try?` and no log meant a
    /// full disk, a chmod'ed `backups/` or a `VACUUM INTO` that lost the busy timeout rewrote the
    /// store with no copy and no record, which is precisely the state that made
    /// ``StoreOpenError``'s "restore the newest automatic snapshot" a lie for the user it was
    /// written for. The upgrade still proceeds — a snapshot that cannot be taken must not lock
    /// somebody out of their meetings — but it says so.
    private static func snapshot(_ pool: DatabasePool, beside url: URL) {
        let directory = url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        // Pruned *before* the copy, keeping one fewer so the new one lands inside the seven. `run`
        // prunes only the directory it chose for itself and this one was named, so the prune was
        // ours to place — and after the copy it can never free the space the copy needed.
        _ = try? StoreBackup.prune(in: directory, keeping: StoreBackup.keep - 1)
        do {
            try StoreBackup.run(
                store: MeetingStore(dbPool: pool),
                to: directory.appendingPathComponent(StoreBackup.filename(Date()))
            )
        } catch {
            StoreBackup.report(error, store: url.path)
        }
    }

    private static func isForeignKeyViolation(_ error: Error) -> Bool {
        (error as? DatabaseError)?.resultCode == .SQLITE_CONSTRAINT
            && (error as? DatabaseError)?.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY
    }

    /// Applies each foreign key's own declared `ON DELETE` action to the rows whose parent has gone,
    /// and records that it did. Returns how many rows it touched.
    ///
    /// Foreign keys are on for every connection this app makes, so it cannot produce this state
    /// itself; a partial restore, a third-party SQLite tool or a bad sector can. Left alone it is
    /// fatal — GRDB's migrator runs `PRAGMA foreign_key_check`, the migration rolls back, and every
    /// launch from then on fails.
    ///
    /// Its own connection, with foreign keys off, because the repair is a delete of rows the
    /// constraint is currently rejecting.
    static func repairOrphans(at url: URL) throws -> Int {
        var config = Configuration()
        config.busyMode = .timeout(busyTimeout)
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return try queue.write { db in
            var repaired = 0
            for repair in Schema.orphanRepairs where try db.tableExists(repair.table) {
                try db.execute(sql: repair.sql)
                repaired += db.changesCount
            }
            guard repaired > 0 else { return 0 }
            FileHandle.standardError.write(Data(
                "Meetings: repaired \(repaired) orphaned row(s) in \(url.path)\n".utf8))
            // Recorded in the store itself, so `meetings config get store.lastRepair` can answer
            // "why is that meeting shorter than I remember" months later. stderr will be long gone.
            if try db.tableExists("settings") {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                    arguments: [
                        SettingKey.storeLastRepair.rawValue,
                        "\(ISO8601DateFormatter().string(from: Date())): removed or unlinked \(repaired) orphaned row(s)",
                    ]
                )
            }
            return repaired
        }
    }

    /// What is actually wrong with a directory `createDirectory` refused to make.
    private static func reason(for error: Error, at directory: URL) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return "there is a file there, not a directory."
        }
        // The underlying POSIX error first: Foundation's own sentence for a symlink loop is "The
        // file “loop” couldn’t be saved in the folder “attack”", which describes neither the file
        // nor the problem.
        let nsError = error as NSError
        return (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
            ?? nsError.localizedFailureReason
            ?? nsError.localizedDescription
    }

    /// Holds an exclusive `flock` on `<store>.lock` for the length of `body`.
    ///
    /// `flock` and not a lock row in the database, because the thing being protected is the database
    /// coming into existence. The kernel drops the lock when the fd closes, including on a crash, so
    /// a killed process cannot wedge every future launch.
    ///
    /// A store that cannot be locked at all must still open — the lock removes a race, it is not a
    /// permission to run. There are exactly two such stores and both are recognised rather than
    /// guessed at: one whose directory will not take a lock file (`descriptor < 0` — a read-only
    /// volume), and one on a filesystem with no advisory locking (`ENOTSUP`, some network mounts).
    ///
    /// Everything else is a *live process holding the lock*, and giving up on that one was the bug.
    /// The old wait broke after ``busyTimeout`` and ran the body anyway, which reinstates the exact
    /// race the docstring above describes: GRDB reads `grdb_migrations` once, before the
    /// per-migration transactions, so the process that gives up plans its migrations from a read
    /// the winner has since invalidated and dies on `UNIQUE constraint failed:
    /// grdb_migrations.identifier`. Five seconds was never enough anyway — the critical section now
    /// contains a whole-store `VACUUM INTO`.
    ///
    /// The kernel drops a crashed holder's lock, so waiting can only ever be waiting on a process
    /// that is still working. The bound left here is ``lockWait``, long enough for that work on a
    /// large store on a slow disk, and it *fails* rather than proceeding wrongly: an unbounded wait
    /// would turn a genuinely wedged process into a launch that hangs with nothing on screen.
    private static func serialisedAcrossProcesses<T>(for url: URL, _ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        let deadline = Date().addingTimeInterval(lockWait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            // No advisory locking here, so there is nothing to wait for and never will be.
            if failure == ENOTSUP || failure == EOPNOTSUPP || failure == EINVAL { break }
            guard Date() < deadline else {
                throw StoreOpenError.stillLocked(path: url.path, seconds: Int(lockWait))
            }
            usleep(20_000)
        }
        return try body()
    }

    /// A throwaway store in a fresh temp directory, for tests and dry runs. A real file rather than
    /// `:memory:` on purpose — WAL, the busy timeout and two-process behaviour are exactly what the
    /// store has to get right, and an in-memory database cannot exercise any of them.
    public static func temporary() throws -> DatabasePool {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetings-test-\(UUID().uuidString)", isDirectory: true)
        return try open(at: directory.appendingPathComponent("store.db"))
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(busyTimeout)
        // Notes anchor to segment ids and segments belong to meetings; without this the cascades in
        // the schema are decoration and deleting a meeting leaves orphans behind.
        config.foreignKeysEnabled = true
        return config
    }
}
