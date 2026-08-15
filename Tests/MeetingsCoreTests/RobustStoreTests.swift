import Foundation
import GRDB
import Testing

@testable import MeetingsCore

/// The store against a filesystem that is not co-operating.
///
/// Everything here was reproduced against a real store before the fix was written — a store with an
/// orphaned row, one truncated to a hundred bytes, one written by a build from the future, one on a
/// volume with nothing left on it. The bar for each is the same: the person reading the message can
/// tell what is wrong and what to do, and nothing else in the store is lost getting there.
@Suite final class RobustStoreTests {
    let directory: URL

    init() throws { directory = try TestStore.makeDirectory() }
    deinit { TestStore.remove(directory) }

    var storeURL: URL { directory.appendingPathComponent("store.db") }

    /// Reopening is what the tests here actually exercise, so the pool from the first open has to be
    /// gone: a live `DatabasePool` in this process would keep serving reads out of its own
    /// connections and nothing would be re-migrated.
    func openStore() throws -> MeetingStore {
        MeetingStore(dbPool: try MeetingsDatabase.open(at: storeURL))
    }

    /// Corruption of the database file itself, the way a bad sector or a half-finished copy leaves
    /// it: the companions go too.
    ///
    /// They have to. A `-wal` is authoritative for every page it holds, so with one still beside it
    /// SQLite reads page 1 out of the log and never looks at the header — measured here, a store
    /// overwritten with 4 kB of zeroes opened and served its meetings. That is also exactly why the
    /// restore recipe in ``StoreOpenError`` deletes them before copying a snapshot into place.
    func corrupt(with bytes: Data) throws {
        for companion in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + companion)
        }
        try bytes.write(to: storeURL)
    }

    /// Damage applied the way damage arrives: through some other SQLite that does not care about
    /// this schema's foreign keys.
    func withForeignKeysOff(_ body: (Database) throws -> Void) throws {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: storeURL.path, configuration: config)
        try queue.write(body)
    }

    /// The repair only runs when a migration runs, because that is when GRDB checks. Dropping the
    /// last applied identifier is how a v2 store meeting a v3 build behaves, without needing a v3
    /// build.
    ///
    /// It replays the real last migration against a store that already has its effect, so that
    /// statement has to be a no-op the second time — `CREATE TABLE IF NOT EXISTS`, `UPDATE`, an
    /// `ALTER` guarded by a column check. A bare `CREATE TABLE` at the end of the ladder fails here
    /// before it ever reaches the repair being tested.
    func forceMigrationOnNextOpen() throws {
        try withForeignKeysOff { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                           arguments: [Schema.migrator.migrations.last])
        }
    }

    // MARK: - The orphan brick

    /// `sqlite3 store.db "PRAGMA foreign_keys=OFF; DELETE FROM meetings;"` and the app never opened
    /// again: GRDB's migrator runs `PRAGMA foreign_key_check`, the migration rolls back, and the
    /// error — which quotes the offending row, transcript text included — became the whole window.
    @Test func anOrphanedSegmentIsRepairedRatherThanFatal() throws {
        var keptID = ""
        do {
            let store = try openStore()
            let doomed = try store.createMeeting(TestStore.meeting(title: "Deleted out from under us"))
            let kept = try store.createMeeting(TestStore.meeting(title: "Perfectly fine"))
            keptID = kept.id
            try store.insertSegments([
                TestStore.segment(meetingID: doomed.id, from: 0, to: 1_000, text: "orphan"),
                TestStore.segment(meetingID: kept.id, from: 0, to: 1_000, text: "survivor"),
            ])
            try store.dbPool.close()
        }
        try withForeignKeysOff { db in
            try db.execute(sql: "DELETE FROM meetings WHERE title = 'Deleted out from under us'")
        }
        try forceMigrationOnNextOpen()

        let reopened = try openStore()

        #expect(try reopened.allMeetings().count == 1, "the healthy meeting survives the repair")
        #expect(try reopened.segments(meetingID: keptID).map(\.text) == ["survivor"])
        #expect(try reopened.dbPool.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM transcript_segments") } == 1)
        // Recorded, not silent: the store says it lost a row and when.
        let record = try #require(try reopened.setting(.storeLastRepair))
        #expect(record.contains("1 orphaned row"))
    }

    /// Not every dangling reference is a delete. `meetings.folder_id` is `ON DELETE SET NULL`, so a
    /// meeting whose folder vanished belongs in Unfiled — losing the meeting would be the repair
    /// doing more damage than the corruption.
    @Test func aDanglingFolderReferenceUnfilesTheMeetingRatherThanDeletingIt() throws {
        var meetingID = ""
        do {
            let store = try openStore()
            let folder = try store.folderNamedOrCreated("Torch0")
            meetingID = try store.createMeeting(
                TestStore.meeting(title: "Weekly", folderID: folder.id)).id
            try store.dbPool.close()
        }
        try withForeignKeysOff { db in try db.execute(sql: "DELETE FROM folders") }
        try forceMigrationOnNextOpen()

        let reopened = try openStore()

        let meeting = try #require(try reopened.meeting(id: meetingID))
        #expect(meeting.folderID == nil)
        #expect(meeting.title == "Weekly")
    }

    /// A store that is merely *damaged* is not repaired and not guessed at. The point of the case is
    /// the sentence: it says what happened, that nothing was touched, and which snapshot to copy —
    /// including the `-wal` removal, without which SQLite replays the old log over the restored file.
    @Test func aStoreThatIsNotADatabaseNamesTheSnapshotToRestoreFrom() throws {
        let snapshot: URL
        do {
            let store = try openStore()
            try store.createMeeting(TestStore.meeting())
            snapshot = try StoreBackup.run(store: store, to: directory
                .appendingPathComponent("backups", isDirectory: true)
                .appendingPathComponent(StoreBackup.filename(Date())))
            try store.dbPool.close()
        }
        try corrupt(with: Data("this is not a database, it is a poem\n".utf8))

        let error = #expect(throws: StoreOpenError.self) { _ = try openStore() }
        let message = try #require(error?.errorDescription)
        #expect(message.contains("is damaged"))
        #expect(message.contains(snapshot.lastPathComponent))
        #expect(message.contains("-wal"), "restoring over a leftover write-ahead log is how a restore corrupts")
        #expect(!message.contains("SQLITE"), "SQLite's own vocabulary is not the user's")
    }

    /// The repair clears every orphan this schema can have, so reaching the diagnosis with a
    /// foreign-key error still in hand means something stopped it. What must not happen either way
    /// is the original error going out as it is: GRDB renders a constraint failure with the row that
    /// caused it, and that row is a sentence somebody said in a meeting.
    @Test func aForeignKeyFailureNeverQuotesTheRowItRejected() throws {
        let raw = DatabaseError(
            resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY,
            message: "FOREIGN KEY constraint violation - from transcript_segments(meeting_id) to meetings(id)",
            sql: "INSERT INTO transcript_segments (text) VALUES (?)",
            arguments: ["the number we agreed was four hundred thousand"],
            publicStatementArguments: true
        )

        let diagnosed = StoreOpenError.diagnose(raw, url: storeURL)
        let message = try #require((diagnosed as? LocalizedError)?.errorDescription)

        #expect(message.contains("could not be repaired"))
        #expect(!message.contains("four hundred thousand"))
        #expect(!message.contains("INSERT INTO"))
    }

    @Test func aDamagedStoreWithNoSnapshotsSaysSoRatherThanNamingNothing() throws {
        do {
            let store = try openStore()
            try store.createMeeting(TestStore.meeting())
            try store.dbPool.close()
        }
        try corrupt(with: Data(repeating: 0, count: 4096))

        let error = #expect(throws: StoreOpenError.self) { _ = try openStore() }
        #expect(try #require(error?.errorDescription).contains("no automatic snapshots"))
    }

    // MARK: - The copy taken before an upgrade

    /// **A migration that rewrites user prose takes a copy of it first.**
    ///
    /// A migration here is not only a schema change: `v6` overwrote every `summary` in the store —
    /// somebody's write-up, edited in place, irreversibly — and nothing had snapshotted it.
    /// ``StoreBackup/run(store:to:keeping:now:)`` was reachable only from `meetings backup`, a command
    /// run by hand, so "restore an older snapshot from the backups directory beside the store" was
    /// advice with an empty directory behind it for everyone who had never heard of it.
    @Test func anUpgradeSnapshotsTheStoreBeforeRewritingIt() throws {
        let backups = directory.appendingPathComponent("backups", isDirectory: true)
        do {
            let store = try openStore()
            try store.createMeeting(TestStore.meeting(title: "Written before the upgrade"))
            try store.dbPool.close()
        }
        #expect(try StoreBackup.list(in: backups).isEmpty,
                "a store being created has nothing worth copying, and an open with nothing pending copies nothing")

        try forceMigrationOnNextOpen()
        let reopened = try openStore()

        let snapshots = try StoreBackup.list(in: backups)
        #expect(snapshots.count == 1, "the upgrade left the snapshot the error message names")
        // A real store, not a marker: it opens, and it holds what was there before the pass ran.
        let restored = MeetingStore(dbPool: try DatabasePool(path: try #require(snapshots.first).path))
        #expect(try restored.allMeetings().map(\.title) == ["Written before the upgrade"])
        #expect(try reopened.allMeetings().count == 1, "and the store itself came through the migration")
    }

    /// Best-effort, and the migration is not: a backups directory that cannot be written to costs the
    /// snapshot, not the upgrade. Somebody whose disk is full still gets their meetings.
    @Test func aSnapshotThatCannotBeWrittenDoesNotStopTheUpgrade() throws {
        let backups = directory.appendingPathComponent("backups", isDirectory: true)
        do {
            let store = try openStore()
            try store.createMeeting(TestStore.meeting(title: "Still opens"))
            try store.dbPool.close()
        }
        // A file where the backups directory goes: nothing can be created inside it.
        try Data("not a directory\n".utf8).write(to: backups)
        try forceMigrationOnNextOpen()

        let reopened = try openStore()
        #expect(try reopened.allMeetings().map(\.title) == ["Still opens"])
    }

    // MARK: - A store from the future

    /// GRDB's migrator only ever looks for migrations that are *missing*, so an older build opens a
    /// newer store without a word and starts writing rows that ignore whatever the newer migration
    /// added. Refusing is the only safe answer, and the store has to come out untouched.
    @Test func aStoreFromANewerBuildIsRefusedAndLeftAlone() throws {
        do {
            let store = try openStore()
            try store.createMeeting(TestStore.meeting(title: "Written by the future"))
            try store.dbPool.close()
        }
        try withForeignKeysOff { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99')")
        }

        let error = #expect(throws: StoreOpenError.self) { _ = try openStore() }
        let message = try #require(error?.errorDescription)
        #expect(message.contains("newer version"))
        #expect(message.contains("v99"))
        // And it says which snapshot, or that there is none — rather than pointing at a backups
        // directory that may well be empty. Nothing has been migrated here, so nothing snapshotted it.
        #expect(message.contains("no automatic snapshot beside the store"))

        // Untouched: same migrations, same rows, and it still opens for the build that wrote it.
        var applied: Set<String> = []
        var meetings = 0
        try withForeignKeysOff { db in
            applied = try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
            meetings = try Int.fetchOne(db, sql: "SELECT count(*) FROM meetings") ?? 0
        }
        #expect(applied == Set(Schema.migrator.migrations + ["v99"]))
        #expect(meetings == 1)
    }

    // MARK: - Somewhere impossible

    @Test func aFileWhereTheStoreDirectoryShouldBeIsNamedAsSuch() throws {
        let path = directory.appendingPathComponent("not-a-directory")
        try Data("i am a file\n".utf8).write(to: path)

        let error = #expect(throws: StoreOpenError.self) {
            _ = try MeetingsDatabase.open(at: path.appendingPathComponent("store.db"))
        }
        #expect(try #require(error?.errorDescription).contains("there is a file there, not a directory"))
    }

    @Test func aDirectoryWhereTheStoreFileShouldBeIsNamedAsSuch() throws {
        let path = directory.appendingPathComponent("store.db", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        let error = #expect(throws: StoreOpenError.self) { _ = try openStore() }
        #expect(try #require(error?.errorDescription).contains("has to be a file"))
    }

    /// `MEETINGS_HOME=meetings` is not one store. The CLI resolves it against wherever you are
    /// standing and the app against `/`, so it silently becomes a different, healthy-looking store
    /// per working directory. A subprocess because the rule is about the process environment.
    @Test func aRelativeStoreOverrideIsRefusedInsteadOfForkingTheStore() throws {
        let cli = Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("meetings")
        try #require(FileManager.default.fileExists(atPath: cli.path))

        let process = Process()
        let err = Pipe()
        process.executableURL = cli
        process.arguments = ["list"]
        process.environment = ["MEETINGS_HOME": "relative-store", "PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(message.contains("relative path"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("relative-store").path),
                "nothing may be created at the ambiguous path")
    }

    // MARK: - Snapshots

    /// A VACUUM that runs out of disk leaves the file it had started. Zero bytes sorts to the front
    /// of a directory listing that is ordered by name, so it becomes the snapshot the damaged-store
    /// message offers — and the next prune drops a real one to keep it.
    @Test func anEmptySnapshotIsNotOfferedAsABackup() throws {
        let backups = directory.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let real = backups.appendingPathComponent("store-2026-08-01-090000.db")
        try Data(repeating: 0x41, count: 4096).write(to: real)
        try Data().write(to: backups.appendingPathComponent("store-2026-08-02-090000.db"))

        #expect(try StoreBackup.list(in: backups).map(\.lastPathComponent) == [real.lastPathComponent])
    }
}

