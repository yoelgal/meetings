import Foundation
import Testing

@testable import MeetingsCore

/// The two halves of custom vocabulary that can be tested without 700 MB of Core ML: what the
/// store's terms turn into on the way to FluidAudio, and what FluidAudio's rewritten transcript
/// turns back into on the way to the store.
///
/// The middle — the CTC spotter and the rescorer — is proved by an A/B on real audio; see
/// `TranscriptionVocabularyABTests`.
@Suite struct VocabularyTermMappingTests {
    private func entries(_ terms: [VocabularyTerm]) -> [VocabularyBiasing.Entry] {
        VocabularyBiasing.entries(for: terms)
    }

    /// The mapping that is easy to get backwards. FluidAudio's `minSimilarity` is a floor — higher
    /// demands a closer match and so replaces *less* — and our `threshold` is documented as a
    /// confidence floor, which points the same way. So it is the identity, and a term asking for
    /// 0.9 must arrive as 0.9 and not as 0.1.
    @Test func thresholdIsAFloorAtBothEndsAndMapsStraightThrough() {
        let mapped = entries([
            VocabularyTerm(term: "ptychography", threshold: 0.9),
            VocabularyTerm(term: "altinha", threshold: 0.3),
            VocabularyTerm(term: "Torch0"),
        ])
        #expect(mapped.map(\.text) == ["ptychography", "altinha", "Torch0"])
        #expect(mapped[0].minSimilarity == 0.9, "strict stays strict — a high threshold replaces less")
        #expect(mapped[1].minSimilarity == 0.3, "loose stays loose — a low threshold replaces more")
        #expect(mapped[2].minSimilarity == nil, "no threshold means FluidAudio's size-aware default")
    }

    /// The over-firing guard, in numbers. Measured against real audio with `CRAN` in effect,
    /// FluidAudio's size-aware default (a 0.50 floor) let `'ran' vs 'CRAN' (sim=0.75)` through and
    /// wrote "so we CRAN the job" — while leaving the `cran` the term was added to fix alone. One
    /// edit against a four-character term is 0.75 in *either* direction, so no floor can keep the
    /// good short fires and drop the bad ones; 0.80 is the first that sits above a single edit.
    @Test func aShortTermGetsASimilarityFloorAndALongOneIsLeftAlone() {
        let mapped = entries([
            VocabularyTerm(term: "CRAN"),
            VocabularyTerm(term: "Snyk"),
            VocabularyTerm(term: "Rui"),
            VocabularyTerm(term: "Torch0"),
            VocabularyTerm(term: "Bhriain"),
            VocabularyTerm(term: "ptychography"),
        ])
        #expect(mapped.filter { $0.text.count <= 4 }.allSatisfy { $0.minSimilarity == 0.8 })
        #expect(mapped.filter { $0.text.count > 4 }.allSatisfy { $0.minSimilarity == nil },
                "five characters and up keep the behaviour they were measured with")
    }

    /// The escape hatch. A user who types a threshold against a four-letter term has asked for the
    /// loose gate and gets it — the floor is a default, not a ceiling on the user.
    @Test func anExplicitThresholdBeatsTheShortTermFloorInBothDirections() {
        let mapped = entries([
            VocabularyTerm(term: "CRAN", threshold: 0.5),
            VocabularyTerm(term: "Snyk", threshold: 0.95),
        ])
        #expect(mapped[0].minSimilarity == 0.5)
        #expect(mapped[1].minSimilarity == 0.95)
    }

    /// A malformed row cannot invert or disable the gate.
    @Test func aNonsenseThresholdIsClampedRatherThanTrusted() {
        let mapped = entries([
            VocabularyTerm(term: "Nunes", threshold: 4.2),
            VocabularyTerm(term: "Airbus", threshold: -1),
        ])
        #expect(mapped[0].minSimilarity == 1)
        #expect(mapped[1].minSimilarity == 0)
    }

    /// FluidAudio drops terms under `minTermLength` silently. Dropping them here too is what keeps
    /// the report honest: a term that reaches the recogniser and is ignored would otherwise be
    /// listed as "in effect".
    @Test func termsTooShortToSurviveNeverCountAsInEffect() {
        let mapped = entries([
            VocabularyTerm(term: "Li"),
            VocabularyTerm(term: " "),
            VocabularyTerm(term: "Ng"),
            // Trimmed before it is measured, so this one is three characters and survives.
            VocabularyTerm(term: " Rui "),
            VocabularyTerm(term: "Nunes"),
        ])
        #expect(mapped.map(\.text) == ["Rui", "Nunes"])
    }

    /// A disabled term is a term the user switched off after it misfired. It must not come back.
    @Test func disabledAndDuplicateTermsAreNotSentToTheRecogniser() {
        let mapped = entries([
            VocabularyTerm(term: "Torch0"),
            VocabularyTerm(term: "torch0", folderID: "airbus"),
            VocabularyTerm(term: "Ptychography", enabled: false),
        ])
        #expect(mapped.map(\.text) == ["Torch0"])
    }
}

