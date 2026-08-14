import Foundation

/// The two things a `<ref>` on the command line can be. An agent holds one of these
/// without needing to know or care which.
public enum MeetingRef: Hashable, Sendable, CustomStringConvertible {
    case id(String)
    case calendar(String)

    public init(_ raw: String) {
        if raw.hasPrefix("cal:") {
            self = .calendar(String(raw.dropFirst(4)))
        } else {
            self = .id(raw)
        }
    }

    public var description: String {
        switch self {
        case .id(let value): value
        case .calendar(let value): "cal:\(value)"
        }
    }
}

/// What a read resolved to. A calendar event with no row is a legitimate answer — `meetings show`
/// on an untouched event prints the event.
public enum ReadTarget: Sendable {
    case meeting(Meeting)
    case event(CalendarEvent)
}

public enum RefError: Error, CustomStringConvertible {
    case notFound(MeetingRef)
    case notImplemented

    public var description: String {
        switch self {
        case .notFound(let ref): "no meeting or calendar event for \(ref)"
        case .notImplemented: "reference resolution is not wired up yet"
        }
    }
}

/// One scored `--match` candidate. Never auto-resolved — the CLI returns every candidate over
/// threshold and lets the agent ask.
public struct MatchCandidate: Codable, Sendable {
    public var ref: String
    public var title: String
    public var start: Date?
    public var score: Double
    public var matchedOn: [String]

    public init(ref: String, title: String, start: Date?, score: Double, matchedOn: [String]) {
        self.ref = ref
        self.title = title
        self.start = start
        self.score = score
        self.matchedOn = matchedOn
    }
}
