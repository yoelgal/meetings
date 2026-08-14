import Foundation
import GRDB

/// The `transcript_segments` table. Offsets are milliseconds from `started_at`, never wall clock —
/// a meeting that starts late still has notes anchored to the right words.
///
/// The table is AUTOINCREMENT so ids are never reused: notes hold onto segment ids, and a recycled
/// id would silently move a note onto a sentence nobody said.
public struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transcript_segments"

    public var id: Int64?
    public var meetingID: String
    public var channel: Channel
    public var tStartMs: Int
    public var tEndMs: Int
    public var text: String
    public var pass: Pass
    /// Manually corrected. A re-transcription preserves these verbatim.
    public var edited: Bool

    public enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case channel
        case tStartMs = "t_start_ms"
        case tEndMs = "t_end_ms"
        case text
        case pass
        case edited
    }

    public init(
        id: Int64? = nil,
        meetingID: String,
        channel: Channel,
        tStartMs: Int,
        tEndMs: Int,
        text: String,
        pass: Pass,
        edited: Bool = false
    ) {
        self.id = id
        self.meetingID = meetingID
        self.channel = channel
        self.tStartMs = tStartMs
        self.tEndMs = tEndMs
        self.text = text
        self.pass = pass
        self.edited = edited
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public func contains(offsetMs: Int) -> Bool {
        offsetMs >= tStartMs && offsetMs <= tEndMs
    }
}
