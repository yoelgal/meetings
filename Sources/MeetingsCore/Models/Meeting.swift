import Foundation
import GRDB

/// A person on the calendar event. Both fields are optional because EventKit hands out plenty of
/// participants with an email and no display name, and the occasional one with neither.
public struct Attendee: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String? = nil) {
        self.name = name
        self.email = email
    }
}

/// One agent-written action item. `due` stays a free string: the agent writes what the meeting
/// actually said ("end of week"), and inventing a Date for that would be a lie with a timezone.
public struct Action: Codable, Hashable, Sendable {
    public var text: String
    public var owner: String?
    public var due: String?
    public var done: Bool

    public init(text: String, owner: String? = nil, due: String? = nil, done: Bool = false) {
        self.text = text
        self.owner = owner
        self.due = due
        self.done = done
    }
}

/// The `meetings` table. `preNotes`, `summary` and `actions` are deliberately three fields rather than
/// one document so `meetings actions list --open` never has to parse prose.
///
/// `attendees` and `actions` are JSON TEXT columns in SQLite, but nothing above this type ever sees
/// the JSON — GRDB encodes and decodes the nested values for us, so the store's surface is typed.
public struct Meeting: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "meetings"

    public var id: String
    public var folderID: String?
    public var title: String
    public var state: MeetingState
    public var calendarEventID: String?
    public var scheduledStart: Date?
    public var scheduledEnd: Date?
    public var startedAt: Date?
    public var endedAt: Date?
    public var attendees: [Attendee]
    public var preNotes: String
    public var summary: String?
    public var actions: [Action]?
    public var audioPath: String?
    public var audioPurgedAt: Date?
    public var source: MeetingSource
    public var importedFrom: String?

    /// Swift is camelCase, SQL is snake_case, and the mapping is written out rather than derived so
    /// a rename in either language fails loudly instead of silently reading a column that isn't there.
    public enum CodingKeys: String, CodingKey {
        case id
        case folderID = "folder_id"
        case title
        case state
        case calendarEventID = "calendar_event_id"
        case scheduledStart = "scheduled_start"
        case scheduledEnd = "scheduled_end"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case attendees
        case preNotes = "pre_notes"
        case summary
        case actions
        case audioPath = "audio_path"
        case audioPurgedAt = "audio_purged_at"
        case source
        case importedFrom = "imported_from"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .secondsSince1970
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public init(
        id: String = UUID().uuidString,
        folderID: String? = nil,
        title: String,
        state: MeetingState = .scheduled,
        calendarEventID: String? = nil,
        scheduledStart: Date? = nil,
        scheduledEnd: Date? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        attendees: [Attendee] = [],
        preNotes: String = "",
        summary: String? = nil,
        actions: [Action]? = nil,
        audioPath: String? = nil,
        audioPurgedAt: Date? = nil,
        source: MeetingSource = .recorded,
        importedFrom: String? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.title = title
        self.state = state
        self.calendarEventID = calendarEventID
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attendees = attendees
        self.preNotes = preNotes
        self.summary = summary
        self.actions = actions
        self.audioPath = audioPath
        self.audioPurgedAt = audioPurgedAt
        self.source = source
        self.importedFrom = importedFrom
    }

    /// The one date every list sorts on: when it actually happened, falling back to when it was
    /// meant to. Kept here so the SQL `coalesce(started_at, scheduled_start)` and the Swift side
    /// can never drift apart.
    public var sortDate: Date? { startedAt ?? scheduledStart }

    /// Write the summary and move the meeting with it.
    ///
    /// The last two states are defined by whether a summary exists, so the state follows the
    /// field rather than being set separately. Only these two states move: a summary arriving on a
    /// meeting that is still recording says nothing about whether the recording has finished, and
    /// claiming otherwise would be a lie the app's detail view would then render.
    ///
    /// It lives on the model rather than in `meetings summary set`, because the app can now clear a
    /// summary too — and a second copy of this rule is how a meeting cleared in the window ends up
    /// in a different state from one cleared at the command line.
    ///
    /// Absent and empty are the same state: a write-up that is only whitespace stores nothing, so no
    /// reader has to tell "the user deleted it" from "nobody has written one yet" — there is no
    /// difference, and a meeting cannot sit at `complete` with a blank write-up on it.
    ///
    /// Anything else is stored exactly as given, deliberately. The app's editor autosaves while the
    /// user types and then reads the field back to see whether somebody else wrote it; a store that
    /// quietly trimmed the newline they had just typed would hand that editor a value it did not
    /// write, which it would report as a conflict against itself.
    public mutating func setSummary(_ markdown: String?) {
        let markdown = markdown ?? ""
        let blank = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        summary = blank ? nil : markdown
        switch (state, blank) {
        case (.ready, false): state = .complete
        case (.complete, true): state = .ready
        default: break
        }
    }
}
