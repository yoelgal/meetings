import Foundation
import MeetingsCore

/// The `--json` shapes are the agent-facing API, so they are written out here rather than encoded
/// straight off the GRDB records: the database's column names are free to change, this is not.
/// Optionals are omitted when nil, so a meeting with no summary has no `summary` key rather than a
/// null an agent has to special-case.

struct MeetingJSON: Encodable {
    let ref: String
    let title: String
    let state: String
    let folder: String?
    let scheduledStart: Date?
    let scheduledEnd: Date?
    let startedAt: Date?
    let endedAt: Date?
    let durationMs: Int?
    let attendees: [Attendee]
    let source: String
    let calendarEventId: String?
    let audioAvailable: Bool
    let audioPurgedAt: Date?
    /// Present only when a channel of this meeting failed to transcribe, which is the whole point:
    /// a key that is nearly always absent is one an agent can branch on without reading it every
    /// time, and its presence is the only signal that a `ready` meeting is carrying half a
    /// transcript rather than a whole one.
    let transcriptIssues: [TranscriptIssueJSON]?

    init(_ meeting: Meeting, folder: String?, transcriptIssues: [TranscriptIssue] = []) {
        self.ref = meeting.id
        self.title = meeting.title
        self.state = meeting.state.rawValue
        self.folder = folder
        self.scheduledStart = meeting.scheduledStart
        self.scheduledEnd = meeting.scheduledEnd
        self.startedAt = meeting.startedAt
        self.endedAt = meeting.endedAt
        self.durationMs = MeetingJSON.durationMs(meeting)
        self.attendees = meeting.attendees
        self.source = meeting.source.rawValue
        self.calendarEventId = meeting.calendarEventID
        self.audioAvailable = meeting.audioPath != nil && meeting.audioPurgedAt == nil
        self.audioPurgedAt = meeting.audioPurgedAt
        self.transcriptIssues = transcriptIssues.isEmpty ? nil : transcriptIssues.map(TranscriptIssueJSON.init)
    }

    /// What actually happened, falling back to what was scheduled. Nil when neither is known, which
    /// is legal for an imported row.
    static func durationMs(_ meeting: Meeting) -> Int? {
        if let start = meeting.startedAt, let end = meeting.endedAt {
            return Int(end.timeIntervalSince(start) * 1000)
        }
        if let start = meeting.scheduledStart, let end = meeting.scheduledEnd {
            return Int(end.timeIntervalSince(start) * 1000)
        }
        return nil
    }
}

/// One channel that could not be transcribed. `sentence` is the same line plain `show` prints, so
/// an agent relaying the problem to a human says what the app says.
struct TranscriptIssueJSON: Encodable {
    let channel: String
    /// Which half of the pipeline let the channel down — `capture` (the audio is not there and no
    /// re-run will put it back) or `transcription` (the audio is there and could not be read).
    /// They call for opposite advice, and without this an agent could only tell them apart by
    /// string-matching the English in `reason` — in the one output shape that exists so agents do
    /// not have to. The bundle shape has always carried it; this one did not.
    ///
    /// A kind this build does not know is still emitted as its raw string rather than being
    /// dropped or coerced: the set grows, and an agent reading a newer store must see the word.
    let kind: String
    let reason: String
    let sentence: String
    let at: Date

    init(_ issue: TranscriptIssue) {
        self.channel = issue.channel.rawValue
        self.kind = issue.kind.rawValue
        self.reason = issue.reason
        self.sentence = issue.sentence
        self.at = issue.at
    }
}

struct EventJSON: Encodable {
    let ref: String
    let title: String
    let start: Date
    let end: Date
    let durationMs: Int
    let attendees: [Attendee]
    let calendarName: String
    let videoLink: String?
    let notes: String?

    init(_ event: CalendarEvent) {
        self.ref = "cal:\(event.id)"
        self.title = event.title
        self.start = event.start
        self.end = event.end
        self.durationMs = Int(event.end.timeIntervalSince(event.start) * 1000)
        self.attendees = event.attendees
        self.calendarName = event.calendarName
        self.videoLink = event.videoLink?.absoluteString
        self.notes = event.notes
    }
}

struct SegmentJSON: Encodable {
    let id: Int64?
    let channel: String
    let speaker: String
    let startMs: Int
    let endMs: Int
    /// The same `m:ss` the plain output prints, so a timestamp an agent quotes back matches what a
    /// human saw.
    let start: String
    let text: String
    let pass: String
    let edited: Bool

