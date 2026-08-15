import AVFoundation
import Foundation
import Testing

@testable import MeetingsCore

/// Real audio, generated rather than checked in: a sine tone at whatever rate and channel count the
/// test needs. Enough for a file copy to be meaningful and for the converter to have something with
/// actual energy in it to resample.
enum AudioFixture {
    static func write(
        to url: URL,
        seconds: Double,
        frequency: Double,
        sampleRate: Double,
        channels: Int,
        formatID: AudioFormatID = kAudioFormatLinearPCM
    ) throws {
        var settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if formatID == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw AudioIngestError.empty(url)
        }
        buffer.frameLength = frames
        for channel in 0..<Int(file.processingFormat.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frames) {
                samples[frame] = Float(sin(2 * .pi * frequency * Double(frame) / sampleRate) * 0.4)
            }
        }
        try file.write(from: buffer)
    }
}

/// A shared, deliberately awkward meeting: two channels, an edited segment, live notes anchored to
/// specific sentences, a note written before anybody spoke, pre-notes, a summary, actions, and an
/// apostrophe and a slash in the title so the slug and the JSON escaping both get exercised.
enum BundleFixture {
    static let start = Date(timeIntervalSince1970: 1_770_000_000)

    @discardableResult
    static func loadedMeeting(in store: MeetingStore, folder: String? = "Torch0") throws -> Meeting {
        let folderID = try folder.map { try store.folderNamedOrCreated($0).id }
        var meeting = Meeting(
            folderID: folderID,
            title: "Ma'agan Michael / Torch0 sync",
            state: .complete,
            calendarEventID: "event-torch0-weekly",
            scheduledStart: start,
            scheduledEnd: start.addingTimeInterval(1_800),
            startedAt: start.addingTimeInterval(60),
            endedAt: start.addingTimeInterval(1_500),
            attendees: [
                Attendee(name: "Will Smith", email: "will@example.com"),
                Attendee(name: "Sofia Nunes"),
            ],
            preNotes: "- ask about the ptychography run\n- budget?",
            // The write-up carries the actions, as task list items — and the legacy `actions` column
            // is *also* populated, which is exactly the state the v6 migration leaves a real store
            // in: the column is kept as a safety net and nothing reads it any more. Anything that
            // still did would print this meeting's two actions twice.
            summary: """
                # Decisions

                Ship Torch0 on Friday.

                ## Actions

                - [ ] Send the ptychography numbers
                - [x] Book the follow-up
                """,
            actions: [
                Action(text: "Send the ptychography numbers", owner: "Sofia", due: "end of week", done: false),
                Action(text: "Book the follow-up", done: true),
            ],
            source: .recorded
        )
        meeting = try store.createMeeting(meeting)

        try store.insertSegments([
            TranscriptSegment(meetingID: meeting.id, channel: .mic, tStartMs: 0, tEndMs: 4_000,
                              text: "morning — shall we start with the ptychography run", pass: .final),
            TranscriptSegment(meetingID: meeting.id, channel: .system, tStartMs: 4_500, tEndMs: 9_000,
                              text: "yes, the numbers came back better than Tuesday", pass: .final),
            TranscriptSegment(meetingID: meeting.id, channel: .mic, tStartMs: 9_500, tEndMs: 14_000,
                              text: "then we ship Torch0 on Friday", pass: .final, edited: true),
        ])

        // A note before any speech (anchor falls back to the first segment), one mid-conversation.
        try store.addNote(meetingID: meeting.id, tOffsetMs: 0, text: "starting late again")
        try store.addNote(meetingID: meeting.id, tOffsetMs: 6_000, text: "better than Tuesday — get the exact figure")
        try store.addNote(meetingID: meeting.id, tOffsetMs: 12_000, text: "Friday ship confirmed")
        return try #require(try store.meeting(id: meeting.id))
    }

