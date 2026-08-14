import Foundation
import Testing

@testable import MeetingsCore

/// The fixture seam. Everything that reads the calendar goes through
/// `CalendarSources.resolved()`, which is the only reason these tests can exercise `cal:` refs
/// without ever asking for calendar access.
@Suite struct CalendarSourceTests {
    @Test func fixtureRoundTripsThroughTheJSONOnDisk() async throws {
        let events = try await CalFixture.source().events(from: .distantPast, to: .distantFuture)
        #expect(events.count == CalFixture.events.count)

        let intro = try #require(events.first { $0.id == "6A70E5D8-MATER-1400" })
        #expect(intro.title == "Mater-AI intro")
        #expect(intro.calendarName == "Work")
        #expect(intro.videoLink?.host() == "meet.google.com")
        #expect(intro.attendees.contains(CalFixture.sofia))
        // The attendee EventKit gave us an address for and no name at all.
        #expect(intro.attendees.contains(Attendee(email: "lars.jensen@mater.ai")))
        #expect(intro.start == CalFixture.event("6A70E5D8-MATER-1400").start)
    }

    @Test func eventsAreWindowedAndSortedByStart() async throws {
        let source = CalFixture.source()
        let fortnight = try await source.events(
            from: CalFixture.now, to: CalFixture.now.addingTimeInterval(14 * 86_400)
        )
        #expect(fortnight.map(\.start) == fortnight.map(\.start).sorted())
        // The standup two days ago is outside the window; the board catch-up in twelve days is not.
        #expect(!fortnight.contains { $0.id == "8F2C1A44-STANDUP-0912" })
        #expect(fortnight.contains { $0.id == "A2C7B450-BOARD-1100" })
    }

    @Test func eventLookupByIdentifier() async throws {
        let source = CalFixture.source()
        #expect(try await source.event(withIdentifier: "1B93F7CE-ONEONE-1600")?.title == "1:1 Sofia")
        #expect(try await source.event(withIdentifier: "no-such-event") == nil)
    }

    @Test func videoLinkPresenceIsWhatTheNudgeReads() async throws {
        let source = CalFixture.source()
        let onsite = try #require(try await source.event(withIdentifier: "D0E4A116-AIRBUS-0930"))
        #expect(onsite.videoLink == nil)
        let standup = try #require(try await source.event(withIdentifier: "8F2C1A44-STANDUP-0912"))
        #expect(standup.videoLink?.host() == "torch0.zoom.us")
    }

    /// The seam itself: a fixture stands in when the environment names one, and only then.
    @Test func resolvedPicksTheFixtureOnlyWhenTheEnvironmentNamesOne() async throws {
        let resolved = CalendarSources.resolved()
        if Paths.calendarFixtureURL != nil {
            let fixture = try #require(resolved as? FixtureCalendarSource)
            _ = CalFixture.url   // the acceptance run's fixture is written before anything reads it
            let events = try await fixture.events(from: .distantPast, to: .distantFuture)
            #expect(events.contains { $0.title == "Torch0 weekly" })
        } else {
            #expect(resolved is EventKitCalendarSource)
            // Deliberately not called: EventKit access is never requested from a test.
        }
    }

    @Test func videoLinkSnifferFindsALinkInAnyOfTheFields() {
        #expect(VideoLink.find(in: [nil, "Join: https://torch0.zoom.us/j/98213347761"])?.host() == "torch0.zoom.us")
        #expect(VideoLink.find(in: ["Filton, Building 07", "https://intranet.airbus.com/rooms/7"]) == nil)
    }

    /// Subdomains are how most of these providers actually hand out links — a tenant, a region, a
    /// workspace — so matching only the bare host would miss nearly every real Zoom invitation.
    @Test func aSubdomainOfAKnownHostCounts() {
        #expect(VideoLink.find(in: ["https://acme.zoom.us/j/123"])?.host() == "acme.zoom.us")
        #expect(VideoLink.find(in: ["https://torch0.webex.com/meet/will"])?.host() == "torch0.webex.com")
        #expect(VideoLink.find(in: ["https://torch0.slack.com/huddle/T01/C02"])?.host() == "torch0.slack.com")
    }

