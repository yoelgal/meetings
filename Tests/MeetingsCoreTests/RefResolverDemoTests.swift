import Foundation
import Testing

@testable import MeetingsCore

/// The acceptance run for W1-C, printed rather than only asserted: it drives `RefResolver` against
/// a real store under `$MEETINGS_HOME` and the fixture calendar at `$MEETINGS_CALENDAR_FIXTURE`,
/// and prints what actually happened at each step.
///
/// Enabled only when the environment names a throwaway home — a demo that wrote into the operator's
/// real store would be a bug, not a demonstration.
@Suite struct RefResolverDemoTests {
    static var configured: Bool {
        ProcessInfo.processInfo.environment["MEETINGS_HOME"] != nil && Paths.calendarFixtureURL != nil
    }

    @Test(.enabled(if: configured)) func acceptanceRun() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM HH:mm"
        func when(_ date: Date?) -> String { date.map(formatter.string(from:)) ?? "—" }

        _ = CalFixture.url
        try Paths.ensureDirectories()
        let store = try MeetingStore()
        let calendar = CalendarSources.resolved()
        let resolver = RefResolver(store: store, calendar: calendar)

        print("\n=== W1-C acceptance run ===")
        print("MEETINGS_HOME             \(Paths.root.path)")
        print("store                     \(Paths.databaseURL.path)")
        print("MEETINGS_CALENDAR_FIXTURE \(Paths.calendarFixtureURL?.path ?? "unset")")
        print("calendar source           \(type(of: calendar))")

        print("\n--- fixture events (the next fortnight) ---")
        for event in try await calendar.events(from: CalFixture.now.addingTimeInterval(-3 * 86_400),
                                               to: CalFixture.now.addingTimeInterval(14 * 86_400)) {
            let people = event.attendees.map { $0.name ?? $0.email ?? "?" }.joined(separator: ", ")
            print("  \(when(event.start))  \(event.title)")
            print("      cal:\(event.id)  [\(event.calendarName)]  \(event.videoLink?.host() ?? "no video link")")
            print("      \(people)")
        }

        print("\n--- 1. read a cal: ref with no row behind it ---")
        let ref = MeetingRef("cal:C41D9B02-WEEKLY-1000")
        switch try await resolver.resolveForRead(ref) {
        case .event(let event):
            print("  \(ref) -> calendar event \"\(event.title)\" at \(when(event.start)), no row exists")
        case .meeting(let meeting):
            Issue.record("expected the event, got row \(meeting.id)")
        }

        print("\n--- 2. write against the same ref materialises exactly one row ---")
        let first = try await resolver.resolveForWrite(ref)
        print("  row \(first.id)")
        print("  title \"\(first.title)\"  state \(first.state.rawValue)  calendar_event_id \(first.calendarEventID ?? "—")")
        print("  scheduled \(when(first.scheduledStart)) – \(when(first.scheduledEnd))")
        print("  attendees \(first.attendees.map { $0.name ?? $0.email ?? "?" }.joined(separator: ", "))")
        print("  rows in meetings: \(try store.allMeetings().count)")

        print("\n--- 3. a second write against the same ref reuses it ---")
        let second = try await resolver.resolveForWrite(ref)
        print("  row \(second.id)  same row: \(second.id == first.id)  rows in meetings: \(try store.allMeetings().count)")

        print("\n--- 4. a read now prefers the row over the event ---")
        if case .meeting(let meeting) = try await resolver.resolveForRead(ref) {
            print("  \(ref) -> row \(meeting.id) \"\(meeting.title)\"")
        }

        print("\n--- 5. vocabulary auto-seeded from the attendees ---")
        _ = try await resolver.resolveForWrite(MeetingRef("cal:A2C7B450-BOARD-1100"))
        _ = try await resolver.resolveForWrite(MeetingRef("cal:D0E4A116-AIRBUS-0930"))
        _ = try await resolver.resolveForWrite(MeetingRef("cal:35FA6D9C-MAAGAN-0800"))
        for term in try store.allVocabularyTerms() {
            print("  seeded   \(term.term)   (source \(term.source.rawValue), \(term.folderID == nil ? "global" : "folder"))")
        }
        let seeded = Set(try store.allVocabularyTerms().map(\.term))
        for (token, reason) in [
            ("Will", "bare first name, and \"will\" is a common word"),
            ("Green", "surname, but \"green\" is a common word"),
            ("Bo Li", "no token long enough to be distinctive"),
            ("Li", "under four characters"),
            ("Ravi", "single-token display names are never seeded on their own"),
        ] {
            print("  refused  \(token)\(String(repeating: " ", count: max(1, 8 - token.count)))— \(reason)"
                + (seeded.contains(token) ? "   *** BUT IT WAS SEEDED ***" : ""))
            #expect(!seeded.contains(token))
        }

        print("\n--- 6. --match returns every candidate, scored, never auto-resolved ---")
        for query in ["torch0 weekly", "sofia", "bergmann", "mater ai"] {
            print("  $ meetings upcoming --match \"\(query)\"")
            let candidates = try await resolver.match(query)
            if candidates.isEmpty { print("      (no candidate over \(Match.threshold))") }
            for candidate in candidates {
                print(String(format: "      %.2f  %-34s %-20s %@",
                             candidate.score,
                             (candidate.title as NSString).utf8String!,
                             (when(candidate.start) as NSString).utf8String!,
                             "\(candidate.ref)  matched on \(candidate.matchedOn.joined(separator: "+"))"))
            }
        }

        print("\n--- 7. concurrent writes against one untouched cal: ref ---")
        let contested = MeetingRef("cal:6A70E5D8-MATER-1400")
        // Two connection pools on one file, as the app and the CLI would be, and a gate so all
        // eight writers are released at the same instant instead of politely queueing.
        let cli = MeetingStore(dbPool: try MeetingsDatabase.open())
        let racers = (0..<8).map { RefResolver(store: $0.isMultiple(of: 2) ? store : cli, calendar: calendar) }
        let gate = Gate(count: racers.count)
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, racer) in racers.enumerated() {
                group.addTask {
                    await gate.arrive()
                    return (index, try await racer.resolveForWrite(contested).id)
                }
            }
            return try await group.reduce(into: [(Int, String)]()) { $0.append($1) }
        }
        for (index, id) in results.sorted(by: { $0.0 < $1.0 }) {
            print("  writer \(index) (pool \(index.isMultiple(of: 2) ? "app" : "cli")) got row \(id)")
        }
        let materialised = try store.allMeetings().filter { $0.calendarEventID == "6A70E5D8-MATER-1400" }
        print("  rows with that calendar_event_id: \(materialised.count)")
        print("  distinct ids returned: \(Set(results.map(\.1)).count)")
        #expect(materialised.count == 1)
        #expect(Set(results.map(\.1)).count == 1)
        print("")
    }
}