    init(_ segment: TranscriptSegment) {
        self.id = segment.id
        self.channel = segment.channel.rawValue
        self.speaker = segment.channel.speakerLabel
        self.startMs = segment.tStartMs
        self.endMs = segment.tEndMs
        self.start = Format.offset(ms: segment.tStartMs)
        self.text = segment.text
        self.pass = segment.pass.rawValue
        self.edited = segment.edited
    }
}

/// What a write hands back: the resulting object, so an agent can chain without a second
/// read. The field the command changed is always present; the rest are omitted.
///
/// `materialised` says whether this write is what created the row from a `cal:` ref. An agent that
/// wrote against an event and got back a meeting id needs to know that a `scheduled` row now exists
/// where there was only a calendar entry.
struct WriteResultJSON: Encodable {
    let meeting: MeetingJSON
    var materialised: Bool
    var preNotes: String?
    var summary: String?
    var actions: [Action]?
    var note: NoteJSON?
    var segment: SegmentJSON?
    var vocabulary: VocabJSON?
    /// Present only when `--add-vocab` produced a term the recogniser would have ignored, which is
    /// the one case where the edit lands and the vocabulary half of it does not. Absent otherwise,
    /// so an agent that never asks for a term never sees the key.
    var vocabularyRefused: String?
    /// The fields of the request that were accepted and not stored — `["owner", "due"]` from
    /// `actions set`, whose markdown has nowhere to put either yet. Absent when everything sent was
    /// written, so an agent that sends neither never sees the key. Without it the response echoed
    /// back `"owner": null` and read as a successful write of what was sent, minus two fields.
    var droppedFields: [String]?

    init(_ meeting: Meeting, folder: String?, materialised: Bool) {
        self.meeting = MeetingJSON(meeting, folder: folder)
        self.materialised = materialised
    }
}

struct VocabJSON: Encodable {
    let id: Int64?
    let term: String
    /// The folder the term is scoped to, or null for a term that applies everywhere.
    let folder: String?
    let threshold: Double?
    let source: String
    let enabled: Bool

    init(_ term: VocabularyTerm, folder: String?) {
        self.id = term.id
        self.term = term.term
        self.folder = folder
        self.threshold = term.threshold
        self.source = term.source.rawValue
        self.enabled = term.enabled
    }
}

struct FolderJSON: Encodable {
    let name: String
    let id: String
    let meetings: Int
    let vocabulary: Int
}

/// One action item with the meeting it came from, because `actions list` flattens across meetings
/// and an action with no ref is not actionable.
struct ActionItemJSON: Encodable {
    let ref: String
    let meeting: String
    let folder: String?
    let text: String
    let owner: String?
    let due: String?
    let done: Bool

    init(_ action: Action, meeting: Meeting, folder: String?) {
        self.ref = meeting.id
        self.meeting = meeting.title
        self.folder = folder
        self.text = action.text
        self.owner = action.owner
        self.due = action.due
        self.done = action.done
    }

    /// **One rule: this is 0.1.2's synthesised encoding, written out by hand.** Every optional is
    /// omitted when it is nil, exactly as the synthesised `Encodable` omitted it, so nothing
    /// downstream sees a key appear or disappear that was not already doing both.
    ///
    /// **`owner` and `due` are the one exception**, and it is the loosening this shape exists for:
    /// the markdown became the record and cannot carry either, so both are *always* nil now, not
    /// nil for some actions. Omitting them would not vary a key per item — it would delete two keys
    /// from every payload the CLI has ever emitted, which is the shape change a reader notices. Nil
    /// `folder` is per item, an unfiled meeting among filed ones, and the key stays as it was.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ref, forKey: .ref)
        try container.encode(meeting, forKey: .meeting)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encode(text, forKey: .text)
        try container.encode(owner, forKey: .owner)
        try container.encode(due, forKey: .due)
        try container.encode(done, forKey: .done)
    }

    enum CodingKeys: String, CodingKey {
        case ref, meeting, folder, text, owner, due, done
    }
}

struct NoteJSON: Encodable {
    let id: Int64?
    let offsetMs: Int
    let at: String
    let anchorSegmentId: Int64?
    let text: String

    init(_ note: Note) {
        self.id = note.id
        self.offsetMs = note.tOffsetMs
        self.at = Format.offset(ms: note.tOffsetMs)
        self.anchorSegmentId = note.anchorSegmentID
        self.text = note.text
    }
}
