import CryptoKit
import EventKit
import Foundation

/// Apple Calendar through EventKit. A Google Calendar subscribed into Apple Calendar reads
/// through here too, which is the whole point of the decision — one permission, no OAuth.
///
/// Nothing in this type ever prompts. `requestAccess()` is explicit and is only called from
/// onboarding or the Settings permissions row, so a CLI invocation can never pop a dialog.
public struct EventKitCalendarSource: CalendarSource {
    public init() {}

    /// A fresh store per call. `EKEventStore` is not `Sendable`, and the alternative — holding one
    /// across actor boundaries — buys nothing: we read a list of events a few times a minute.
    private func makeStore() -> EKEventStore { EKEventStore() }

    public func authorizationStatus() -> CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .authorized
        case .denied: .denied
        case .restricted: .restricted
        // `writeOnly` cannot read events, which for our purposes is the same as no access.
        case .notDetermined, .writeOnly: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Prompts. Only ever called from a place where the user asked for it.
    @discardableResult
    public func requestAccess() async throws -> Bool {
        try await makeStore().requestFullAccessToEvents()
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        guard authorizationStatus() == .authorized else { return [] }
        let store = makeStore()
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .map(Self.convert)
            .sorted { $0.start < $1.start }
    }

    public func event(withIdentifier id: String) async throws -> CalendarEvent? {
        guard authorizationStatus() == .authorized else { return nil }
        return makeStore().event(withIdentifier: id).map(Self.convert)
    }

    // MARK: -

    /// EventKit hands attendees back as `mailto:` URLs. Anything else (a room, a resource) has no
    /// address worth recording.
    static func email(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = url.absoluteString.dropFirst("mailto:".count)
        return address.isEmpty ? nil : String(address).removingPercentEncoding
    }

    /// A stable identity for an event, and **never a random one**.
    ///
    /// `eventIdentifier` is nil more often than it looks: events from some subscribed and CalDAV
    /// calendars simply do not carry one. This used to fall back to a fresh `UUID`, which was
    /// harmless while nothing wrote rows — an event with a throwaway id was displayed and forgotten.
    /// The moment `CalendarSync` began materialising a row per event, that fallback became a row
    /// factory: every poll minted a new identity for the same meeting, so the same call was inserted
    /// again every few seconds. It reached 3,779 rows for one event before it was caught.
    ///
    /// So: the event's own identifier, else the calendar item's, else a digest of the things that
    /// make this event that event. The digest is SHA-256 rather than `hashValue`, whose seed changes
    /// per process and would therefore be a slower version of the same bug.
    static func identity(_ event: EKEvent) -> String {
        if let id = event.eventIdentifier, !id.isEmpty { return id }
        if !event.calendarItemIdentifier.isEmpty { return event.calendarItemIdentifier }
        let fingerprint = [
            event.calendar?.calendarIdentifier ?? "",
            event.title ?? "",
            String(event.startDate.timeIntervalSince1970),
            String(event.endDate.timeIntervalSince1970),
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func convert(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: identity(event),
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            attendees: (event.attendees ?? []).map { participant in
                Attendee(
                    name: participant.name,
                    email: Self.email(from: participant.url)
                )
            },
            calendarName: event.calendar?.title ?? "",
            videoLink: VideoLink.find(in: [event.notes, event.location, event.url?.absoluteString]),
            notes: event.notes
        )
    }
}

/// Finding the video link is what decides whether the menu bar nudges you and
/// whether an event is a meeting at all (``CalendarEvent/isMeeting``), so the sniffing rule lives in
/// one place rather than being re-guessed per call site.
public enum VideoLink {
    /// Every provider we can name. The list is long on purpose: a host missing from it is not a
    /// cosmetic gap any more, it is a real meeting silently absent from Upcoming.
    static let hosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "around.co", "riverside.fm",
        "gotomeeting.com", "gotomeet.me", "meet.goto.com", "bluejeans.com", "chime.aws",
        "discord.gg", "discord.com", "slack.com", "skype.com", "lifesize.com",
        "lifesizecloud.com", "8x8.vc", "dialpad.com", "butter.us", "gather.town",
        "tuple.app", "pop.com", "vowel.com", "ringcentral.com",
        // Zoho hangs a dozen unrelated products off zoho.com, so only the meeting subdomain counts —
        // a link to a Zoho CRM record in an event's notes does not make that event a call.
        "meeting.zoho.com", "meeting.zoho.eu", "meeting.zoho.in",
    ]

    public static func find(in candidates: [String?]) -> URL? {
        for text in candidates.compactMap({ $0 }) {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(text.startIndex..., in: text)
            let matches = detector?.matches(in: text, range: range) ?? []
            for match in matches {
                guard let url = match.url, let host = url.host()?.lowercased() else { continue }
                // Exact host or a subdomain of one, never a substring: `zoom.us.attacker.com` ends
                // with the right characters and belongs to somebody else entirely.
                if hosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return url }
            }
        }
        return nil
    }
}
