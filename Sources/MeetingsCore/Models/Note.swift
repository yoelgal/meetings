import Foundation
import GRDB

/// The `notes` table — what you typed *during* the meeting. `anchorSegmentID` is the transcript
/// position at the instant you wrote it, and it is nullable because a note can legitimately land
/// before anyone has said anything, or on a meeting with no transcript at all.
public struct Note: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "notes"

    public var id: Int64?
    public var meetingID: String
    public var tOffsetMs: Int
    public var anchorSegmentID: Int64?
    public var text: String

    public enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case tOffsetMs = "t_offset_ms"
        case anchorSegmentID = "anchor_segment_id"
        case text
    }

    public init(
        id: Int64? = nil,
        meetingID: String,
        tOffsetMs: Int,
        anchorSegmentID: Int64? = nil,
        text: String
    ) {
        self.id = id
        self.meetingID = meetingID
        self.tOffsetMs = tOffsetMs
        self.anchorSegmentID = anchorSegmentID
        self.text = text
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
