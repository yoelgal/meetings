import Foundation
import Testing

@testable import MeetingsCore

/// `ActionsInput` and `Correction` used to live in the CLI executable, where nothing could reach
/// them. Both stand in front of a write — one decides what an agent's `actions set` puts in the
/// database, the other decides what goes into the recogniser's vocabulary — so their edges are
/// tested here rather than trusted.
@Suite struct ActionsInputTests {
    @Test func itReadsTheFullShapeAndDefaultsDoneToFalse() throws {
        let actions = try ActionsInput.parse("""
            [{"text": "Send the ptychography numbers", "owner": "Sofia", "due": "Friday", "done": true},
             {"text": "Book the follow-up"}]
            """)
        #expect(actions.count == 2)
        #expect(actions[0].text == "Send the ptychography numbers")
        #expect(actions[0].owner == "Sofia")
        #expect(actions[0].due == "Friday")
        #expect(actions[0].done)
        #expect(actions[1].owner == nil)
        #expect(actions[1].due == nil)
        #expect(!actions[1].done, "absent means not done")
    }

    @Test func anEmptyListIsLegalBecauseClearingTheActionsIsSomethingAnAgentDoes() throws {
        #expect(try ActionsInput.parse("[]").isEmpty)
    }

    /// An empty string in a field is absence written differently, and storing it would make
    /// `owner == ""` a thing every reader has to check for.
    @Test func blankOptionalsBecomeNil() throws {
        let actions = try ActionsInput.parse(#"[{"text": "Ship it", "owner": "  ", "due": null}]"#)
        #expect(actions[0].owner == nil)
        #expect(actions[0].due == nil)
    }

    /// The reason this is hand-rolled: `JSONDecoder` would drop `assignee` silently and the agent
    /// would never learn the owner it set was thrown away.
    @Test func anUnknownKeyIsRefusedRatherThanDropped() {
        #expect(throws: InputError.self) {
            try ActionsInput.parse(#"[{"text": "Ship it", "assignee": "Sofia"}]"#)
        }
        let message = describe(#"[{"text": "Ship it", "assignee": "Sofia", "owmer": "Dan"}]"#)
        #expect(message.contains("item 1 has unknown keys assignee, owmer"), "\(message)")
    }

    /// `NSNumber` bridges to `Bool` happily, so `"done": 7` would silently mean done.
    @Test func aNumberIsNotABoolean() {
        #expect(describe(#"[{"text": "Ship it", "done": 7}]"#).contains("done that is not true or false"))
        #expect(describe(#"[{"text": "Ship it", "owner": 3}]"#).contains("owner that is not a string"))
    }

    @Test func everyOtherWayOfGettingItWrongNamesTheItem() {
        #expect(describe("").contains("came through empty"))
        #expect(describe("   \n ").contains("came through empty"))
        #expect(describe("not json at all").contains("not valid JSON"))
        #expect(describe(#"{"text": "Ship it"}"#).contains("top level has to be an array"))
        #expect(describe(#"["Ship it"]"#).contains("item 1 is not an object"))
        #expect(describe(#"[{"text": "Fine"}, {"owner": "Sofia"}]"#).contains("item 2 needs a non-empty text"))
        #expect(describe(#"[{"text": "   "}]"#).contains("item 1 needs a non-empty text"))
    }

    private func describe(_ raw: String) -> String {
        do {
            _ = try ActionsInput.parse(raw)
            return "(no error)"
        } catch {
            return (error as? InputError)?.errorDescription ?? "\(error)"
        }
    }
}

@Suite struct CorrectionTermTests {
    @Test func itKeepsOnlyTheWordsTheEditChanged() throws {
        #expect(try Correction.term(
            from: "run the torch zero calibration before the review",
            to: "run the Torch0 calibration before the review") == "Torch0")
        #expect(try Correction.term(from: "the tycography rig", to: "the ptychography rig") == "ptychography")
    }

    /// Head and tail are trimmed case-insensitively, so an edit that only changed capitalisation has
    /// no term in it at all. That is the right answer rather than a near miss: the recogniser heard
    /// every word correctly, and "Airbus" in its vocabulary would not have changed what it heard.
    /// The user is told to add the term directly if that is what they meant.
    @Test func aCapitalisationOnlyEditHasNoTermInIt() {
        #expect(throws: InputError.self) { try Correction.term(from: "the airbus review", to: "The Airbus review") }
    }

    @Test func anAppendedWordIsATerm() throws {
        #expect(try Correction.term(from: "ask Sofia", to: "ask Sofia Nunes") == "Nunes")
    }

    /// Punctuation is trimmed on the way in, or the vocabulary gets "ptychography." and matches
    /// nothing anybody says.
    @Test func punctuationDoesNotRideAlong() throws {
        #expect(try Correction.term(from: "we ran the tycography.", to: "we ran the ptychography.") == "ptychography")
    }

    @Test func anEditThatChangedNoWordsHasNothingToAdd() {
        #expect(throws: InputError.self) { try Correction.term(from: "same words", to: "same words") }
        #expect(throws: InputError.self) { try Correction.term(from: "same words", to: "  same   words  ") }
    }

    /// The promotion is offered for "a single word or short phrase" only: a rewritten sentence
    /// in the recogniser's vocabulary is worse than no vocabulary at all.
    @Test func arewriteIsRefusedRatherThanAddedAsAPhrase() {
        #expect(throws: InputError.self) {
            try Correction.term(
                from: "the meeting was about the rig",
                to: "the meeting covered a great many other things entirely")
        }
    }

    @Test func threeWordsIsStillAShortPhrase() throws {
        #expect(try Correction.term(from: "book the follow up call", to: "book the Airbus review call")
            == "Airbus review")
    }
}
