import Foundation
import GRDB

/// The `folders` table. `parentID` is always nil in v1 — the column exists so nesting becomes a UI
/// change rather than a migration.
public struct Folder: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folders"

    public var id: String
    public var name: String
    public var parentID: String?
    public var sortOrder: Int
    public var createdAt: Date

    public enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentID = "parent_id"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .secondsSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        parentID: String? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
