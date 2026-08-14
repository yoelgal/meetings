import AVFoundation
import Foundation
import Testing

@testable import MeetingsCore

/// `meetings create` — the second, agent-driven import path. The thing under test as much
/// as the happy path is what it *refuses* to work out for itself.
@Suite final class ImportCreateTests {
    let directory: URL
    let store: MeetingStore
    let audioRoot: URL

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
        audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
    }

    deinit { TestStore.remove(directory) }

    /// "Audio absent means it lands at `complete` immediately."
    @Test func withoutAudioTheMeetingIsCompleteStraightAway() throws {
        let result = try MeetingCreate.create(
            MeetingCreate.Request(
                title: "Mater-AI intro",
                date: BundleFixture.start,
                duration: 45 * 60,
                folderName: "Torch0",
                attendees: MeetingCreate.attendees(from: "Will Smith,Sofia Nunes"),
                summary: "They want a pilot in Q4.",
                source: .imported,
                importedFrom: "nov4-notes.md"
            ),
            store: store, audioRoot: audioRoot
        )

        #expect(result.meeting.state == .complete)
        #expect(result.meeting.startedAt == BundleFixture.start)
        #expect(result.meeting.endedAt == BundleFixture.start.addingTimeInterval(2_700))
        #expect(result.meeting.scheduledStart == nil, "nothing was scheduled — this is a record of what happened")
        #expect(result.meeting.source == .imported)
        #expect(result.meeting.importedFrom == "nov4-notes.md")
        #expect(try store.folder(named: "Torch0")?.id == result.meeting.folderID)
        #expect(result.audioFile == nil)

        // Attendee names reach the recogniser's vocabulary, guarded as required.
        let terms = try store.allVocabularyTerms().map(\.term)
        #expect(terms.contains("Will Smith"))
        #expect(terms.contains("Smith"))
        #expect(!terms.contains("Will"), "a bare first name is exactly what the guard exists to stop")
    }

    /// "Audio present means the meeting enters `transcribing` and joins the batch queue."
    /// And the queue is the store, so the state *is* the enqueue.
    @Test func withAudioTheMeetingIsTranscribingAndTheFileIsWhereTheBatchPassLooks() throws {
        // An actual m4a at 44.1 kHz stereo — a voice memo, in other words, and nothing like what
        // the batch pass wants.
        let source = directory.appendingPathComponent("voice-memo.m4a")
        try AudioFixture.write(
            to: source, seconds: 0.5, frequency: 440, sampleRate: 44_100, channels: 2,
            formatID: kAudioFormatMPEG4AAC
        )

        let result = try MeetingCreate.create(
            MeetingCreate.Request(title: "Nov 4 call", date: BundleFixture.start, audio: source),
            store: store, audioRoot: audioRoot
        )

        #expect(result.meeting.state == .transcribing)
        let installed = try #require(result.audioFile)
        #expect(installed.lastPathComponent == "mic.wav")
        #expect(installed.deletingLastPathComponent().lastPathComponent == result.meeting.id)
        #expect(result.meeting.audioPath == installed.deletingLastPathComponent().path)

        // 16 kHz mono, which is what `TranscriptionService` hands Parakeet without resampling.
        let converted = try AVAudioFile(forReading: installed)
        #expect(converted.fileFormat.sampleRate == 16_000)
        #expect(converted.fileFormat.channelCount == 1)
        #expect(converted.length > 6_000, "half a second at 16 kHz is 8 000 frames, give or take the filter tail")

        // And the store, being the queue, already reports it as pending work.
        #expect(try store.meetings(state: .transcribing).map(\.id) == [result.meeting.id])
    }

    /// A file AVFoundation cannot read must fail the create, not leave a meeting that will sit at
    /// `transcribing` forever waiting for audio that never arrives.
    @Test func unreadableAudioLeavesNoMeetingBehind() throws {
        let source = directory.appendingPathComponent("notes.txt")
        try Data("this is not audio".utf8).write(to: source)

        #expect(throws: (any Error).self) {
            try MeetingCreate.create(
                MeetingCreate.Request(title: "Broken", date: BundleFixture.start, audio: source),
                store: store, audioRoot: audioRoot
            )
        }
        #expect(try store.allMeetings().isEmpty)
    }

    /// A transcript with real timings comes in verbatim — the shape a bundle's transcript.json has,
    /// which is what an agent can also write by hand.
    @Test func aJSONTranscriptFileKeepsItsChannelsAndTimings() throws {
        let json = Data("""
            [
              {"channel": "mic", "startMs": 0, "endMs": 3000, "text": "how did the run go"},
              {"channel": "system", "startMs": 3200, "endMs": 8000, "text": "better than Tuesday"}
            ]
            """.utf8)
        let drafts = try TranscriptDraft.parse(json, durationMs: 45 * 60_000)
        let result = try MeetingCreate.create(
            MeetingCreate.Request(title: "Nov 4 call", date: BundleFixture.start, transcript: drafts),
            store: store, audioRoot: audioRoot
        )

        let segments = try store.segments(meetingID: result.meeting.id)
        #expect(segments.map(\.channel) == [.mic, .system])
        #expect(segments.map(\.tStartMs) == [0, 3_200])
        #expect(segments.map(\.pass) == [.final, .final])
        #expect(result.meeting.state == .complete, "a transcript is not audio; there is nothing left to transcribe")
    }

    /// Plain prose has no timings, and the CLI will not invent one per line. One honest segment.
    @Test func aPlainTextTranscriptBecomesOneSegmentRatherThanInventedTimestamps() throws {
        let text = Data("Will: how did the run go?\nSofia: better than Tuesday.\n".utf8)
        let drafts = try TranscriptDraft.parse(text, durationMs: 45 * 60_000)
        #expect(drafts.count == 1)
        #expect(drafts[0].startMs == 0)
        #expect(drafts[0].endMs == 2_700_000)
        #expect(drafts[0].channel == .mic)
        #expect(drafts[0].text.contains("better than Tuesday"))
        #expect(try TranscriptDraft.parse(Data("   \n".utf8), durationMs: nil).isEmpty)
    }

    @Test func notesWithoutAudioOrTranscriptAreLegal() throws {
        let result = try MeetingCreate.create(
            MeetingCreate.Request(
                title: "Coffee with Sofia",
                date: BundleFixture.start,
                preNotes: "ask about the Airbus timeline"
            ),
            store: store, audioRoot: audioRoot
        )
        #expect(result.meeting.state == .complete)
        #expect(result.segmentCount == 0)
        #expect(try store.segments(meetingID: result.meeting.id).isEmpty)
        #expect(result.meeting.preNotes == "ask about the Airbus timeline")
    }

    // MARK: - The parsers, which are the whole "nothing is inferred" surface

    @Test func durationsParseTheDocumentedForms() {
        #expect(MeetingCreate.duration(from: "45m") == 2_700)
        #expect(MeetingCreate.duration(from: "1h30m") == 5_400)
        #expect(MeetingCreate.duration(from: "1.5h") == 5_400)
        #expect(MeetingCreate.duration(from: "90") == 5_400, "a bare number is minutes")
        #expect(MeetingCreate.duration(from: "2700s") == 2_700)
        #expect(MeetingCreate.duration(from: "1h30") == nil, "a trailing number with no unit is a guess")
        #expect(MeetingCreate.duration(from: "about an hour") == nil)
    }

    @Test func datesParseOnlyExplicitForms() throws {
        // The documented example. ISO8601FormatStyle rejects it — it wants the seconds — so this is
        // the case most likely to be broken and least likely to be noticed.
        #expect(MeetingCreate.date(from: "2025-11-04T14:00Z") == Date(timeIntervalSince1970: 1_762_264_800))
        #expect(MeetingCreate.date(from: "2025-11-04T14:00:00Z") == Date(timeIntervalSince1970: 1_762_264_800))
        #expect(MeetingCreate.date(from: "2025-11-04T15:00+01:00") == Date(timeIntervalSince1970: 1_762_264_800))
        #expect(MeetingCreate.date(from: "2025-11-04") != nil)
        #expect(MeetingCreate.date(from: "2025-11-04T14:00") != nil)
        // `--since 7d` is a search window. As a meeting's date it would be a fact we made up.
        #expect(MeetingCreate.date(from: "7d") == nil)
        #expect(MeetingCreate.date(from: "yesterday") == nil)
        #expect(MeetingCreate.date(from: "") == nil)
    }

    @Test func attendeesSplitOnCommasAndNothingElse() {
        let people = MeetingCreate.attendees(from: "Will Smith, sofia@example.com, Ana Pires <ana@example.com>, ")
        #expect(people == [
            Attendee(name: "Will Smith"),
            Attendee(email: "sofia@example.com"),
            Attendee(name: "Ana Pires", email: "ana@example.com"),
        ])
    }
}
