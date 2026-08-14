import Foundation
import Testing

@testable import MeetingsCore

/// The `--match` scorer. The tiers matter more than their exact values: a candidate that
/// matched a whole word must always outrank one that matched half of one, because the agent shows
/// this ranking to a human and asks them to choose.
@Suite struct MatchScoringTests {
    @Test func tiersAreOrdered() {
        #expect(Match.tokenScore(query: "nunes", value: "nunes") == 1.0)
        #expect(Match.tokenScore(query: "nun", value: "nunes") == 0.8)
        #expect(Match.tokenScore(query: "une", value: "nunes") == 0.6)
        // One letter wrong out of five: a typo, scored below any real substring hit.
        let typo = Match.tokenScore(query: "nunez", value: "nunes")
        #expect(typo > 0.5 && typo < 0.6)
        #expect(Match.tokenScore(query: "airbus", value: "nunes") == 0)
    }

    @Test func fuzzyFloorRejectsDifferentWords() {
        #expect(Match.similarity("will", "well") == 0.75)
        #expect(Match.similarity("will", "weekly") < 0.7)
        #expect(Match.tokenScore(query: "will", value: "weekly") == 0)
    }

    @Test func caseAndDiacriticsAndPunctuationAllFold() {
        #expect(Match.tokens("Mater-AI intro") == ["mater", "ai", "intro"])
        #expect(Match.tokens("1:1 Sofia") == ["1", "1", "sofia"])
        #expect(Match.tokens("Ma'agan Michael") == ["ma'agan", "michael"])
        #expect(Match.fieldScore(queryTokens: ["mater", "ai"], value: "Mater-AI intro") == 1.0)
        #expect(Match.fieldScore(queryTokens: ["renee"], value: "Renée Lavigne") == 1.0)
    }

    /// A two-word query that only half-lands is a weaker answer than one that lands twice, and the
    /// mean is what puts those two in the right order. It is still an answer — the agent asks the
    /// user which one they meant — it just does not get to be first.
    @Test func everyQueryTokenHasToEarnItsShare() {
        let both = Match.fieldScore(queryTokens: ["sofia", "nunes"], value: "Sofia Nunes 1:1")
        let half = Match.fieldScore(queryTokens: ["sofia", "nunes"], value: "Sofia standup")
        let none = Match.fieldScore(queryTokens: ["sofia", "nunes"], value: "Airbus site visit")
        #expect(both == 1.0)
        #expect(both > half && half >= Match.threshold)
        #expect(none < Match.threshold)
    }

    @Test func scoreReportsEveryFieldThatTied() {
        let fields: [(MatchField, String)] = [
            (.title, "Torch0 weekly"),
            (.attendee, "Sofia Nunes"),
            (.email, "sofia.nunes"),
            (.calendar, "Work"),
        ]
        let sofia = Match.score(query: "sofia", fields: fields)
        #expect(sofia.score == 1.0)
        #expect(sofia.matchedOn == [.attendee, .email])

        let torch = Match.score(query: "torch0", fields: fields)
        #expect(torch.matchedOn == [.title])
        #expect(Match.score(query: "airbus", fields: fields).score < Match.threshold)
    }

    @Test func emailIsScoredOnItsLocalPartOnly() {
        // Otherwise "torch0" matches every colleague and "com" matches the world.
        #expect(Match.emailLocalPart("will.hastings@torch0.dev") == "will.hastings")
        let fields: [(MatchField, String)] = [(.email, Match.emailLocalPart("will.hastings@torch0.dev"))]
        #expect(Match.score(query: "hastings", fields: fields).score == 1.0)
        #expect(Match.score(query: "torch0", fields: fields).score == 0)
    }

    @Test func emptyQueryMatchesNothing() {
        #expect(Match.score(query: "   ", fields: [(.title, "Torch0 weekly")]).score == 0)
    }
}
