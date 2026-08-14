import Foundation
import Testing

@testable import MeetingsCore

/// Reference resolution. The materialisation rule — any write against a `cal:` ref creates
/// the row first — is the one an agent leans on constantly, so the tests that matter here are the
/// ones about it happening exactly once.
@Suite final class RefResolverTests {
    let directory: URL
    let store: MeetingStore
    let resolver: RefResolver

    /// The weekly, one day out. Used by most of these.
    static let weekly = "C41D9B02-WEEKLY-1000"

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
        resolver = RefResolver(store: store, calendar: CalFixture.source())
    }

    deinit { TestStore.remove(directory) }

    // MARK: - Read

    @Test func readResolvesAUUIDToItsRow() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(title: "Ptychography review with Airbus"))
        guard case .meeting(let found) = try await resolver.resolveForRead(.id(meeting.id)) else {
            Issue.record("expected a meeting"); return
        }
        #expect(found.id == meeting.id)
    }

    @Test func readResolvesACalRefToTheEventWhenNoRowExists() async throws {
        guard case .event(let event) = try await resolver.resolveForRead(MeetingRef("cal:\(Self.weekly)")) else {
            Issue.record("expected a calendar event"); return
        }
        #expect(event.title == "Torch0 weekly")
        #expect(event.attendees.contains(CalFixture.will))
    }

    /// Once the row exists it is the better answer: it carries the pre-notes the event never will.
    @Test func readPrefersTheRowOnceTheEventHasBeenMaterialised() async throws {
        let materialised = try await resolver.resolveForWrite(.calendar(Self.weekly))
        guard case .meeting(let found) = try await resolver.resolveForRead(.calendar(Self.weekly)) else {
            Issue.record("expected a meeting"); return
        }
        #expect(found.id == materialised.id)
    }

    @Test func neitherFoundIsNotFound() async throws {
        await #expect(throws: RefError.self) { try await resolver.resolveForRead(.id(UUID().uuidString)) }
        await #expect(throws: RefError.self) { try await resolver.resolveForRead(.calendar("no-such-event")) }
        await #expect(throws: RefError.self) { try await resolver.resolveForWrite(.id(UUID().uuidString)) }
        await #expect(throws: RefError.self) { try await resolver.resolveForWrite(.calendar("no-such-event")) }
    }

    // MARK: - Write and materialisation

    @Test func writeAgainstACalRefMaterialisesTheRowFromTheEvent() async throws {
        let event = CalFixture.event(Self.weekly)
        let meeting = try await resolver.resolveForWrite(.calendar(Self.weekly))

        #expect(meeting.title == event.title)
        #expect(meeting.state == .scheduled)
        #expect(meeting.calendarEventID == event.id)
        #expect(meeting.scheduledStart == event.start)
        #expect(meeting.scheduledEnd == event.end)
        #expect(meeting.attendees == event.attendees)
        #expect(try store.allMeetings().count == 1)
    }

    @Test func aSecondWriteReusesTheRowRatherThanMakingAnother() async throws {
        let first = try await resolver.resolveForWrite(.calendar(Self.weekly))
        let second = try await resolver.resolveForWrite(.calendar(Self.weekly))
        #expect(first.id == second.id)
        #expect(try store.allMeetings().count == 1)
    }

    /// The claim the schema's unique index exists to make good on. Eight writers across two
    /// connection pools, all released at the same instant so they really do overlap; exactly one
    /// row may result.
    @Test func concurrentWritesAgainstOneCalRefProduceOneRow() async throws {
        let cli = try TestStore.open(directory)   // a second process, on the same file
        let racers = (0..<8).map { index in
            RefResolver(store: index.isMultiple(of: 2) ? store : cli, calendar: CalFixture.source())
        }
        let gate = Gate(count: racers.count)

        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for racer in racers {
                group.addTask {
                    await gate.arrive()
                    return try await racer.resolveForWrite(.calendar(Self.weekly)).id
                }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }

        #expect(ids.count == 1)
        #expect(try store.allMeetings().count == 1)
    }

    /// The interleaving the unique index is there for, made deterministic: the pre-check finds no
    /// row, and another process inserts one while we are still fetching the event. The write must
    /// come back holding the winner's row, not a second row and not an error.
    @Test func aWriterThatLosesTheRaceReturnsTheWinningRow() async throws {
        let winner = Meeting(
            title: "Torch0 weekly",
            state: .scheduled,
            calendarEventID: Self.weekly,
            scheduledStart: CalFixture.event(Self.weekly).start
        )
        let losing = RefResolver(
            store: store,
            calendar: InterposingCalendarSource(inner: CalFixture.source()) { [store] in
                try store.createMeeting(winner)
            }
        )

        let resolved = try await losing.resolveForWrite(.calendar(Self.weekly))
        #expect(resolved.id == winner.id)
        #expect(try store.allMeetings().count == 1)
    }

    @Test func materialisationAutoSeedsTheAttendeeVocabulary() async throws {
        _ = try await resolver.resolveForWrite(.calendar("A2C7B450-BOARD-1100"))   // Daniel Green, Will Hastings
        let terms = try store.allVocabularyTerms()

        #expect(terms.map(\.term).sorted() == ["Daniel Green", "Hastings", "Will Hastings"])
        #expect(terms.allSatisfy { $0.source == .attendee && $0.enabled && $0.folderID == nil })
        // The two refusals this guard exists for.
        #expect(!terms.contains { $0.term == "Will" })
        #expect(!terms.contains { $0.term == "Green" })
    }

    @Test func materialisingAnEventWithNoSeedableAttendeeAddsNoVocabulary() async throws {
        _ = try await resolver.resolveForWrite(.calendar("D0E4A116-AIRBUS-0930"))
        // Klaus Bergmann and Ravi Chandrasekaran are seedable; Bo Li is not.
        #expect(try !store.allVocabularyTerms().contains { $0.term.contains("Li") })
    }

    // MARK: - Match

    @Test func matchReturnsEveryCandidateOverThresholdSortedByScore() async throws {
        let candidates = try await resolver.match("torch0 weekly")
        #expect(candidates.count >= 2)
        #expect(candidates.map(\.score) == candidates.map(\.score).sorted(by: >))
        #expect(candidates.allSatisfy { $0.score >= Match.threshold })

        let titles = candidates.map(\.title)
        #expect(titles.contains("Torch0 weekly"))
        #expect(titles.contains("Torch0 weekly sync"))
        #expect(!titles.contains("Ptychography review with Airbus"))
        #expect(candidates.allSatisfy { $0.ref.hasPrefix("cal:") })
        #expect(candidates.first?.matchedOn == ["title"])
    }

    @Test func matchScoresAttendeesAndEmailLocalParts() async throws {
        let byName = try await resolver.match("Nunes")
        // The standup, the weekly, the intro, the 1:1 and the weekly sync: Sofia is on all five.
        #expect(byName.count == 5)
        #expect(byName.allSatisfy { $0.matchedOn.contains("attendee") })

        let byEmail = try await resolver.match("bergmann")
        #expect(byEmail.map(\.title) == ["Ptychography review with Airbus"])
        #expect(byEmail.first?.matchedOn == ["attendee", "email"])
    }

    @Test func matchNeverListsAnEventAndTheRowMadeFromItTwice() async throws {
        let before = try await resolver.match("torch0 weekly")
        let meeting = try await resolver.resolveForWrite(.calendar(Self.weekly))
        let after = try await resolver.match("torch0 weekly")

        #expect(after.count == before.count)
        #expect(after.contains { $0.ref == meeting.id })
        #expect(!after.contains { $0.ref == "cal:\(Self.weekly)" })
    }

    @Test func matchLooksBackwardsAsWellAsForwards() async throws {
        // The standup was two days ago; "what did we decide" has to find it.
        #expect(try await resolver.match("standup").map(\.title) == ["Torch0 standup"])
        #expect(try await resolver.match("standup", within: 1).isEmpty)
    }

    @Test func matchNeverAutoResolvesAndReturnsNothingBelowThreshold() async throws {
        #expect(try await resolver.match("quarterly compliance audit").isEmpty)
    }
}
