import Foundation
import Testing

@testable import MeetingsCore

/// The one-way export. The bar is lower than the bundle's — nothing round-trips — but two
/// things still have to hold: it is readable, and it never claims something exists that does not.
@Suite final class ExportMarkdownTests {
    let directory: URL
    let store: MeetingStore
    let root: URL

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
        root = directory.appendingPathComponent("Meetings", isDirectory: true)
    }

    deinit { TestStore.remove(directory) }

    @Test func itWritesTheFourFilesUnderFolderAndSlug() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let out = try MarkdownExport.export(meeting, store: store, to: root)

        #expect(out.deletingLastPathComponent().lastPathComponent == "Torch0")
        #expect(out.lastPathComponent.hasSuffix("-maagan-michael-torch0-sync"))
        #expect(BundleFixture.tree(out) == ["meta.json", "notes.md", "summary.md", "transcript.md"])

        let transcript = try String(contentsOf: out.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(transcript.contains("**0:00** You: morning — shall we start with the ptychography run"))
        #expect(transcript.contains("**0:04** Others: yes, the numbers came back better than Tuesday"))

        let notes = try String(contentsOf: out.appendingPathComponent("notes.md"), encoding: .utf8)
        #expect(notes.contains("## Before the meeting"))
        #expect(notes.contains("ask about the ptychography run"))
        #expect(notes.contains("## During the meeting"))
        #expect(notes.contains("**0:06** better than Tuesday — get the exact figure"))

        let summary = try String(contentsOf: out.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summary.contains("Ship Torch0 on Friday."))
        // The actions are in the write-up, so they are exported because the write-up is — and
        // exactly once. The fixture's legacy `actions` column is still populated, the way the v6
        // migration leaves a real store, and an export that still read it would print both twice.
        #expect(summary.contains("- [ ] Send the ptychography numbers"))
        #expect(summary.contains("- [x] Book the follow-up"))
        #expect(summary.components(separatedBy: "- [x] Book the follow-up").count == 2,
                "the actions are written once, from the write-up, not once again from the column")

        let meta = try #require(FileManager.default.contents(atPath: out.appendingPathComponent("meta.json").path))
        let decoded = try #require(try JSONSerialization.jsonObject(with: meta) as? [String: Any])
        #expect(decoded["title"] as? String == meeting.title)
        #expect(decoded["state"] as? String == "complete")
        #expect(decoded["folder"] as? String == "Torch0")
        #expect((decoded["exportFormat"] as? String)?.contains("one-way") == true)
    }

    /// `owner` and `due` leave the machine with the meeting.
    ///
    /// The markdown cannot express either, so on a migrated store the legacy column is their only
    /// copy — and `meta.json`'s actions are derived from the write-up, which meant this export
    /// destroyed them. The bundle path was fixed and this one was not, on the export somebody
    /// reaches for when they are leaving the machine. One rule now:
    /// ``MeetingBundle/withLegacyOwnerAndDue(_:from:)``.
    @Test func metaCarriesTheOwnerAndDueTheWriteUpCannotHold() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let out = try MarkdownExport.export(meeting, store: store, to: root)

        let data = try #require(FileManager.default.contents(atPath: out.appendingPathComponent("meta.json").path))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let actions = try #require(decoded["actions"] as? [[String: Any]])
        // Derived from the write-up: which actions exist and what they say is the document's call.
        #expect(actions.map { $0["text"] as? String }
            == ["Send the ptychography numbers", "Book the follow-up"])
        #expect(actions[0]["owner"] as? String == "Sofia")
        #expect(actions[0]["due"] as? String == "end of week")
    }

    /// A meeting with notes and no transcript is legal, and an empty `transcript.md` would be a
    /// claim that it was recorded and nobody spoke.
    @Test func aMeetingWithNoTranscriptGetsNoTranscriptFile() throws {
        let meeting = try store.createMeeting(Meeting(
            title: "Coffee with Sofia", state: .complete, startedAt: BundleFixture.start,
            preNotes: "ask about the Airbus timeline"
        ))
        let out = try MarkdownExport.export(meeting, store: store, to: root)
        #expect(BundleFixture.tree(out) == ["meta.json", "notes.md"])
        #expect(out.deletingLastPathComponent().lastPathComponent == "Unfiled")
    }

    /// The automatic run is off by default, so a default install writes nothing to `~/Meetings`.
    @Test func theAutomaticExportOnlyFiresWhenItIsTurnedOnAndTheMeetingIsComplete() throws {
        try store.setSetting(.exportMarkdownRoot, root.path)
        let ready = try store.createMeeting(Meeting(title: "Not written up yet", state: .ready, startedAt: BundleFixture.start))
        let complete = try BundleFixture.loadedMeeting(in: store)

        #expect(try MarkdownExport.exportIfEnabled(meetingID: complete.id, store: store) == nil, "off by default")

        try store.setSetting(.exportMarkdownOnComplete, "true")
        #expect(try MarkdownExport.exportIfEnabled(meetingID: ready.id, store: store) == nil, "not complete, not exported")
        let out = try #require(try MarkdownExport.exportIfEnabled(meetingID: complete.id, store: store))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))
        #expect(try MarkdownExport.root(store: store) == root)
    }

    /// A re-export after the summary was cleared must not leave the old one lying there being wrong.
    @Test func aReExportRemovesAFileWhoseSectionHasGoneAway() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let out = try MarkdownExport.export(meeting, store: store, to: root)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))

        let cleared = try store.updateMeeting(id: meeting.id) { row in
            row.summary = nil
            row.actions = nil
        }
        _ = try MarkdownExport.export(cleared, store: store, to: root)
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.md").path))
    }

    /// Wave 2 wired `exportIfEnabled` into `create` and `import` and nowhere else, so the way a
    /// meeting actually reaches `complete` in daily use — an agent writing the summary — exported
    /// nothing. The hook now sits on the store's update path, so every transition is covered by
    /// construction rather than by remembering.
    @Test func everyTransitionIntoCompleteExports() throws {
        try store.setSetting(.exportMarkdownRoot, root.path)
        try store.setSetting(.exportMarkdownOnComplete, "true")

        // 1. `meetings summary set` — a read-modify-write through `updateMeeting(id:_:)`.
        let ready = try store.createMeeting(TestStore.meeting(title: "Airbus review", state: .ready))
        #expect(!FileManager.default.fileExists(atPath: directory(for: "airbus-review").path))
        try store.updateMeeting(id: ready.id) { row in
            row.summary = "# Decisions\n\nShip on Friday."
            row.state = .complete
        }
        let summaryFile = directory(for: "airbus-review").appendingPathComponent("summary.md")
        #expect(try String(contentsOf: summaryFile, encoding: .utf8).contains("Ship on Friday."))

        // 2. A whole-record save — what the app and the cloud enhancer use.
        var other = try store.createMeeting(TestStore.meeting(title: "Rig handover", state: .ready))
        other.summary = "Handed over."
        other.state = .complete
        try store.updateMeeting(other)
        #expect(FileManager.default.fileExists(
            atPath: directory(for: "rig-handover").appendingPathComponent("summary.md").path))

        // 3. The batch re-pass landing on a meeting that already has a summary, which counts as
        //    complete, and the export has to see the final transcript, not the live one.
        let repassed = try store.createMeeting(TestStore.meeting(title: "Ptychography sync", state: .transcribing))
        try store.updateMeeting(id: repassed.id) { $0.summary = "Ran the rig." }
        try store.replaceLiveSegments(meetingID: repassed.id, with: [
            TestStore.segment(meetingID: repassed.id, from: 0, to: 3_000, text: "the rig is free on Thursday"),
        ])
        #expect(try store.meeting(id: repassed.id)?.state == .complete)
        let transcript = directory(for: "ptychography-sync").appendingPathComponent("transcript.md")
        #expect(try String(contentsOf: transcript, encoding: .utf8).contains("the rig is free on Thursday"))
    }

    /// The other half of the same hook: a write that leaves the meeting anywhere else writes nothing
    /// to `~/Meetings`, so the export stays what it is meant to be rather than a mirror.
    @Test func aWriteThatDoesNotReachCompleteExportsNothing() throws {
        try store.setSetting(.exportMarkdownRoot, root.path)
        try store.setSetting(.exportMarkdownOnComplete, "true")

        let meeting = try store.createMeeting(TestStore.meeting(title: "Standup", state: .ready))
        try store.updateMeeting(id: meeting.id) { $0.title = "Standup" }
        #expect(!FileManager.default.fileExists(atPath: root.path))

        // And clearing a summary takes the meeting back to `ready` without re-exporting.
        try store.updateMeeting(id: meeting.id) { row in
            row.summary = "written up"
            row.state = .complete
        }
        #expect(FileManager.default.fileExists(atPath: directory(for: "standup").path))
        try FileManager.default.removeItem(at: directory(for: "standup"))
        try store.updateMeeting(id: meeting.id) { row in
            row.summary = nil
            row.state = .ready
        }
        #expect(!FileManager.default.fileExists(atPath: directory(for: "standup").path))
    }

    private func directory(for slug: String) -> URL {
        let day = Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"), timeZone: .current,
            calendar: Calendar(identifier: .gregorian)
        ).format(TestStore.referenceDate)
        return root.appendingPathComponent("Unfiled", isDirectory: true)
            .appendingPathComponent("\(day)-\(slug)", isDirectory: true)
    }

    @Test func slugsAreReadableAndNeverEmpty() {
        #expect(MeetingBundle.slug("Ma'agan Michael / Torch0 sync") == "maagan-michael-torch0-sync")
        #expect(MeetingBundle.slug("1:1 — Will") == "1-1-will")
        #expect(MeetingBundle.slug("   ") == "meeting")
        #expect(MeetingBundle.slug(String(repeating: "a", count: 200)).count == 60)
    }
}
