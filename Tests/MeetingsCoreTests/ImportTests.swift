import Foundation
import Testing

@testable import MeetingsCore

/// The import rule, which is one sentence long and load-bearing: "Id collision generates a new
/// id and records `imported_from` — **never overwrites**."
@Suite final class ImportTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    /// Import the same bundle twice and you have two independent meetings; edit one and the other
    /// does not move.
    @Test func importingTwiceGivesTwoMeetingsAndLeavesTheFirstAlone() throws {
        let original = try BundleFixture.loadedMeeting(in: store)
        let bundle = try MeetingBundle.export(original, store: store, to: directory)

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let target = try TestStore.open(elsewhere)

        let first = try MeetingBundle.restore(at: bundle, into: target)
        let second = try MeetingBundle.restore(at: bundle, into: target)

        #expect(first.meeting.id != second.meeting.id)
        #expect(!first.idCollision)
        #expect(second.idCollision)
        #expect(second.meeting.importedFrom == bundle.lastPathComponent)
        #expect(second.meeting.source == .imported)
        #expect(try target.allMeetings().count == 2)

        // The transcripts and notes are separate rows, not shared ones.
        let firstSegments = try target.segments(meetingID: first.meeting.id)
        let secondSegments = try target.segments(meetingID: second.meeting.id)
        #expect(firstSegments.map(\.text) == secondSegments.map(\.text))
        #expect(Set(firstSegments.compactMap(\.id)).isDisjoint(with: Set(secondSegments.compactMap(\.id))))
        #expect(try target.notes(meetingID: first.meeting.id).count == 3)
        #expect(try target.notes(meetingID: second.meeting.id).count == 3)

        // Change the copy; the original must not follow.
        try target.updateMeeting(id: second.meeting.id) { $0.title = "A different title entirely" }
        #expect(try target.meeting(id: first.meeting.id)?.title == original.title)
        #expect(try target.meeting(id: first.meeting.id)?.summary == original.summary)
    }

    /// The other collision: this machine already materialised the same calendar event. The unique
    /// index covers non-imported rows, so the incoming copy has to be marked imported or the insert
    /// fails outright — and the local row stays the one `cal:` writes land on.
    @Test func aBundleForAnEventThisMachineAlreadyHasIsImportedBeside_it() throws {
        let original = try BundleFixture.loadedMeeting(in: store)
        let bundle = try MeetingBundle.export(original, store: store, to: directory)

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let target = try TestStore.open(elsewhere)
        let local = try target.createMeeting(Meeting(
            title: "Torch0 sync",
            state: .scheduled,
            calendarEventID: "event-torch0-weekly",
            scheduledStart: BundleFixture.start,
            preNotes: "my own pre-notes"
        ))

        let result = try MeetingBundle.restore(at: bundle, into: target)
        #expect(result.meeting.id != local.id)
        #expect(!result.idCollision, "the id was free; it was the calendar event that was taken")
        #expect(result.meeting.source == .imported)
        #expect(result.meeting.importedFrom == bundle.lastPathComponent)
        #expect(try target.meeting(id: local.id)?.preNotes == "my own pre-notes")
        // `cal:` writes still resolve to the row this machine materialised.
        #expect(try target.meeting(calendarEventID: "event-torch0-weekly")?.id == local.id)
    }

    @Test func dryRunReportsTheSameDecisionAndWritesNothing() throws {
        let original = try BundleFixture.loadedMeeting(in: store)
        let bundle = try MeetingBundle.export(original, store: store, to: directory)
        let contents = try MeetingBundle.read(at: bundle)

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let target = try TestStore.open(elsewhere)

        let plan = try target.planBundleImport(contents, bundleName: bundle.lastPathComponent, folderName: nil)
        #expect(plan.planOnly)
        #expect(plan.segmentCount == 3)
        #expect(plan.noteCount == 3)
        #expect(plan.folderCreated == "Torch0")
        #expect(!plan.idCollision)
        #expect(try target.allMeetings().isEmpty, "a dry run writes nothing")
        #expect(try target.folders().isEmpty, "not even the folder it would create")

        // And the real run agrees with what the plan said.
        let real = try target.importBundle(contents, bundleName: bundle.lastPathComponent, folderName: nil)
        #expect(real.meeting.id == plan.meeting.id)
        #expect(real.folderCreated == plan.folderCreated)
        #expect(real.segmentCount == plan.segmentCount)
    }

    @Test func folderOverrideWinsOverTheBundlesOwnFolder() throws {
        let original = try BundleFixture.loadedMeeting(in: store, folder: "Torch0")
        let bundle = try MeetingBundle.export(original, store: store, to: directory)

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let target = try TestStore.open(elsewhere)
        let result = try MeetingBundle.restore(at: bundle, into: target, folderName: "Archive 2026")

        #expect(result.folderCreated == "Archive 2026")
        #expect(try target.folder(id: try #require(result.meeting.folderID))?.name == "Archive 2026")
        #expect(try target.folder(named: "Torch0") == nil)
    }

    /// Everything in the row, field by field. A restore that quietly drops `attendees` or flips a
    /// state is the failure this format exists to prevent, and it would not show up in a diff of
    /// the transcript.
    @Test func everyFieldOnTheRowSurvives() throws {
        let original = try BundleFixture.loadedMeeting(in: store)
        let bundle = try MeetingBundle.export(original, store: store, to: directory)

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let target = try TestStore.open(elsewhere)
        let restored = try #require(try target.meeting(
            id: try MeetingBundle.restore(at: bundle, into: target).meeting.id))

        #expect(restored.title == original.title)
        #expect(restored.state == original.state)
        #expect(restored.calendarEventID == original.calendarEventID)
        #expect(restored.scheduledStart == original.scheduledStart)
        #expect(restored.scheduledEnd == original.scheduledEnd)
        #expect(restored.startedAt == original.startedAt)
        #expect(restored.endedAt == original.endedAt)
        #expect(restored.attendees == original.attendees)
        #expect(restored.preNotes == original.preNotes)
        #expect(restored.summary == original.summary)
        // The write-up is the row's actions, and `actions.json` is now derived from it rather than
        // from the legacy column — which stopped being the record at v6 and is never rewritten, so
        // exporting it produced a file that contradicted the `summary.md` beside it. What survives
        // the trip is every action, with its text and its box; `owner` and `due` do not, because
        // they only ever existed in that column and nothing has read them since. They stay on the
        // machine that has them, where they remain recoverable.
        #expect(restored.actions?.map(\.text) == original.actions?.map(\.text))
        #expect(restored.actions?.map(\.done) == original.actions?.map(\.done))
        #expect(restored.source == original.source)

        let segments = try target.segments(meetingID: restored.id)
        let originalSegments = try store.segments(meetingID: original.id)
        #expect(segments.map(\.text) == originalSegments.map(\.text))
        #expect(segments.map(\.channel) == [.mic, .system, .mic])
        #expect(segments.map(\.tStartMs) == [0, 4_500, 9_500])
        #expect(segments.map(\.edited) == [false, false, true], "a correction is still a correction on the far side")
    }

    /// The FTS index is maintained by triggers, so an import is searchable without anybody
    /// remembering to reindex — but only if the import writes through the store rather than around it.
    @Test func anImportedMeetingIsSearchableImmediately() throws {
        let original = try BundleFixture.loadedMeeting(in: store)
        let bundle = try MeetingBundle.export(original, store: store, to: directory)

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let target = try TestStore.open(elsewhere)
        let result = try MeetingBundle.restore(at: bundle, into: target)

        #expect(try target.search(query: "ptychography").contains { $0.meeting.id == result.meeting.id })
        #expect(try target.search(query: "Tuesday").contains { $0.meeting.id == result.meeting.id })
    }
}