    /// Two 16 kHz mono WAVs, so `--with-audio` has something real to carry.
    static func writeAudio(for meetingID: String, under root: URL) throws {
        let directory = root.appendingPathComponent(meetingID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, name) in ["mic.wav", "system.wav"].enumerated() {
            try AudioFixture.write(
                to: directory.appendingPathComponent(name),
                seconds: 0.25,
                frequency: 220 * Double(index + 1),
                sampleRate: 16_000,
                channels: 1
            )
        }
    }

    /// Every file under `url`, as paths relative to it, sorted.
    static func tree(_ url: URL) -> [String] {
        let base = url.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(atPath: base)
        var files: [String] = []
        while let entry = enumerator?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: base + "/" + entry, isDirectory: &isDirectory)
            if !isDirectory.boolValue { files.append(entry) }
        }
        return files.sorted()
    }
}

/// The headline claim about the bundle format: it round-trips exactly. Everything else in
/// import and export is downstream of this being true.
@Suite final class BundleRoundTripTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    /// export → import → export produces byte-identical files, audio included.
    ///
    /// The export date is pinned so `manifest.json` is comparable too; in a real pair of exports
    /// that one field is the only thing allowed to differ.
    @Test func exportImportExportIsByteIdentical() throws {
        let exportedAt = Date(timeIntervalSince1970: 1_770_100_000)
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        try BundleFixture.writeAudio(for: meeting.id, under: audioRoot)

        let first = try MeetingBundle.export(
            meeting, store: store, to: directory.appendingPathComponent("out1", isDirectory: true),
            withAudio: true, exportedAt: exportedAt, audioRoot: audioRoot
        )

        // A second machine: a fresh store and a fresh audio root, exactly as a restore would be.
        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let restoredStore = try TestStore.open(elsewhere)
        let restoredAudio = elsewhere.appendingPathComponent("audio", isDirectory: true)
        let result = try MeetingBundle.restore(
            at: first, into: restoredStore, audioRoot: restoredAudio
        )

        let second = try MeetingBundle.export(
            result.meeting, store: restoredStore,
            to: elsewhere.appendingPathComponent("out2", isDirectory: true),
            withAudio: true, exportedAt: exportedAt, audioRoot: restoredAudio
        )

        #expect(first.lastPathComponent == second.lastPathComponent)
        #expect(BundleFixture.tree(first) == BundleFixture.tree(second))
        for file in BundleFixture.tree(first) {
            let a = try #require(FileManager.default.contents(atPath: first.appendingPathComponent(file).path))
            let b = try #require(FileManager.default.contents(atPath: second.appendingPathComponent(file).path))
            #expect(a == b, "\(file) differs between the two exports")
        }
        // Including the id: a restore onto a machine that has never seen this meeting keeps it.
        #expect(result.meeting.id == meeting.id)
        #expect(!result.idCollision)
        #expect(result.meeting.source == .recorded, "a clean restore is not an import of somebody else's meeting")
        #expect(result.meeting.importedFrom == nil)
    }

    /// The trap this format is built around. A note points at a segment id; segment ids are
    /// AUTOINCREMENT and are reassigned on import, so the bundle carries the *relationship* — the
    /// note's position in the transcript — and import rebuilds the id from it.
    @Test func noteAnchorsSurviveReassignedSegmentIds() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let originalAnchors = try store.notes(meetingID: meeting.id).map { note in
            (note.text, try store.segments(meetingID: meeting.id).first { $0.id == note.anchorSegmentID }?.text)
        }
        let bundle = try MeetingBundle.export(meeting, store: store, to: directory)

        // Import into the *same* store, which forces every segment to get a new id.
        let result = try MeetingBundle.restore(at: bundle, into: store)
        #expect(result.idCollision)

        let newSegments = try store.segments(meetingID: result.meeting.id)
        let oldSegments = try store.segments(meetingID: meeting.id)
        #expect(Set(newSegments.compactMap(\.id)).isDisjoint(with: Set(oldSegments.compactMap(\.id))))

        let restoredAnchors = try store.notes(meetingID: result.meeting.id).map { note in
            (note.text, newSegments.first { $0.id == note.anchorSegmentID }?.text)
        }
        #expect(restoredAnchors.map(\.0) == originalAnchors.map(\.0))
        #expect(restoredAnchors.map(\.1) == originalAnchors.map(\.1))
        #expect(restoredAnchors.allSatisfy { $0.1 != nil })
    }

    /// "A meeting with notes but no audio and no transcript is legal. Nothing in the
    /// schema or UI may assume a transcript exists."
    @Test func aMeetingWithNotesAndNoTranscriptRoundTrips() throws {
        let meeting = try store.createMeeting(Meeting(
            title: "Coffee with Sofia",
            state: .complete,
            startedAt: BundleFixture.start,
            preNotes: "ask about the Airbus timeline"
        ))
        try store.addNote(meetingID: meeting.id, tOffsetMs: 0, text: "no recording — she asked me not to")

        let bundle = try MeetingBundle.export(meeting, store: store, to: directory)
        let contents = try MeetingBundle.read(at: bundle)
        #expect(contents.segments.isEmpty)
        #expect(contents.notes.count == 1)
        #expect(contents.notes[0].anchorSegmentIndex == nil, "no transcript means no anchor, not anchor zero")
        #expect(contents.summary == nil, "a NULL summary writes no summary.md, so it comes back NULL")
        #expect(contents.actions == nil)

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let restoredStore = try TestStore.open(elsewhere)
        let result = try MeetingBundle.restore(at: bundle, into: restoredStore)
        let restored = try #require(try restoredStore.meeting(id: result.meeting.id))
        #expect(restored.summary == nil)
        #expect(restored.actions == nil)
        #expect(restored.preNotes == "ask about the Airbus timeline")
        #expect(try restoredStore.segments(meetingID: restored.id).isEmpty)
        #expect(try restoredStore.notes(meetingID: restored.id).map(\.text) == ["no recording — she asked me not to"])
    }

    /// Folder ids are machine-local, so the bundle carries the name and the import resolves it.
    @Test func theFolderTravelsAsANameAndIsCreatedOnTheFarSide() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store, folder: "Torch0")
        let bundle = try MeetingBundle.export(meeting, store: store, to: directory)
        #expect(try MeetingBundle.read(at: bundle).meeting.folder == "Torch0")

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let restoredStore = try TestStore.open(elsewhere)
        let result = try MeetingBundle.restore(at: bundle, into: restoredStore)
        #expect(result.folderCreated == "Torch0")
        #expect(try restoredStore.folder(named: "Torch0")?.id == result.meeting.folderID)

        // A second bundle into the same folder reuses it rather than failing the unique index.
        let again = try MeetingBundle.restore(at: bundle, into: restoredStore)
        #expect(again.folderCreated == nil)
        #expect(try restoredStore.folders().count == 1)
    }

    @Test func withoutWithAudioTheBundleCarriesNoAudio() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        try BundleFixture.writeAudio(for: meeting.id, under: audioRoot)

        let bundle = try MeetingBundle.export(meeting, store: store, to: directory, audioRoot: audioRoot)
        #expect(try MeetingBundle.read(at: bundle).audio.isEmpty)
        #expect(!BundleFixture.tree(bundle).contains { $0.hasPrefix("audio/") })

        // And a re-export with audio into the same place replaces the bundle rather than merging.
        let withAudio = try MeetingBundle.export(
            meeting, store: store, to: directory, withAudio: true, audioRoot: audioRoot)
        #expect(withAudio == bundle)
        #expect(BundleFixture.tree(bundle).filter { $0.hasPrefix("audio/") } == ["audio/mic.wav", "audio/system.wav"])
    }

    @Test func theBundleNameIsTheMeetingsDayAndSlug() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let name = MeetingBundle.directoryName(for: meeting)
        #expect(name.hasSuffix("-maagan-michael-torch0-sync.meetingbundle"))
        #expect(name.hasPrefix(MeetingBundle.dayFormatter.string(from: try #require(meeting.sortDate))))

        // A meeting with no date at all is legal, and gets said so rather than given today's.
        let undated = Meeting(title: "Notes from somewhere", state: .complete)
        #expect(MeetingBundle.directoryName(for: undated) == "undated-notes-from-somewhere.meetingbundle")
    }

    @Test func aBundleFromTheFutureIsRefusedRatherThanPartlyRead() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let bundle = try MeetingBundle.export(meeting, store: store, to: directory)
        let manifest = bundle.appendingPathComponent(MeetingBundle.File.manifest)
        try Data(#"{"schemaVersion":99,"exportedAt":"2026-08-12T10:00:00Z","sourceMachine":"x"}"#.utf8)
            .write(to: manifest)

        #expect(throws: BundleError.unsupportedSchema(99)) {
            _ = try MeetingBundle.read(at: bundle)
        }
    }

    /// The bundle used to drop `transcript_issues`, which is wave 2's headline fix undone at the
    /// exact moment the data moves machines: a meeting whose mic channel failed silently arrived on
    /// the far side as an apparently whole transcript, and the receiving machine has no other way
    /// to find out that half the conversation is missing.
    @Test func transcriptIssuesTravelWithTheBundle() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let recordedAt = Date(timeIntervalSince1970: 1_770_050_000)
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .mic, kind: .capture,
            reason: ChannelAudit.noSignalReason(.mic), at: recordedAt))
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .system, kind: .transcription,
            reason: "system.wav is truncated", at: recordedAt))

        let exportedAt = Date(timeIntervalSince1970: 1_770_100_000)
        let first = try MeetingBundle.export(
            meeting, store: store, to: directory.appendingPathComponent("out1", isDirectory: true),
            exportedAt: exportedAt)
        #expect(BundleFixture.tree(first).contains(MeetingBundle.File.issues))

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let restoredStore = try TestStore.open(elsewhere)
        let result = try MeetingBundle.restore(at: first, into: restoredStore)

        let restored = try restoredStore.transcriptIssues(meetingID: result.meeting.id)
        #expect(restored.map(\.channel) == [.mic, .system])
        #expect(restored.map(\.kind) == [.capture, .transcription])
        #expect(restored[0].sentence.contains("your own voice was not captured"))
        #expect(restored.allSatisfy { $0.at == recordedAt })
        #expect(try restoredStore.meetingIDsWithTranscriptIssues() == [result.meeting.id])

        // And the round trip is still byte-exact with the extra file in it.
        let second = try MeetingBundle.export(
            result.meeting, store: restoredStore,
            to: elsewhere.appendingPathComponent("out2", isDirectory: true), exportedAt: exportedAt)
        #expect(BundleFixture.tree(first) == BundleFixture.tree(second))
        for file in BundleFixture.tree(first) {
            let a = try #require(FileManager.default.contents(atPath: first.appendingPathComponent(file).path))
            let b = try #require(FileManager.default.contents(atPath: second.appendingPathComponent(file).path))
            #expect(a == b, "\(file) differs between the two exports")
        }
    }

    /// A bundle written before the write-up became the record — a populated `actions.json` beside a
    /// `summary.md` with no task items in it — is what 0.1.2 exported, and it is the only shape the
    /// v6 migration can never reach: that migration runs once per store at upgrade time and never
    /// revisits a row imported afterwards. Writing `actions.json` straight into the column left the
    /// actions where the app, `meetings show` and `actions list` have all stopped looking.
    @Test func aPreV6BundlesActionsLandInTheWriteUp() throws {
        let meeting = try store.createMeeting(Meeting(
            title: "Torch0 sync",
            state: .complete,
            startedAt: BundleFixture.start,
            summary: "# Decisions\n\nShip Torch0 on Friday."  // No task items: 0.1.2 kept them apart.
        ))
        let bundle = try MeetingBundle.export(meeting, store: store, to: directory)
        #expect(!BundleFixture.tree(bundle).contains(MeetingBundle.File.actions),
                "this build derives actions.json from the write-up, which carries none")
        try Data(#"[{"text":"Send the numbers","owner":"Sofia","due":"Friday","done":false},"#
            .appending(#"{"text":"Book the follow-up","owner":null,"due":null,"done":true}]"#).utf8)
            .write(to: bundle.appendingPathComponent(MeetingBundle.File.actions))

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let restoredStore = try TestStore.open(elsewhere)
        let result = try MeetingBundle.restore(at: bundle, into: restoredStore)
        let restored = try #require(try restoredStore.meeting(id: result.meeting.id))

        let actions = MarkdownActions.parse(restored.summary ?? "")
        #expect(actions.map(\.text) == ["Send the numbers", "Book the follow-up"])
        #expect(actions.map(\.done) == [false, true])
        #expect(restored.summary?.hasPrefix("# Decisions\n\nShip Torch0 on Friday.") == true,
                "the write-up that was there is not rewritten, only added to")
        // The column is still kept, unchanged, for the reason the migration keeps it: it is the only
        // place `owner` and `due` survive, and nothing else can recover them.
        #expect(restored.actions?.map(\.owner) == ["Sofia", nil])
    }

    /// The same bundle with no write-up at all: the actions become one, and a meeting whose write-up
    /// is its action list is written up — the rule ``Meeting/setSummary(_:)`` states and the v6
    /// migration restates. A `ready` row carrying a write-up is a state the rest of the app does not
    /// expect to see.
    @Test func aPreV6BundleWithNoWriteUpGetsOneAndMovesOn() throws {
        let meeting = try store.createMeeting(Meeting(
            title: "Coffee with Sofia", state: .ready, startedAt: BundleFixture.start))
        let bundle = try MeetingBundle.export(meeting, store: store, to: directory)
        try Data(#"[{"text":"Send the numbers","owner":null,"due":null,"done":false}]"#.utf8)
            .write(to: bundle.appendingPathComponent(MeetingBundle.File.actions))

        let elsewhere = try TestStore.makeDirectory()
        defer { TestStore.remove(elsewhere) }
        let restoredStore = try TestStore.open(elsewhere)
        let result = try MeetingBundle.restore(at: bundle, into: restoredStore)
        let restored = try #require(try restoredStore.meeting(id: result.meeting.id))

        #expect(restored.summary == "## Actions\n\n- [ ] Send the numbers")
        #expect(restored.state == .complete)
    }

    /// `actions.json` is the write-up's task items, not the legacy column beside it. The column is
    /// never rewritten after v6, so exporting it produced a file contradicting the `summary.md` next
    /// to it the moment somebody edited their write-up in the app.
    @Test func theExportedActionsAreTheWriteUpsOwn() throws {
        var meeting = try BundleFixture.loadedMeeting(in: store)
        // The write-up is edited after the migration, exactly as the app lets the user do; the
        // column keeps saying what it said in 0.1.2.
        meeting = try store.updateMeeting(id: meeting.id) {
            $0.summary = "## Actions\n\n- [x] Send the ptychography numbers\n- [ ] Chase the invoice"
        }
        let bundle = try MeetingBundle.export(meeting, store: store, to: directory)
        let exported = try #require(try MeetingBundle.read(at: bundle).actions)
        #expect(exported.map(\.text) == ["Send the ptychography numbers", "Chase the invoice"])
        #expect(exported.map(\.done) == [true, false])
        #expect(meeting.actions?.map(\.text) == ["Send the ptychography numbers", "Book the follow-up"],
                "the column is untouched — it just stopped being what the bundle carries")
    }

    /// Absence stays absence: a whole transcript writes no `issues.json`, so every bundle this build
    /// produces for a healthy meeting is byte-identical to the ones the previous build produced.
    @Test func aWholeTranscriptWritesNoIssuesFile() throws {
        let meeting = try BundleFixture.loadedMeeting(in: store)
        let bundle = try MeetingBundle.export(meeting, store: store, to: directory)
        #expect(!BundleFixture.tree(bundle).contains(MeetingBundle.File.issues))
        #expect(try MeetingBundle.read(at: bundle).issues.isEmpty)
    }
}
