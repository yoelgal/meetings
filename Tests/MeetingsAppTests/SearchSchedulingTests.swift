import Foundation
import MeetingsCore
import Testing

@testable import MeetingsApp

/// **The palette's read runs after the keystroke, not inside it.**
///
/// `searchQuery`'s `didSet` is the setter SwiftUI's `TextField` writes through, so calling the FTS
/// read from it put a query, a `snippet()` per hit and a re-render of the list inside AppKit's
/// text-input event with the field mid-edit — and the field was re-set from the binding between two
/// characters. Typing `or` searched `ro`, and against a store holding "Testing Meetings app with Or"
/// and "Problem Solving (Intern/Graduate) interview with Revolut" that returns the interview and not
/// the meeting whose name was typed. Same store, same function, a query nobody typed.
///
/// `AppSourceGuardTests` pins the *shape* — the setter calls `scheduleSearch()` and not
/// `runSearch()`. That is one level away from the criterion: a `scheduleSearch` that ran the read
/// synchronously would satisfy it and reintroduce the whole defect under a new name. This asserts
/// the criterion itself, which is that nothing has changed on the model by the time the setter
/// returns.
///
/// **No window, no view.** `AppModel` is an `@Observable` class over a store, and the calendar source
/// is a fixture pointing at a file that does not exist — the calendar is never read here and EventKit
/// is never touched.
@MainActor @Suite final class SearchSchedulingTests {
    private let directory: URL
    private let store: MeetingStore
    private let model: AppModel

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetings-search-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MeetingStore(
            dbPool: try MeetingsDatabase.open(at: directory.appendingPathComponent("store.db"))
        )
        _ = try store.createMeeting(Meeting(title: "Torch0 weekly", state: .ready))
        model = AppModel(
            store: store,
            calendarSource: FixtureCalendarSource(url: directory.appendingPathComponent("none.json"))
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Waits for the scheduled search to land, without ever waiting a fixed amount of time.
    private func settled() async {
        for _ in 0..<200 where model.searchResults.isEmpty {
            await Task.yield()
        }
    }

    @Test func settingTheQueryChangesNothingBeforeTheSetterReturns() async {
        model.searchQuery = "Torch0"
        #expect(model.searchResults.isEmpty, """
            The results were already there when the setter returned, so the store was read from \
            inside the keystroke. That is the arrangement that searched `ro` while `or` was being \
            typed — a synchronous `scheduleSearch` is the same defect wearing the fixed name.
            """)

        await settled()
        #expect(model.searchResults.map(\.meeting.title) == ["Torch0 weekly"], """
            Deferring is only half of it: the search still has to run, and to run against the \
            query as it stands when it runs.
            """)
    }

    /// A burst of typing costs one read of the store, and it is a read of the **last** query — the
    /// half-typed ones are cancelled rather than answered.
    @Test func onlyTheSettledQueryIsEverAsked() async {
        for query in ["T", "To", "Tor", "Torch0"] {
            model.searchQuery = query
            #expect(model.searchResults.isEmpty, "\(query) was answered inside its own keystroke")
        }
        await settled()
        #expect(model.searchResults.map(\.meeting.title) == ["Torch0 weekly"])
    }

    /// Clearing the field empties the results, and that also has to wait for its own turn — the
    /// setter is the same setter.
    @Test func clearingTheFieldEmptiesTheResultsOnItsOwnTurn() async {
        model.searchQuery = "Torch0"
        await settled()
        #expect(!model.searchResults.isEmpty)

        model.searchQuery = ""
        for _ in 0..<200 where !model.searchResults.isEmpty {
            await Task.yield()
        }
        #expect(model.searchResults.isEmpty)
    }
}
