import Foundation
import GRDB

@testable import MeetingsCore

/// Every store test runs against a real file in a fresh temp directory, deleted afterwards. Not
/// `:memory:`: WAL, the busy timeout and two processes sharing one file are exactly the behaviour
/// under test, and an in-memory database has none of it.
///
/// Suites hold a `directory` and a `store` and clean up in `deinit` — swift-testing makes a new
/// instance per test case, so no test can see another's rows.
enum TestStore {
    static func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetings-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func open(_ directory: URL) throws -> MeetingStore {
        MeetingStore(dbPool: try MeetingsDatabase.open(at: directory.appendingPathComponent("store.db")))
    }

    // MARK: - Fixtures

    /// Whole seconds on purpose: the date columns are INTEGER seconds, so a fixture with a
    /// fractional date would fail a round-trip test for the wrong reason.
    static let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    static func meeting(
        title: String = "Torch0 weekly",
        state: MeetingState = .ready,
        folderID: String? = nil,
        startedAt: Date? = referenceDate,
        preNotes: String = ""
    ) -> Meeting {
        Meeting(
            folderID: folderID,
            title: title,
            state: state,
            startedAt: startedAt,
            endedAt: startedAt.map { $0.addingTimeInterval(1800) },
            preNotes: preNotes
        )
    }

    static func segment(
        meetingID: String,
        channel: Channel = .mic,
        from startMs: Int,
        to endMs: Int,
        text: String,
        pass: Pass = .live,
        edited: Bool = false
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            tStartMs: startMs,
            tEndMs: endMs,
            text: text,
            pass: pass,
            edited: edited
        )
    }
}