// MARK: - Bundles from somewhere else

@Suite final class RobustBundleTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    /// **The security one.** A meeting id out of a bundle becomes a directory name, so
    /// `"id": "../../../../pwned"` in `meeting.json` wrote the bundle's audio outside the audio root
    /// — anywhere the user can write. Reproduced end to end before this existed.
    @Test func aBundleWhoseMeetingIdEscapesTheAudioRootCannotWriteOutsideIt() throws {
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        let source = directory.appendingPathComponent("incoming.meetingbundle", isDirectory: true)
        try writeBundle(at: source, id: "../../../../pwned", withAudioNamed: "mic.wav")

        let result = try MeetingBundle.restore(at: source, into: store, audioRoot: audioRoot)

        #expect(result.meeting.id != "../../../../pwned")
        #expect(result.idCollision, "the import has to say the id it was given is not the id it used")
        #expect(MeetingStore.isUsableAsAFilename(result.meeting.id))
        let escaped = directory.deletingLastPathComponent().appendingPathComponent("pwned")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        let landed = try #require(result.meeting.audioPath)
        #expect(landed.hasPrefix(audioRoot.path + "/"))
        #expect(FileManager.default.fileExists(atPath: landed + "/mic.wav"))
    }

    /// The same guard, minus the traversal: an empty id, or one carrying a path separator or a
    /// leading dot, is not a filename this store would ever have produced.
    @Test(arguments: ["", "..", "a/b", "a:b", ".hidden", "with space", String(repeating: "x", count: 129)])
    func anIdThatIsNotAFilenameIsRejected(_ id: String) {
        #expect(!MeetingStore.isUsableAsAFilename(id))
    }

    @Test func anOrdinaryUUIDIsAccepted() {
        #expect(MeetingStore.isUsableAsAFilename(UUID().uuidString))
    }

    /// A bundle with a file nobody has heard of is still a bundle: the reader takes what it knows.
    @Test func anUnknownExtraFileIsIgnored() throws {
        let source = directory.appendingPathComponent("extra.meetingbundle", isDirectory: true)
        try writeBundle(at: source, id: UUID().uuidString)
        try Data("who put this here\n".utf8).write(to: source.appendingPathComponent("surprise.txt"))

        #expect(try MeetingBundle.read(at: source).meeting.title == "Imported")
    }

    /// The reader used to print `dataCorrupted(Swift.DecodingError.Context(codingPath: []…))` at
    /// whoever's bundle got truncated in transit.
    @Test func aTruncatedFileReadsAsASentence() throws {
        let source = directory.appendingPathComponent("torn.meetingbundle", isDirectory: true)
        try writeBundle(at: source, id: UUID().uuidString)
        try Data("[{\"chann".utf8).write(to: source.appendingPathComponent(MeetingBundle.File.transcript))

        let error = #expect(throws: BundleError.self) { _ = try MeetingBundle.read(at: source) }
        let message = try #require(error?.errorDescription)
        #expect(message.contains("transcript.json"))
        #expect(!message.contains("codingPath"))
    }

    /// `--with-audio` on a meeting whose audio directory was deleted underneath it wrote a bundle
    /// with no `audio/` and said nothing — on the one path that exists to survive losing the machine.
    @Test func exportingAudioThatIsGoneStillWritesTheBundle() throws {
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        var meeting = TestStore.meeting(title: "Audio deleted underneath it")
        meeting.audioPath = audioRoot.appendingPathComponent(meeting.id).path
        meeting = try store.createMeeting(meeting)

        let out = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bundle = try MeetingBundle.export(
            meeting, store: store, to: out, withAudio: true, audioRoot: audioRoot)

        #expect(try MeetingBundle.read(at: bundle).audio.isEmpty)
        #expect(try MeetingBundle.read(at: bundle).meeting.title == meeting.title)
    }

    // MARK: -

    func writeBundle(at url: URL, id: String, withAudioNamed audioName: String? = nil) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest = MeetingBundle.Manifest(exportedAt: Date(), sourceMachine: "elsewhere")
        let row = MeetingBundle.MeetingRow(
            id: id, title: "Imported", state: .complete, folder: nil, calendarEventId: nil,
            scheduledStart: nil, scheduledEnd: nil, startedAt: TestStore.referenceDate,
            endedAt: nil, attendees: [], source: .recorded, importedFrom: nil, audioPurgedAt: nil)
        try write(manifest, to: url.appendingPathComponent(MeetingBundle.File.manifest))
        try write(row, to: url.appendingPathComponent(MeetingBundle.File.meeting))
        try write([MeetingBundle.Segment](), to: url.appendingPathComponent(MeetingBundle.File.transcript))
        try write([MeetingBundle.NoteRow](), to: url.appendingPathComponent(MeetingBundle.File.notes))
        try Data().write(to: url.appendingPathComponent(MeetingBundle.File.preNotes))
        if let audioName {
            let audio = url.appendingPathComponent(MeetingBundle.File.audio, isDirectory: true)
            try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 64).write(to: audio.appendingPathComponent(audioName))
        }
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try MeetingBundle.encoder.encode(value).write(to: url)
    }
}