@Suite struct RescoredTranscriptRealignmentTests {
    private func words(_ specs: [(Int, Int, String)]) -> [EngineSegment] {
        specs.map { EngineSegment(startMs: $0.0, endMs: $0.1, text: $0.2) }
    }

    private func correction(_ original: String, _ replacement: String)
        -> VocabularyBiasingReport.Replacement
    {
        .init(original: original, replacement: replacement)
    }

    private let heard = [
        (0, 400, "Burst"), (400, 800, "number"), (800, 1_200, "one"),
        (1_200, 1_600, "about"), (1_600, 2_000, "the"), (2_000, 2_800, "titography"),
        (2_800, 3_200, "plan."),
    ]

    /// The critic's own case. The corrected word has to land on the timing of the word it replaced,
    /// or a note taken at 2.4 s stops pointing at the sentence it was taken during.
    @Test func aCorrectedWordKeepsTheTimingOfTheWordItReplaced() {
        let out = VocabularyBiasing.realign(
            words(heard), applying: [correction("titography", "ptychography")]
        )
        #expect(out.applied == ["ptychography"])
        #expect(out.words.map(\.text)
            == ["Burst", "number", "one", "about", "the", "ptychography", "plan."])
        #expect(out.words[5].startMs == 2_000)
        #expect(out.words[5].endMs == 2_800)
        #expect(out.words.map(\.startMs) == heard.map(\.0))
    }

    /// A multi-word term collapses several heard words into one. The replacement has to span all of
    /// them — start of the first, end of the last — and nothing after it may drift.
    @Test func aMultiWordTermSpansEveryWordItSwallowed() {
        let heard = words([
            (0, 400, "We"), (400, 900, "use"), (900, 1_400, "new"), (1_400, 1_900, "red"),
            (1_900, 2_400, "daily."),
        ])
        let out = VocabularyBiasing.realign(heard, applying: [correction("new red", "Newrez")])
        #expect(out.words.map(\.text) == ["We", "use", "Newrez", "daily."])
        #expect(out.words[2].startMs == 900)
        #expect(out.words[2].endMs == 1_900)
        #expect(out.words[3].startMs == 1_900)
    }

    /// The regression. Measured on `say`-generated audio at commit e3388e1: FluidAudio logged
    /// `Final: The Tokamak team beat Quokka baseline again.` / `Replacements: 2`, and the stored
    /// transcript came back `The Takamak team beat Quoker Baseline again.` with `applied=[]` —
    /// because the replacement *text* holds a space, the old walk read it as an insertion, gave up
    /// on the whole pass, and took the perfectly good `Takamak → Tokamak` fix with it.
    ///
    /// Both corrections have to land, and the two-word one has to own both of its words' clock.
    @Test func aReplacementContainingASpaceLandsAndDoesNotTakeAnotherTermWithIt() {
        let heard = words([
            (0, 320, "The"), (320, 880, "Takamak"), (880, 1_120, "team"), (1_120, 1_360, "beat"),
            (1_360, 1_840, "Quoker"), (1_840, 2_320, "Baseline"), (2_320, 2_560, "again."),
        ])
        let out = VocabularyBiasing.realign(heard, applying: [
            correction("Takamak", "Tokamak"),
            correction("Quoker Baseline", "Quokka baseline"),
        ])
        #expect(out.words.map(\.text)
            == ["The", "Tokamak", "team", "beat", "Quokka baseline", "again."])
        #expect(out.applied == ["Tokamak", "Quokka baseline"])
        #expect(out.placed == 2)
        #expect(out.words[4].startMs == 1_360, "start of the first word it ate")
        #expect(out.words[4].endMs == 2_320, "end of the last word it ate")
        #expect(out.words[5] == heard[6], "nothing after the correction drifted")
    }

    /// The house rule the old pass broke: degrade per correction, never per pass. A term whose
    /// phrase is not in the word list loses its own fix and nothing else.
    @Test func aCorrectionThatCannotBePlacedLosesOnlyItsOwnFix() {
        let heard = words([
            (0, 400, "Sofia"), (400, 900, "noon"), (900, 1_400, "yes"), (1_400, 1_900, "tor"),
        ])
        let out = VocabularyBiasing.realign(heard, applying: [
            correction("noon", "Nunes"),
            correction("words that were never heard", "Ptychography"),
            correction("tor", "Torch0"),
        ])
        #expect(out.words.map(\.text) == ["Sofia", "Nunes", "yes", "Torch0"])
        #expect(out.applied == ["Nunes", "Torch0"])
        #expect(out.placed == 2, "the caller needs the count to say one correction was lost")
        #expect(out.words[1].startMs == 400)
        #expect(out.words[3].endMs == 1_900)
    }

    /// A dropped correction must not cost the timings either: the heard word stays exactly as heard.
    @Test func nothingIsInventedWhenNoCorrectionCanBePlaced() {
        let out = VocabularyBiasing.realign(
            words(heard), applying: [correction("nothing like it", "Torch0")]
        )
        #expect(out.words == words(heard))
        #expect(out.applied.isEmpty)
        #expect(out.placed == 0)
    }

    @Test func anUntouchedTranscriptComesBackWithEveryTimingIntact() {
        let out = VocabularyBiasing.realign(words(heard), applying: [])
        #expect(out.words == words(heard))
        #expect(out.applied.isEmpty)
    }

    /// The same term corrected twice is two corrections and one applied name — the caller compares
    /// the count, not the names, or it reports a loss that did not happen.
    @Test func oneTermCorrectedTwiceIsTwoPlacementsAndOneName() {
        let heard = words([
            (0, 400, "tor"), (400, 800, "and"), (800, 1_200, "tor"),
        ])
        let out = VocabularyBiasing.realign(heard, applying: [
            correction("tor", "Torch0"), correction("tor", "Torch0"),
        ])
        #expect(out.words.map(\.text) == ["Torch0", "and", "Torch0"])
        #expect(out.applied == ["Torch0"])
        #expect(out.placed == 2)
    }
}

