import Foundation
import GRDB

/// The `vocabulary` table. A term is global (`folderID == nil`) or scoped to one folder — an Airbus
/// folder and a Torch0 folder have different jargon, and pushing all of it into every meeting is
/// how you get false firing.
///
/// `enabled` is a soft-disable rather than a delete so a badly auto-seeded term stays visible in
/// the UI instead of quietly coming back the next time attendees are seeded.
public struct VocabularyTerm: Codable, Identifiable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "vocabulary"

    public var id: Int64?
    public var term: String
    public var folderID: String?
    public var threshold: Double?
    public var source: VocabSource
    public var enabled: Bool

    public enum CodingKeys: String, CodingKey {
        case id
        case term
        case folderID = "folder_id"
        case threshold
        case source
        case enabled
    }

    public init(
        id: Int64? = nil,
        term: String,
        folderID: String? = nil,
        threshold: Double? = nil,
        source: VocabSource = .manual,
        enabled: Bool = true
    ) {
        self.id = id
        self.term = term
        self.folderID = folderID
        self.threshold = threshold
        self.source = source
        self.enabled = enabled
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