// MARK: - Retention against a filesystem that moved

@Suite final class RobustRetentionTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    /// The audio directory is gone — a Finder window, an over-eager cleaner, a half-finished restore
    /// — and the sweep still has to clear the row, or the UI keeps offering a play button for a file
    /// that is not there and the sweep retries it every launch forever.
    @Test func aSweepOverAudioThatIsAlreadyGoneStillClearsTheRow() throws {
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        var meeting = TestStore.meeting(
            title: "Audio deleted underneath it",
            startedAt: Date().addingTimeInterval(-90 * 86_400))
        meeting.audioPath = audioRoot.appendingPathComponent(meeting.id).path
        meeting = try store.createMeeting(meeting)

        let purged = try Retention(store: store, audioRoot: audioRoot).sweep(retentionDays: 30)

        #expect(purged.count == 1)
        #expect(purged[0].bytes == 0)
        let after = try #require(try store.meeting(id: meeting.id))
        #expect(after.audioPath == nil)
        #expect(after.audioPurgedAt != nil)
    }

    /// And the whole audio root gone with it: the sweep runs on every launch, so it has to be a
    /// no-op rather than the thing that stops the app opening.
    @Test func aSweepWithNoAudioRootAtAllDoesNotThrow() throws {
        let missing = directory.appendingPathComponent("nowhere/audio", isDirectory: true)
        var meeting = TestStore.meeting(startedAt: Date().addingTimeInterval(-90 * 86_400))
        meeting.audioPath = missing.appendingPathComponent(meeting.id).path
        meeting = try store.createMeeting(meeting)

        #expect(try Retention(store: store, audioRoot: missing).sweep(retentionDays: 30).count == 1)
        #expect(try store.meeting(id: meeting.id)?.audioPath == nil)
    }
}
