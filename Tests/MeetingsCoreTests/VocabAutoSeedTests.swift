import Foundation
import Testing

@testable import MeetingsCore

/// The auto-seed guard. Most of these assert a *refusal*: seeding "Will" makes every
/// "will" in the transcript a candidate for boosting, and that is how a custom-vocabulary feature
/// ends up making transcripts worse.
@Suite struct VocabAutoSeedTests {
    @Test func fullNameAndSurnameSeed_bareFirstNameNever() {
        let terms = AutoSeed.candidates(for: Attendee(name: "Will Smith"))
        #expect(terms == ["Will Smith", "Smith"])
        #expect(!terms.contains("Will"))
    }

    @Test func bothTokensTooShortSeedsNothing() {
        #expect(AutoSeed.candidates(for: Attendee(name: "Bo Li")).isEmpty)
    }

    @Test func apostropheSurvives() {
        #expect(AutoSeed.candidates(for: Attendee(name: "Tal Ma'agan")) == ["Tal Ma'agan", "Ma'agan"])
        #expect(AutoSeed.candidates(for: Attendee(name: "Ma'agan Michael")) == ["Ma'agan Michael", "Michael"])
    }

    @Test func hyphenatedSurnameStaysWhole() {
        #expect(AutoSeed.candidates(for: Attendee(name: "Ana Nunes-Silva")) == ["Ana Nunes-Silva", "Nunes-Silva"])
    }

    /// The one that stops the feature poisoning transcripts: "Green" is a word the meeting will use.
    @Test func surnameThatIsACommonWordIsRefusedButTheFullNameSurvives() {
        #expect(AutoSeed.candidates(for: Attendee(name: "Daniel Green")) == ["Daniel Green"])
        #expect(AutoSeed.candidates(for: Attendee(name: "Sarah Young")) == ["Sarah Young"])
    }

    @Test func mononymIsNeverSeeded() {
        #expect(AutoSeed.candidates(for: Attendee(name: "Ravi")).isEmpty)
    }

    /// What most corporate directories hand EventKit, and the way it broke the guard was the worst
    /// available: the last token of "Hastings, Will" is the *first* name, and the rules seed the last
    /// token on its own. Every Exchange invitation was putting a bare first name into the recogniser.
    @Test func lastnameCommaFirstnameIsPutBackIntoSpeakingOrder() {
        #expect(AutoSeed.candidates(for: Attendee(name: "Hastings, Will")) == ["Will Hastings", "Hastings"])
        #expect(!AutoSeed.candidates(for: Attendee(name: "Hastings, Will")).contains("Will"))
        #expect(AutoSeed.candidates(for: Attendee(name: "Nunes, Sofia")) == ["Sofia Nunes", "Nunes"])
        #expect(AutoSeed.candidates(for: Attendee(name: "Nunes-Silva, Ana")) == ["Ana Nunes-Silva", "Nunes-Silva"])
        // Whitespace-free is the same shape and just as common from Exchange.
        #expect(AutoSeed.candidates(for: Attendee(name: "Hastings,Will")) == ["Will Hastings", "Hastings"])
    }

    /// Anything more elaborate than one comma is refused rather than guessed at. "Hastings, Will,
    /// PhD" reordered by rule would seed "PhD"; this guard would rather lose a surname.
    @Test func aNameWithMoreThanOneCommaIsRefused() {
        #expect(AutoSeed.candidates(for: Attendee(name: "Hastings, Will, PhD")).isEmpty)
        #expect(AutoSeed.candidates(for: Attendee(name: "Torch0 Lab, Building 2, Floor 3")).isEmpty)
    }

    /// Rooms, phones and video bridges arrive in the attendee list looking exactly like people.
    /// "Zoom" and "Huddle" are four letters and are not common enough words to be caught by the
    /// common-words list, so they need naming.
    @Test func roomsAndResourcesSeedNothing() {
        for resource in [
            "Torch0 Board Room", "Conference Room Lisbon", "Zoom Room 3", "Huddle Space Alpha",
            "Airbus Boardroom", "Polycom Speakerphone", "Toulouse Breakout Room",
        ] {
            #expect(AutoSeed.candidates(for: Attendee(name: resource)).isEmpty, "seeded from \(resource)")
        }
        // A resource word anywhere in the name is enough, whatever else the name contains.
        #expect(AutoSeed.candidates(for: Attendee(name: "Lisbon Huddle")).isEmpty)
        #expect(AutoSeed.candidates(for: Attendee(email: "boardroom.lisbon@torch0.dev")).isEmpty)
        // And a person is still a person.
        #expect(AutoSeed.candidates(for: Attendee(name: "Sofia Nunes")) == ["Sofia Nunes", "Nunes"])
    }