    /// The reason the rule is host-or-subdomain and never a substring: an attacker who owns
    /// `attacker.com` can put `zoom.us` anywhere in a hostname they control, and a link in an
    /// invitation from a stranger is exactly the place that gets tried.
    @Test func aLookalikeHostIsNotAMeetingLink() {
        #expect(VideoLink.find(in: ["https://zoom.us.attacker.com/j/123"]) == nil)
        #expect(VideoLink.find(in: ["https://notzoom.us/j/123"]) == nil)
        #expect(VideoLink.find(in: ["https://meet.google.com.evil.test/x"]) == nil)
    }

    /// The list has to be wide enough that "has a meeting link" means any meeting, not just the four
    /// big providers — every host missing from it is a real meeting absent from Upcoming.
    @Test func theProviderListReachesBeyondTheBigFour() {
        let links = [
            "https://meet.goto.com/torch0/cryo-stage",
            "https://bluejeans.com/123456789",
            "https://chime.aws/1234567890",
            "https://discord.gg/abcdefg",
            "https://join.skype.com/abc123",
            "https://8x8.vc/torch0-standup",
            "https://torch0.dialpad.com/meetings/xyz",
            "https://butter.us/r/torch0",
            "https://gather.town/app/abc/torch0",
            "https://tuple.app/c/abc-def",
            "https://meeting.zoho.com/meeting/join?key=abc",
            "https://v.ringcentral.com/join/123456789",
        ]
        for link in links {
            #expect(VideoLink.find(in: [link]) != nil, "\(link) should read as a meeting link")
        }
        // Zoho hangs unrelated products off the same domain, so only the meeting subdomain counts.
        #expect(VideoLink.find(in: ["https://crm.zoho.com/records/42"]) == nil)
    }

    /// The whole rule Upcoming filters on, at both front ends (`AppModel.loadUpcoming`,
    /// `meetings upcoming`).
    @Test func isMeetingIsExactlyWhetherThereIsALink() {
        #expect(CalFixture.event("8F2C1A44-STANDUP-0912").isMeeting)
        #expect(CalFixture.event("A2C7B450-BOARD-1100").isMeeting)
        // In person at Filton, and a site visit. Neither is something there is a call to join.
        #expect(!CalFixture.event("D0E4A116-AIRBUS-0930").isMeeting)
        #expect(!CalFixture.event("35FA6D9C-MAAGAN-0800").isMeeting)

        let events = [CalFixture.event("8F2C1A44-STANDUP-0912"), CalFixture.event("D0E4A116-AIRBUS-0930")]
        #expect(events.filter(\.isMeeting).map(\.id) == ["8F2C1A44-STANDUP-0912"])
    }

    /// Only the *list* is filtered. A `cal:` ref pointing at a linkless event still has to resolve,
    /// or an agent could not attach pre-notes to one and `meetings show cal:…` would fail
    /// on the very events the list stopped showing.
    @Test func lookupByIdentifierIgnoresTheMeetingFilter() async throws {
        let source = CalFixture.source()
        let onsite = try #require(try await source.event(withIdentifier: "D0E4A116-AIRBUS-0930"))
        #expect(!onsite.isMeeting)
        #expect(onsite.title == "Ptychography review with Airbus")
    }
}

/// The bug this exists to prevent reached 3,779 rows for one meeting on a real machine.
///
/// `EventKitCalendarSource.convert` used to fall back to `UUID()` when an event carried no
/// identifier, which some subscribed and CalDAV calendars do not. That was invisible until
/// `CalendarSync` started writing a row per event, at which point every poll invented a new identity
/// for the same call and inserted it again. A source guard rather than a behaviour test, because
/// reproducing it needs a real `EKEvent` from a real calendar that withholds identifiers.
@Test func theCalendarSourceNeverInventsARandomEventIdentity() throws {
    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/MeetingsCore/Calendar/EventKitCalendarSource.swift"),
        encoding: .utf8
    )
    #expect(!source.contains("UUID()"),
            "an event with no identifier must get a stable id, never a fresh one per poll")
    #expect(source.contains("SHA256"),
            "the fallback identity has to be a digest of the event, not a per-process hash")
}
