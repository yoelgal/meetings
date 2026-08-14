import Foundation
import Synchronization
import Testing

@testable import MeetingsCore

@Suite final class StoreChangeTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = MeetingStore(dbPool: try MeetingsDatabase.open(at: directory.appendingPathComponent("store.db")))
    }

    deinit { TestStore.remove(directory) }

    /// The one thing that actually matters about the ordering: by the time a listener is told a
    /// meeting changed, reading the store must show the change. A notification posted inside the
    /// transaction would have the listener cache the *old* row and never look again.
    @Test func theNotificationArrivesAfterTheCommit() throws {
        let seen = Mutex<[String]>([])
        let meeting = TestStore.meeting(title: "Committed?")
        let store = self.store

        let observation = StoreChange.observe(storePath: store.dbPool.path) { meetingID in
            guard let meetingID else { return }
            let title = (try? store.meeting(id: meetingID))??.title ?? "<not committed yet>"
            seen.withLock { $0.append(title) }
        }
        defer { _ = observation }

        try store.createMeeting(meeting)
        #expect(seen.withLock { $0 } == ["Committed?"])
    }

    @Test func everyMutationAnnouncesItself() throws {
        let posts = Mutex<[String?]>([])
        let observation = StoreChange.observe(storePath: store.dbPool.path) { meetingID in posts.withLock { $0.append(meetingID) } }
        defer { _ = observation }

        func recorded(_ body: () throws -> Void) rethrows -> [String?] {
            posts.withLock { $0.removeAll() }
            try body()
            return posts.withLock { $0 }
        }

        let folder = try store.createFolder(Folder(name: "Torch0"))
        let meeting = TestStore.meeting(state: .ready, folderID: folder.id)

        #expect(try recorded { try store.createMeeting(meeting) } == [meeting.id])
        #expect(try recorded { try store.updateMeeting(id: meeting.id) { $0.title = "Renamed" } } == [meeting.id])

        var segment = TestStore.segment(meetingID: meeting.id, from: 0, to: 1_000, text: "hello", pass: .final)
        #expect(try recorded { segment = try store.insertSegment(segment) } == [meeting.id])
        #expect(try recorded { _ = try store.editSegment(id: segment.id!, text: "hello there") } == [meeting.id])
        #expect(try recorded { _ = try store.addNote(meetingID: meeting.id, tOffsetMs: 10, text: "n") } == [meeting.id])
        #expect(try recorded { try store.replaceLiveSegments(meetingID: meeting.id, with: []) } == [meeting.id])

        // Folder, vocabulary and settings changes are not about one meeting, so they say so.
        #expect(try recorded { _ = try store.addVocabularyTerm(VocabularyTerm(term: "ptychography")) } == [nil])
        #expect(try recorded { try store.setSetting(.audioRetentionDays, "7") } == [nil])
        #expect(try recorded { _ = try store.deleteFolder(id: folder.id) } == [nil])
        #expect(try recorded { _ = try store.deleteMeeting(id: meeting.id) } == [meeting.id])
    }

    /// A no-op delete has nothing to announce. Otherwise every failed `meetings delete` wakes the
    /// app up for nothing.
    @Test func noOpMutationsStayQuiet() throws {
        let posts = Mutex<Int>(0)
        let observation = StoreChange.observe(storePath: store.dbPool.path) { _ in posts.withLock { $0 += 1 } }
        defer { _ = observation }

        #expect(try store.deleteMeeting(id: "nope") == false)
        #expect(try store.deleteFolder(id: "nope") == false)
        #expect(try store.deleteVocabularyTerm(id: 999) == false)
        #expect(try store.setVocabularyEnabled(id: 999, false) == false)
        #expect(posts.withLock { $0 } == 0)
    }

    @Test func droppingTheObservationStopsTheCallbacks() throws {
        let posts = Mutex<Int>(0)
        var observation: StoreChange.Observation? = StoreChange.observe(storePath: store.dbPool.path) { _ in posts.withLock { $0 += 1 } }

        try store.createMeeting(TestStore.meeting())
        #expect(posts.withLock { $0 } == 1)

        observation = nil
        _ = observation
        try store.createMeeting(TestStore.meeting())
        #expect(posts.withLock { $0 } == 1)
    }

    /// distnoted echoes a post back to the process that sent it. An observer that took both copies
    /// would refresh twice per write, the second time at some unrelated moment — which is how a
    /// refresh loop starts. One write, one callback, and it stays one after the echo has had time
    /// to come back.
    @Test func theDistributedEchoOfOurOwnPostIsDropped() async throws {
        let posts = Mutex<Int>(0)
        let observation = StoreChange.observe(storePath: store.dbPool.path) { _ in posts.withLock { $0 += 1 } }
        defer { _ = observation }

        try store.createMeeting(TestStore.meeting())
        #expect(posts.withLock { $0 } == 1)

        try await Task.sleep(for: .milliseconds(500))
        #expect(posts.withLock { $0 } == 1, "the echo arrived and was counted a second time")
    }

    @Test func theNotificationNameIsTheOneBothProcessesAgreedOn() {
        #expect(StoreChange.name.rawValue == "com.yoelgal.Meetings.storeChanged")
        #expect(StoreChange.meetingIDKey == "meetingId")
    }
}
