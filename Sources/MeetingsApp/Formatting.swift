import Foundation
import MeetingsCore

/// One place for every string the UI derives from a date or a duration. Scattering
/// `DateFormatter`s through the views is how "14:00" in the list becomes "2:00 PM" in the detail.
enum Format {
    /// "14:00" — locale's short time.
    static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// What a list row's metadata line leads with: "14:00" today, "Fri 15 Aug, 17:00" otherwise.
    ///
    /// A bare time is only unambiguous on the one day a bare time can mean. Everywhere else the row
    /// leaned entirely on its section header to say which day it was, and the headers that cover
    /// more than one day — Scheduled, Previous 7 Days, a whole month — cannot. Two meetings on
    /// different days read as two meetings on the same afternoon.
    static func rowDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeOfDay(date) }
        // Weekday and day-month: enough to place it without turning a quiet metadata line into a
        // full date. The year appears only when it is not this one, where leaving it off would lie.
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        let day = date.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .year(sameYear ? .omitted : .defaultDigits)
        )
        return "\(day), \(timeOfDay(date))"
    }

    /// "32 min", "1 hr 12 min". Nil for a meeting that has no measurable length yet, so callers
    /// leave the segment out rather than printing "0 min".
    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds >= 60 else { return nil }
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
        )
    }

    static func duration(from start: Date?, to end: Date?) -> String? {
        guard let start, let end else { return nil }
        return duration(end.timeIntervalSince(start))
    }

    /// "Today", "Yesterday", "Monday 10 August", "4 November 2025". Upcoming's day headers, where
    /// there are at most seven of them and each one is a different day you actually care about.
    static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        // Inside this year the year is noise; outside it, leaving it off is a lie.
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return day.formatted(
            .dateTime.weekday(.wide).day().month(.wide)
                .year(sameYear ? .omitted : .defaultDigits)
        )
    }

    /// The bucket a past meeting falls in, the way Notes buckets a note list: Today, Yesterday,
    /// Previous 7 Days, Previous 30 Days, then by month.
    ///
    /// A day header per row is not a grouping — it is the same list with a third more height. On a
    /// real week of meetings a per-day header fires on almost every row, which is what wave 2's
    /// list did. `order` sorts the buckets; it is not shown.
    /// Named, because the list reverses this one bucket and a bare `1` there is a number nobody can
    /// check against the function that produced it.
    static let scheduledBucket = 1

    static func bucket(for date: Date?, now: Date = Date()) -> (order: Int, label: String) {
        guard let date else { return (Int.max, "Undated") }
        let calendar = Calendar.current
        // Today first, whether or not it has happened yet: it is the day you are actually in, and a
        // week of scheduled meetings above it pushes this afternoon off the top of the list.
        //
        // Scheduled sat above Today until a list holding one meeting today and one in eleven days
        // showed them under two headers, the further one first, each row printing a bare time and
        // nothing to say which day it meant. The order is the fix here; the dates are `rowDate`.
        if calendar.isDateInToday(date) { return (0, "Today") }
        // Anything still ahead of us is not history and does not belong in a "previous" bucket.
        if date > now { return (scheduledBucket, "Scheduled") }
        if calendar.isDateInYesterday(date) { return (2, "Yesterday") }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 7 { return (3, "Previous 7 Days") }
        if days <= 30 { return (4, "Previous 30 Days") }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        // Months back from this one, so newer months sort first and every one of them sorts after
        // the five fixed buckets above.
        let months = calendar.dateComponents(
            [.month],
            from: calendar.dateInterval(of: .month, for: date)?.start ?? date,
            to: calendar.dateInterval(of: .month, for: now)?.start ?? now
        ).month ?? 1
        return (
            5 + max(1, months),
            date.formatted(.dateTime.month(.wide).year(sameYear ? .omitted : .defaultDigits))
        )
    }

    /// The one date format a detail pane's subtitle uses. Three panes were formatting the same slot
    /// three ways — `.complete` in two of them, `.abbreviated` in the third.
    static func detailDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// "12:34" / "1:02:33" — the elapsed clock on the recording HUD and the transcript gutter.
    /// Always at least mm:ss so the digits do not reflow as the meeting passes a minute.
    static func clock(milliseconds: Int) -> String {
        let total = max(0, milliseconds) / 1000
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// "3 days" — how long a meeting has been sitting at `ready` without a write-up.
    static func age(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .wide, maximumUnitCount: 1)
        )
    }

    /// The one quiet metadata line under a list row: "14:00 · 32 min", plus the state only when the
    /// state is news.
    ///
    /// A state is not news when the scope already says it — every row under Needs write-up needs a
    /// write-up — and it is not news when it is the resting state: "Written up" on the twelve
    /// finished meetings in a list is twelve repetitions of "nothing to do here". Wave 2's list put
    /// "Needs write-up" on screen four times over two rows.
    static func metadata(for meeting: Meeting, statedByScope: Bool = false, now: Date = Date()) -> String {
        var parts: [String] = []
        if let date = meeting.sortDate { parts.append(rowDate(date, now: now)) }
        if let length = duration(from: meeting.startedAt, to: meeting.endedAt)
            ?? duration(from: meeting.scheduledStart, to: meeting.scheduledEnd) {
            parts.append(length)
        }
        if !statedByScope, meeting.state != .complete { parts.append(meeting.state.label) }
        return parts.joined(separator: " · ")
    }
}

extension MeetingState {
    /// What a person calls this state. `ready` is never shown as "ready" — the whole point of that
    /// state is that something is still owed on it.
    var label: String {
        switch self {
        case .scheduled: "Scheduled"
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .ready: "Needs write-up"
        case .complete: "Written up"
        }
    }
}

extension Channel {
    var label: String {
        switch self {
        case .mic: "Microphone"
        case .system: "System audio"
        }
    }
}

extension Attendee {
    /// Falls back through name → email → a truthful placeholder. An attendee row that renders as an
    /// empty line looks like a bug in the list, not a gap in the calendar data.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let email, !email.isEmpty { return email }
        return "Unnamed attendee"
    }

    /// The email, but only when it is not already the display name.
    var secondaryLine: String? {
        guard let email, !email.isEmpty, email != displayName else { return nil }
        return email
    }
}
