import Foundation
import Testing

@testable import MeetingsCore

/// `VACUUM INTO` a dated snapshot, seven kept. Corruption protection, and deliberately not
/// the same thing as a bundle export.
@Suite final class BackupTests {
    let directory: URL
    let store: MeetingStore
    let backups: URL

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
        backups = directory.appendingPathComponent("backups", isDirectory: true)
    }

    deinit { TestStore.remove(directory) }

    /// The point of a snapshot is that it opens as a store. Anything less is a file of the right
    /// size, which is what people discover the day they need it.
    @Test func theSnapshotOpensAsAStoreWithTheSameContent() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let snapshot = try StoreBackup.run(store: store, to: backups.appendingPathComponent("store-2026-08-12-100000.db"))

        let reopened = MeetingStore(dbPool: try MeetingsDatabase.open(at: snapshot))
        let restored = try #require(try reopened.meeting(id: meeting.id))
        #expect(restored.title == meeting.title)
        #expect(restored.summary == meeting.summary)
        #expect(try reopened.segments(meetingID: meeting.id).count == 3)
        #expect(try reopened.notes(meetingID: meeting.id).count == 3)
        // The FTS index comes with it — a snapshot you have to reindex is a half restore.
        #expect(try reopened.search(query: "ptychography").isEmpty == false)
    }

    /// Writes committed to the WAL after the snapshot are not in it, and — the failure that matters
    /// — writes committed *before* it are, even though they may still be sitting in the log.
    @Test func theSnapshotIsATransactionBoundary() throws {
        let meeting = try store.createMeeting(TestStore.meeting(title: "Before the snapshot"))
        let snapshot = try StoreBackup.run(store: store, to: backups.appendingPathComponent("store-2026-08-12-100001.db"))
        try store.createMeeting(TestStore.meeting(title: "After the snapshot"))

        let reopened = MeetingStore(dbPool: try MeetingsDatabase.open(at: snapshot))
        #expect(try reopened.allMeetings().map(\.title) == ["Before the snapshot"])
        #expect(try reopened.meeting(id: meeting.id) != nil)
    }

    /// Ten days of real snapshots, oldest first. Real, rather than a file with the right name and
    /// some bytes in it: ``StoreBackup/list(in:)`` opens each candidate now, because a `VACUUM INTO`
    /// killed part-way leaves a plausible-sized file that is not a store and must not be offered as
    /// the thing to restore from.
    func seedSnapshots(_ days: ClosedRange<Int>) throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let seed = try StoreBackup.run(store: store, to: directory.appendingPathComponent("seed.db"))
        defer { try? FileManager.default.removeItem(at: seed) }
        for day in days {
            let name = String(format: "store-2026-08-%02d-090000.db", day)
            try FileManager.default.copyItem(at: seed, to: backups.appendingPathComponent(name))
        }
    }

    @Test func sevenAreKeptAndTheOldestGo() throws {
        try seedSnapshots(1...10)
        // Something else in the directory that is not a snapshot must survive the prune.
        try Data("not mine".utf8).write(to: backups.appendingPathComponent("README.txt"))

        let kept = try StoreBackup.prune(in: backups)
        #expect(kept.count == StoreBackup.keep)
        #expect(kept.map(\.lastPathComponent).first == "store-2026-08-10-090000.db")
        #expect(kept.map(\.lastPathComponent).last == "store-2026-08-04-090000.db")
        #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent("store-2026-08-01-090000.db").path))
        #expect(FileManager.default.fileExists(atPath: backups.appendingPathComponent("README.txt").path))
    }

    /// A dated snapshot onto a directory that is already full, the way the pre-migration copy takes
    /// one: **prune first, then write.**
    ///
    /// `run(to:)` with an explicit path deliberately does not prune — a directory the user named is
    /// theirs — so the pair is the caller's to place, and the order is not cosmetic. Pruning
    /// afterwards leaves all seven old snapshots on the disk for the whole of the copy, so it can
    /// never free the space the copy needs, which is the failure it exists for: a nearly full volume.
    /// Keeping one fewer is what leaves room for the new one inside the seven.
    @Test func aDatedSnapshotOnTopOfAFullDirectoryPrunesBeforeItWrites() throws {
        try seedSnapshots(1...7)
        try BundleFixture.loadedMeeting(in: store)

        let kept = try StoreBackup.prune(in: backups, keeping: StoreBackup.keep - 1)
        #expect(kept.count == StoreBackup.keep - 1, "room made before a byte of the copy is written")
        #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent("store-2026-08-01-090000.db").path))

        // Comfortably later than the seven already there, whatever timezone this machine is in.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try StoreBackup.run(
            store: store, to: backups.appendingPathComponent(StoreBackup.filename(now)), now: now)
        #expect(snapshot.lastPathComponent.hasPrefix("store-2027-"))

        let after = try StoreBackup.list(in: backups)
        #expect(after.count == StoreBackup.keep)
        #expect(after.first?.lastPathComponent == snapshot.lastPathComponent, "the new one is the newest")
    }

    @Test func aSecondSnapshotToTheSamePathReplacesIt() throws {
        try BundleFixture.loadedMeeting(in: store)
        let path = backups.appendingPathComponent("store-2026-08-12-100002.db")
        _ = try StoreBackup.run(store: store, to: path)
        try store.createMeeting(TestStore.meeting(title: "Added between snapshots"))
        _ = try StoreBackup.run(store: store, to: path)

        let reopened = MeetingStore(dbPool: try MeetingsDatabase.open(at: path))
        #expect(try reopened.allMeetings().count == 2)
    }
}
