import Foundation
import GRDB

/// A channel of a meeting whose batch pass failed, and why.
///
/// This exists because the alternative is silence. `runBatchPass` transcribes two files; if one of
/// them is unreadable the other still produces a perfectly good half-transcript, and without a
/// record of the failure that half-transcript is indistinguishable from a complete one — the meeting
/// sits at `ready`, the app shows a transcript, and the missing side is only noticed weeks later by
/// someone reading a summary that quotes nobody.
public struct TranscriptIssue: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcript_issues"

    /// Which half of the pipeline let the channel down. They are not interchangeable and must not
    /// share a row: a transcription failure is cleared by a re-run that finally reads the file, and
    /// a capture failure never is — re-transcribing a silent WAV does not put the speech back.
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// The batch pass could not read or decode the channel's audio.
        case transcription
        /// The audio itself is not there: the device handed the recorder digital silence, or the
        /// track ended up empty.
        case capture
        /// The transcript is complete, but the custom vocabulary pass over it did not run — the CTC
        /// model would not load, or a correction could not be put back on the clock. The jargon may
        /// be mangled, and the whole point is that nobody can see that by reading the
        /// transcript. Cleared by a re-run that finally manages it.
        case vocabulary
    }

    public var meetingID: String
    public var channel: Channel
    public var kind: Kind
    /// What went wrong, in the engine's own words. Shown to the user, so it is a sentence rather
    /// than a code.
    public var reason: String
    public var at: Date

    public enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case channel
        case kind
        case reason
        case at
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .secondsSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public init(
        meetingID: String,
        channel: Channel,
        kind: Kind = .transcription,
        reason: String,
        at: Date = Date()
    ) {
        self.meetingID = meetingID
        self.channel = channel
        self.kind = kind
        self.reason = reason
        self.at = at
    }

    /// One line, for `meetings show` and the detail view's banner. The lead-in names what actually
    /// happened: a channel nobody could transcribe and a channel that was never recorded are two
    /// different sentences to the person reading them.
    public var sentence: String {
        switch kind {
        case .transcription: "The \(channel.rawValue) channel could not be transcribed: \(reason)"
        case .capture: "The \(channel.rawValue) channel is missing audio: \(reason)"
        case .vocabulary:
            "Custom vocabulary did not run on the \(channel.rawValue) channel: \(reason)"
        }
    }
}

extension MeetingStore {
    /// Records — or replaces — the verdict for one channel of one meeting.
    public func recordTranscriptIssue(_ issue: TranscriptIssue) throws {
        try dbPool.write { db in
            try issue.upsert(db)
        }
        StoreChange.post(storePath: dbPool.path, meetingID: issue.meetingID)
    }

    /// Called for a channel the batch pass finally managed to read, whether or not it had failed
    /// before: a re-run that succeeds has to take its own warning down with it.
    ///
    /// **Only the transcriber's verdict**, which is why the kind is named rather than assumed. A
    /// capture failure is not the transcriber's to clear — the batch pass reads a full-length silent
    /// WAV perfectly well and reports success, and clearing on that success is precisely how "your
    /// microphone recorded nothing" disappeared from a meeting that then sat at `ready` looking
    /// complete. The vocabulary verdict *is* the transcriber's, and the same pass clears it.
    @discardableResult
    public func clearTranscriptIssue(
        meetingID: String, channel: Channel, kind: TranscriptIssue.Kind = .transcription
    ) throws -> Bool {
        let cleared = try dbPool.write { db -> Bool in
            try db.execute(
                sql: "DELETE FROM transcript_issues WHERE meeting_id = ? AND channel = ? AND kind = ?",
                arguments: [meetingID, channel.rawValue, kind.rawValue]
            )
            return db.changesCount > 0
        }
        if cleared { StoreChange.post(storePath: dbPool.path, meetingID: meetingID) }
        return cleared
    }

    /// Empty for the overwhelming majority of meetings, which is the point: a non-empty result is
    /// the UI's cue to say the transcript is incomplete.
    public func transcriptIssues(meetingID: String) throws -> [TranscriptIssue] {
        try dbPool.read { db in
            try TranscriptIssue.fetchAll(db, sql: """
                SELECT * FROM transcript_issues WHERE meeting_id = ? ORDER BY channel ASC, kind ASC
                """, arguments: [meetingID])
        }
    }

    /// Every meeting carrying an unresolved transcript failure. The app's list and `meetings list`
    /// use it to mark those rows without a query per meeting.
    public func meetingIDsWithTranscriptIssues() throws -> Set<String> {
        try dbPool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT meeting_id FROM transcript_issues"))
        }
    }
}
