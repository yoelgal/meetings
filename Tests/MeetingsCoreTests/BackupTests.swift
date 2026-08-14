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

    @Test func sevenAreKeptAndTheOldestGo() throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        // Ten days of snapshots, oldest first.
        for day in 1...10 {
            let name = String(format: "store-2026-08-%02d-090000.db", day)
            try Data("snapshot \(day)".utf8).write(to: backups.appendingPathComponent(name))
        }
        // Something else in the directory that is not a snapshot must survive the prune.
        try Data("not mine".utf8).write(to: backups.appendingPathComponent("README.txt"))

        let kept = try StoreBackup.prune(in: backups)
        #expect(kept.count == StoreBackup.keep)
        #expect(kept.map(\.lastPathComponent).first == "store-2026-08-10-090000.db")
        #expect(kept.map(\.lastPathComponent).last == "store-2026-08-04-090000.db")
        #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent("store-2026-08-01-090000.db").path))
        #expect(FileManager.default.fileExists(atPath: backups.appendingPathComponent("README.txt").path))
    }

    /// A dated snapshot on top of a full directory, then the prune: eight in, seven out, and the
    /// new one is the one that survives. Together these are what "runs on launch" amounts to.
    ///
    /// `run(to:)` with an explicit path deliberately does not prune — a directory the user named is
    /// theirs — so the launch sweep is the pair, and this asserts the pair.
    @Test func aDatedSnapshotOnTopOfAFullDirectoryPrunesToSeven() throws {
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for day in 1...7 {
            let name = String(format: "store-2026-08-%02d-090000.db", day)
            try Data("snapshot \(day)".utf8).write(to: backups.appendingPathComponent(name))
        }
        try BundleFixture.loadedMeeting(in: store)

        // Comfortably later than the seven already there, whatever timezone this machine is in.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try StoreBackup.run(
            store: store, to: backups.appendingPathComponent(StoreBackup.filename(now)), now: now)
        #expect(snapshot.lastPathComponent.hasPrefix("store-2027-"))
        #expect(try StoreBackup.list(in: backups).count == 8, "written, not yet pruned")

        let kept = try StoreBackup.prune(in: backups)
        #expect(kept.count == StoreBackup.keep)
        #expect(kept.first?.lastPathComponent == snapshot.lastPathComponent, "the new one is the newest")
        #expect(!FileManager.default.fileExists(atPath: backups.appendingPathComponent("store-2026-08-01-090000.db").path))
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