    @Test func nonLetterTokensAreDropped() {
        // The parenthetical is not evidence that "Torch0" is a term, however much we would like it.
        #expect(AutoSeed.candidates(for: Attendee(name: "Sofia Nunes (Torch0)")) == ["Sofia Nunes", "Nunes"])
        #expect(AutoSeed.candidates(for: Attendee(name: "Meeting Room 4")).isEmpty)
    }

    /// No display name at all. The surname is recoverable from the address; the full name is not,
    /// so it is not guessed.
    @Test func emailOnlyAttendeeYieldsTheSurnameOnly() {
        #expect(AutoSeed.candidates(for: Attendee(email: "lars.jensen@mater.ai")) == ["Jensen"])
        #expect(AutoSeed.candidates(for: Attendee(email: "ravi@torch0.dev")).isEmpty)
        #expect(AutoSeed.candidates(for: Attendee(email: "bo.li@airbus.com")).isEmpty)
    }

    @Test func displayNameWinsOverEmail() {
        let attendee = Attendee(name: "Sofia Nunes", email: "s.n@torch0.dev")
        #expect(AutoSeed.candidates(for: attendee) == ["Sofia Nunes", "Nunes"])
    }

    @Test func termsAreDeduplicatedAcrossAttendees() {
        let terms = AutoSeed.terms(for: [
            Attendee(name: "Sofia Nunes"),
            Attendee(name: "Sofia Nunes", email: "sofia.nunes@torch0.dev"),
        ])
        #expect(terms.map(\.term) == ["Sofia Nunes", "Nunes"])
        #expect(terms.allSatisfy { $0.source == .attendee && $0.enabled })
    }

    @Test func seedingTwiceIsIdempotentAndScopesToTheFolder() throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let store = try TestStore.open(directory)
        let folder = try store.createFolder(Folder(name: "Torch0"))

        let attendees = [CalFixture.will, CalFixture.sofia, CalFixture.bo]
        let first = try AutoSeed.seed(attendees: attendees, folderID: folder.id, into: store)
        let second = try AutoSeed.seed(attendees: attendees, folderID: folder.id, into: store)

        #expect(first.map(\.term) == ["Will Hastings", "Hastings", "Sofia Nunes", "Nunes"])
        #expect(second.map(\.id) == first.map(\.id))
        #expect(try store.vocabularyTerms(folderID: folder.id).count == 4)
        #expect(try store.vocabularyTerms(folderID: nil).isEmpty)
    }

    // MARK: - The bundled list

    @Test func commonWordsListIsLoadedAndCoversTheDangerousCollisions() {
        let words = AutoSeed.commonWords
        #expect(words.count > 2000 && words.count < 3500)
        for word in ["will", "call", "team", "mark", "sync", "note", "green", "young", "grace", "long"] {
            #expect(words.contains(word), "common-words.txt is missing \(word)")
        }
        // Ordinary English, which the original three corpora — man pages, UI strings and
        // engineering markdown — turned out to contain almost none of. A probe of 183 everyday
        // words found 170 missing; these are a sample of that class.
        for word in [
            "breakfast", "umbrella", "neighbour", "weather", "kitchen", "holiday", "hungry",
            "doctor", "garden", "bridge", "quiet", "tired", "happy", "coffee", "friend",
        ] {
            #expect(words.contains(word), "common-words.txt is missing the everyday word \(word)")
        }
        // Over-inclusion costs real vocabulary, so the list must not swallow ordinary surnames.
        for name in ["smith", "nunes", "hastings", "michael", "bergmann", "okonkwo"] {
            #expect(!words.contains(name), "common-words.txt wrongly contains the surname \(name)")
        }
        #expect(!words.contains(where: { $0.hasPrefix("#") || $0.contains(" ") }))
    }
}
