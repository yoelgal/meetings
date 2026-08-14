import Foundation
import Testing

@testable import MeetingsCore

/// The retention sweep, against real files and a clock the test owns. Nothing here waits for
/// thirty days and nothing touches the system clock: the sweep takes `now`, so the test stands the
/// meeting in the past instead of standing itself in the future.
@Suite final class RetentionTests {
    let directory: URL
    let audioRoot: URL
    let store: MeetingStore
    /// Whole seconds: the date columns are INTEGER seconds.
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    init() throws {
        directory = try TestStore.makeDirectory()
        audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    private var retention: Retention { Retention(store: store, audioRoot: audioRoot) }

    /// A meeting with two real WAVs on disk and its `audio_path` set, exactly as the recorder and
    /// the batch pass leave it.
    @discardableResult
    private func recorded(daysAgo: Double, state: MeetingState = .complete) throws -> Meeting {
        let endedAt = now.addingTimeInterval(-daysAgo * 86_400)
        var meeting = try store.createMeeting(TestStore.meeting(
            state: state, startedAt: endedAt.addingTimeInterval(-1_800)))
        let audio = audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        for name in ["mic.wav", "system.wav"] {
            try Data(repeating: 0x41, count: 4_096).write(to: audio.appendingPathComponent(name))
        }
        meeting = try store.updateMeeting(id: meeting.id) {
            $0.endedAt = endedAt
            $0.audioPath = audio.path
        }
        return meeting
    }

    private func exists(_ meeting: Meeting) -> Bool {
        FileManager.default.fileExists(
            atPath: audioRoot.appendingPathComponent(meeting.id, isDirectory: true).path)
    }

    @Test func audioOlderThanTheWindowIsDeletedAndTheRowSaysSo() throws {
        let old = try recorded(daysAgo: 31)
        let fresh = try recorded(daysAgo: 29)

        let purged = try retention.sweep(now: now)

        #expect(purged.map(\.meetingID) == [old.id])
        #expect(purged.first?.bytes == 8_192)
        #expect(!exists(old))
        #expect(exists(fresh))

        let row = try #require(try store.meeting(id: old.id))
        #expect(row.audioPath == nil)
        #expect(row.audioPurgedAt == now, "the UI says \"audio deleted\" off this field")
        #expect(try store.meeting(id: fresh.id)?.audioPath != nil)
        #expect(try store.meeting(id: fresh.id)?.audioPurgedAt == nil)
    }

    /// "`0` = keep forever". The setting is a string in a table anyone can write, so the
    /// guard is on the value, not on the caller remembering.
    @Test func zeroDaysKeepsEverythingForever() throws {
        let ancient = try recorded(daysAgo: 4_000)
        try store.setSetting(.audioRetentionDays, "0")

        #expect(try retention.sweep(now: now).isEmpty)
        #expect(exists(ancient))
        #expect(try store.meeting(id: ancient.id)?.audioPath != nil)
    }

    @Test func theStoredSettingIsWhatDecidesTheWindow() throws {
        let meeting = try recorded(daysAgo: 10)
        #expect(try retention.sweep(now: now).isEmpty, "30 days by default, and this is 10 days old")

        try store.setSetting(.audioRetentionDays, "7")
        #expect(try retention.sweep(now: now).map(\.meetingID) == [meeting.id])
    }

    /// The one that would lose a meeting outright: audio is being written into a `recording` row and
    /// read out of a `transcribing` one.
    @Test func aRecordingOrTranscribingMeetingIsNeverTouched() throws {
        let recording = try recorded(daysAgo: 400, state: .recording)
        let transcribing = try recorded(daysAgo: 400, state: .transcribing)
        let done = try recorded(daysAgo: 400, state: .ready)

        #expect(try retention.sweep(now: now).map(\.meetingID) == [done.id])
        #expect(exists(recording))
        #expect(exists(transcribing))
        #expect(!exists(done))
    }

    /// An imported row with no dates at all has no age, and something of unknown age is not old.
    @Test func aMeetingWithNoDateIsNotOldEnoughToPurge() throws {
        let meeting = try store.createMeeting(Meeting(title: "Imported, no dates", state: .complete))
        let audio = audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data("RIFF".utf8).write(to: audio.appendingPathComponent("mic.wav"))
        try store.updateMeeting(id: meeting.id) { $0.audioPath = audio.path }

        #expect(try retention.sweep(now: now).isEmpty)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    /// `audio_path` is a string written by the recorder, the batch pass and whatever imported the
    /// meeting, and this code calls `removeItem`. A row pointing anywhere else deletes nothing.
    @Test func aPathOutsideTheAudioRootIsRefused() throws {
        let outside = directory.appendingPathComponent("not-audio", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: outside.appendingPathComponent("keep.txt"))

        let meeting = try recorded(daysAgo: 400)
        try store.updateMeeting(id: meeting.id) { $0.audioPath = outside.path }

        #expect(try retention.sweep(now: now).isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("keep.txt").path))
        #expect(try store.meeting(id: meeting.id)?.audioPath == outside.path, "and the row is left alone")

        #expect(retention.safeAudioDirectory("/") == nil)
        #expect(retention.safeAudioDirectory(audioRoot.path) == nil, "the root itself is not one meeting's audio")
        #expect(retention.safeAudioDirectory(audioRoot.appendingPathComponent("x").path) != nil)
    }

    /// A directory a user already dragged to the bin still has to clear the row, or the app offers a
    /// play button for audio that is not there.
    @Test func alreadyMissingAudioStillClearsTheRow() throws {
        let meeting = try recorded(daysAgo: 400)
        try FileManager.default.removeItem(
            at: audioRoot.appendingPathComponent(meeting.id, isDirectory: true))

        let purged = try retention.sweep(now: now)
        #expect(purged.map(\.meetingID) == [meeting.id])
        #expect(purged.first?.bytes == 0)
        #expect(try store.meeting(id: meeting.id)?.audioPurgedAt == now)
    }

    @Test func sweepingTwiceChangesNothingTheSecondTime() throws {
        let meeting = try recorded(daysAgo: 400)
        let first = try retention.sweep(now: now)
        let second = try retention.sweep(now: now.addingTimeInterval(60))

        #expect(first.count == 1)
        #expect(second.isEmpty)
        #expect(try store.meeting(id: meeting.id)?.audioPurgedAt == now, "the first sweep's timestamp stands")
    }

    /// Two sweeps at once — the app launching while the CLI runs one, or simply two windows. Neither
    /// may throw, and between them each meeting is purged exactly once.
    @Test func concurrentSweepsPurgeEachMeetingExactlyOnce() async throws {
        let meetings = try (0..<8).map { _ in try recorded(daysAgo: 400) }
        let retention = self.retention
        let now = self.now

        let results = try await withThrowingTaskGroup(of: [Retention.Purged].self) { group in
            for _ in 0..<4 {
                group.addTask { try retention.sweep(now: now) }
            }
            return try await group.reduce(into: [Retention.Purged]()) { $0 += $1 }
        }

        #expect(Set(results.map(\.meetingID)).count == meetings.count)
        #expect(results.count == meetings.count, "no meeting was purged twice")
        #expect(meetings.allSatisfy { !exists($0) })
        #expect(try meetings.allSatisfy { try store.meeting(id: $0.id)?.audioPath == nil })
    }

    /// The launch entry point the app calls. It must not throw whatever the store does.
    @Test func sweepOnLaunchNeverThrows() throws {
        try recorded(daysAgo: 400)
        Retention.sweepOnLaunch(store: store, now: now)
        // No audio root injection on this path, so the real `Paths.audioRoot` guard refuses the
        // temp-directory path — the row is left alone, which is exactly the refusal being asserted.
        #expect(try store.meeting(id: store.allMeetings()[0].id)?.audioPath != nil)
    }
}
