import Foundation
import GRDB
import Testing

@testable import MeetingsCore

/// The app and the CLI are two processes on one file. WAL plus a busy timeout is the whole
/// mitigation, and "two pools on one file" is the closest a unit test gets to it — same
/// SQLite locking, same WAL, same timeout, just one process. Each suite instance opens two
/// independent pools, exactly as the app and the CLI would.
@Suite final class StoreConcurrencyTests {
    let directory: URL
    /// Stands in for the app.
    let app: MeetingStore
    /// Stands in for the CLI, on the same file, through its own connection pool.
    let cli: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        app = try TestStore.open(directory)
        cli = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    @Test func twoPoolsOnOneFileBothWriteWithoutDatabaseIsLocked() async throws {
        let writesEach = 60
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (label, store) in [("app", app), ("cli", cli)] {
                group.addTask {
                    for index in 0..<writesEach {
                        let meeting = Meeting(
                            id: "\(label)-\(String(format: "%03d", index))",
                            title: "\(label) meeting \(index)",
                            startedAt: TestStore.referenceDate.addingTimeInterval(TimeInterval(index))
                        )
                        try store.createMeeting(meeting)
                        try store.addNote(meetingID: meeting.id, tOffsetMs: index, text: "note from \(label)")
                    }
                }
            }
            try await group.waitForAll()
        }

        // Both connections see all of it — no lost writes, no stale snapshot.
        #expect(try app.allMeetings().count == writesEach * 2)
        #expect(try cli.allMeetings().count == writesEach * 2)
        #expect(try cli.search(query: "note from app", limit: 500).count == writesEach)
        #expect(try app.search(query: "note from cli", limit: 500).count == writesEach)
    }

    /// The reason ``MeetingStore/updateMeeting(id:_:)`` exists. Fetching, mutating and saving as
    /// three separate steps loses whichever process finished second; doing it inside one IMMEDIATE
    /// transaction does not.
    @Test func interleavedReadModifyWritesDoNotLoseUpdates() async throws {
        let meeting = try app.createMeeting(TestStore.meeting(state: .scheduled))
        let appendsEach = 40

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (label, store) in [("app", app), ("cli", cli)] {
                group.addTask {
                    for index in 0..<appendsEach {
                        try store.updateMeeting(id: meeting.id) {
                            $0.preNotes += "\(label)-\(index)\n"
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        let preNotes = try #require(try app.meeting(id: meeting.id)?.preNotes)
        let lines = preNotes.split(separator: "\n")
        #expect(lines.count == appendsEach * 2)
        #expect(Set(lines).count == appendsEach * 2, "every append survived")
    }

    /// A committed write in one connection is visible in the other straight away — that is what WAL
    /// buys, and it is what makes the change notification useful rather than a lie.
    @Test func aReaderSeesCommittedWorkFromTheOtherConnectionImmediately() throws {
        #expect(try cli.allMeetings().isEmpty)

        let meeting = try app.createMeeting(TestStore.meeting(title: "Written by the app"))
        #expect(try cli.meeting(id: meeting.id)?.title == "Written by the app")

        try cli.updateMeeting(id: meeting.id) { $0.summary = "written by the CLI" }
        #expect(try app.meeting(id: meeting.id)?.summary == "written by the CLI")
        #expect(try app.search(query: "written by the CLI").count == 1)
    }
}