@Suite struct VocabularyBiasingReportTests {
    @Test func bothChannelsOfOnePassReadAsOneVerdict() throws {
        let merged = try #require(VocabularyBiasingReport.union([
            VocabularyBiasingReport(terms: ["Torch0", "Nunes"], detected: ["Torch0"], applied: ["Torch0"]),
            VocabularyBiasingReport(terms: ["Torch0", "Nunes"], detected: ["Nunes"], applied: ["Nunes"]),
        ]))
        #expect(merged.terms == ["Torch0", "Nunes"])
        #expect(merged.applied == ["Torch0", "Nunes"])
    }

    /// The failure that trade demands: no model, but still a transcript. It has to say so.
    @Test func aPassThatCouldNotBiasSaysSoRatherThanLookingLikeASuccess() {
        let report = VocabularyBiasingReport(
            terms: ["ptychography"],
            unavailable: "the vocabulary model could not be loaded (offline)"
        )
        #expect(report.applied.isEmpty)
        #expect(report.sentence
            == "Custom vocabulary did not run: the vocabulary model could not be loaded (offline)")
    }

    @Test func termsInEffectWithNothingToCorrectIsNotAFailure() {
        let report = VocabularyBiasingReport(terms: ["Torch0"], detected: ["Torch0"])
        #expect(report.unavailable == nil)
        #expect(report.sentence == "1 vocabulary term(s) in effect; none needed applying.")
    }
}
