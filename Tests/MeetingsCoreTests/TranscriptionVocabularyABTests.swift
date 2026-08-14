import Foundation
import Testing

@testable import MeetingsCore

/// The proof that custom vocabulary is not a no-op, run against the real recogniser on real audio.
///
/// It is off unless `MEETINGS_VOCAB_AB` names a WAV, because it needs the ~600 MB TDT bundle, a
/// second ~97.5 MB CTC model and several seconds of Neural Engine time — none of which belongs in a
/// suite that runs on every save. The audio is generated silently:
///
/// ```
/// say -o /tmp/vocab-ab.wav --data-format=LEI16@16000 "Burst number one about the ptychography plan."
/// MEETINGS_VOCAB_AB=/tmp/vocab-ab.wav MEETINGS_VOCAB_AB_TERM=ptychography \
///   swift test --filter CustomVocabularyOnRealAudio
/// ```
///
/// What it pins is the A/B the critic ran: the same file, the same engine instance, once with no
/// terms and once with one, and the term has to appear in the second transcript and not the first.
@Suite struct CustomVocabularyOnRealAudioTests {
    private static let audio = ProcessInfo.processInfo.environment["MEETINGS_VOCAB_AB"]
    private static let term = ProcessInfo.processInfo.environment["MEETINGS_VOCAB_AB_TERM"] ?? "ptychography"

    @Test(.enabled(if: audio != nil))
    func theTermTheRecogniserGetsWrongIsRightOnceItIsInTheVocabulary() async throws {
        let url = URL(fileURLWithPath: try #require(Self.audio))
        let engine = FluidAudioBatchEngine()
        try await engine.prepare(progress: { _ in })

        let before = try await engine.transcribe(url, vocabulary: [], progress: { _ in })
        let unbiased = await engine.vocabularyReport()
        let after = try await engine.transcribe(
            url,
            vocabulary: [VocabularyTerm(term: Self.term)],
            progress: { _ in }
        )
        let report = await engine.vocabularyReport()

        // Printed before anything can fail, because this output *is* the evidence.
        print("A/B BEFORE: \(before.map(\.text).joined(separator: " "))")
        print("A/B AFTER:  \(after.map(\.text).joined(separator: " "))")
        print("A/B REPORT: \(report?.sentence ?? "no report")")

        #expect(unbiased == nil, "no terms means the CTC model is never touched")
        let applied = try #require(report)
        #expect(applied.unavailable == nil)
        #expect(applied.applied.count == 1)
        // Case is FluidAudio's to decide — it preserves the capitalisation of the word it replaced.
        #expect(applied.applied[0].localizedCaseInsensitiveCompare(Self.term) == .orderedSame)
        #expect(!before.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains(Self.term))
        #expect(after.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains(Self.term))
        // The corrected word has to sit on the clock, not just in the string.
        let corrected = try #require(
            after.first { $0.text.localizedCaseInsensitiveContains(Self.term) }
        )
        #expect(corrected.endMs > corrected.startMs)
    }

    /// A multi-word term is inert unless the corrections come back per replacement span.
    ///
    /// Measured at e3388e1 on this clip: FluidAudio logged `Final: The Tokamak team beat Quokka
    /// baseline again.` / `Replacements: 2`, and the stored transcript came back
    /// `The Takamak team beat Quoker Baseline again.` with `applied=[]` and
    /// `unavailable=the corrected transcript could not be realigned to the word timings`. One
    /// multi-word term destroyed a single-word term's correct fix, and the first-named
    /// vocabulary source — auto-seeded attendee full names — is multi-word by construction.
    ///
    /// ```
    /// say -o /tmp/vocab-multi.wav --data-format=LEI16@16000 \
    ///   "The takamak team beat kwoka baseleen again."
    /// MEETINGS_VOCAB_AB_MULTIWORD=/tmp/vocab-multi.wav swift test --filter CustomVocabularyOnRealAudio
    /// ```
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGS_VOCAB_AB_MULTIWORD"] != nil))
    func aMultiWordTermLandsAndDoesNotCostTheSingleWordTermBesideIt() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MEETINGS_VOCAB_AB_MULTIWORD"])
        let url = URL(fileURLWithPath: path)
        let engine = FluidAudioBatchEngine()
        try await engine.prepare(progress: { _ in })

        let before = try await engine.transcribe(url, vocabulary: [], progress: { _ in })
        let after = try await engine.transcribe(
            url,
            vocabulary: [VocabularyTerm(term: "tokamak"), VocabularyTerm(term: "quokka baseline")],
            progress: { _ in }
        )
        let report = try #require(await engine.vocabularyReport())
        let text = after.map(\.text).joined(separator: " ")
        print("MULTIWORD BEFORE: \(before.map(\.text).joined(separator: " "))")
        print("MULTIWORD AFTER:  \(text)")
        print("MULTIWORD REPORT: \(report.sentence)")

        #expect(report.unavailable == nil)
        #expect(report.applied.count == 2, "both terms, not one term and a discarded pass")
        #expect(text.localizedCaseInsensitiveContains("tokamak"))
        #expect(text.localizedCaseInsensitiveContains("quokka baseline"))
        // The multi-word correction has to own the clock of every word it ate, and nothing after it
        // may drift — the timings are what notes anchor to.
        let corrected = try #require(after.first { $0.text.localizedCaseInsensitiveContains("quokka") })
        #expect(corrected.endMs > corrected.startMs)
        #expect(after.map(\.startMs) == after.map(\.startMs).sorted())
        #expect(after.last?.endMs == before.last?.endMs, "the transcript still ends where the audio does")
    }

    /// The over-firing guard, on the case that made the transcript *worse* than the unbiased
    /// one: a four-letter term rewriting an ordinary English word while leaving the word it was
    /// added to fix alone, and reporting success.
    ///
    /// Measured at e3388e1: `'ran' vs 'CRAN' (sim=0.75, span=1) -> REPLACE`, giving
    /// "so we CRAN the job twice", `applied=["CRAN"]`. The short-term cbw taper had already cut the
    /// boost to 0.72 and it fired anyway.
    ///
    /// ```
    /// say -o /tmp/vocab-overfire.wav --data-format=LEI16@16000 \
    ///   "The cran mirror was down, so we ran the job twice."
    /// MEETINGS_VOCAB_AB_OVERFIRE=/tmp/vocab-overfire.wav swift test --filter CustomVocabularyOnRealAudio
    /// ```
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGS_VOCAB_AB_OVERFIRE"] != nil))
    func aShortTermDoesNotRewriteAnOrdinaryWordItMerelyRhymesWith() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MEETINGS_VOCAB_AB_OVERFIRE"])
        let url = URL(fileURLWithPath: path)
        let engine = FluidAudioBatchEngine()
        try await engine.prepare(progress: { _ in })

        let before = try await engine.transcribe(url, vocabulary: [], progress: { _ in })
        let after = try await engine.transcribe(
            url, vocabulary: [VocabularyTerm(term: "CRAN")], progress: { _ in }
        )
        let report = try #require(await engine.vocabularyReport())
        print("OVERFIRE BEFORE: \(before.map(\.text).joined(separator: " "))")
        print("OVERFIRE AFTER:  \(after.map(\.text).joined(separator: " "))")
        print("OVERFIRE REPORT: \(report.sentence)")

        #expect(after.map(\.text) == before.map(\.text),
                "a term that has nothing to correct must leave the transcript exactly as it was")
        #expect(report.applied.isEmpty, "and must not claim it corrected something")
        #expect(report.unavailable == nil, "nothing failed — there was simply nothing to do")
    }

    /// The vocabulary's other half, and the honest version of it. The terms here are FluidAudio's own
    /// documented over-firers — `and` → `Andre`, `sync` → `Snyk`, `ran` → `CRAN`, `just` → `Wyost` —
    /// against audio made of nothing but the words they prey on.
    ///
    /// Two of the four used to fire on this clip — `ran → CRAN` at similarity 0.75 and
    /// `sink → Snyk` at 0.50 — because FluidAudio's size-aware default is a 0.50 floor and the
    /// short-term cbw taper alone does not hold. ``VocabularyBiasing/shortTermMinSimilarity(for:)``
    /// raises the floor to 0.80 for a term of four characters or fewer, and neither fires now.
    ///
    /// The containment bar stays, because it is the one that survives a term this guard cannot
    /// catch — **a bad term degrades a phrase, not the transcript**. A misfire replaces exactly the
    /// word it landed on, with a word the user asked for; it never deletes, never reflows, never
    /// touches the function words the stopword guard protects.
    ///
    /// ```
    /// say -o /tmp/distractor.wav --data-format=LEI16@16000 "And we ran the sync at noon, and it was just fine."
    /// MEETINGS_VOCAB_AB_DISTRACTOR=/tmp/distractor.wav swift test --filter CustomVocabularyOnRealAudio
    /// ```
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEETINGS_VOCAB_AB_DISTRACTOR"] != nil))
    func aVocabularyOfKnownOverFirersDoesNotEatTheTranscript() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MEETINGS_VOCAB_AB_DISTRACTOR"])
        let url = URL(fileURLWithPath: path)
        let engine = FluidAudioBatchEngine()
        try await engine.prepare(progress: { _ in })

        let terms = ["Andre", "Snyk", "CRAN", "Wyost"]
        let clean = try await engine.transcribe(url, vocabulary: [], progress: { _ in })
        let baited = try await engine.transcribe(
            url,
            vocabulary: terms.map { VocabularyTerm(term: $0) },
            progress: { _ in }
        )
        let report = try #require(await engine.vocabularyReport())

        let cleanWords = clean.map(\.text).joined(separator: " ").split(separator: " ").map(String.init)
        let baitedWords = baited.map(\.text).joined(separator: " ").split(separator: " ").map(String.init)
        print("DISTRACTOR CLEAN:  \(cleanWords.joined(separator: " "))")
        print("DISTRACTOR BAITED: \(baitedWords.joined(separator: " "))")
        print("DISTRACTOR REPORT: \(report.sentence)")

        // The guard: four terms of four characters or fewer, on a clip built from the common words
        // they prey on, now move nothing at all.
        #expect(baitedWords == cleanWords, "a known over-firer rewrote a word it merely rhymes with")
        #expect(report.applied.isEmpty)
        // Containment: same words in the same places, and every one that moved became a term the
        // user actually asked for. Nothing dropped, nothing reflowed, no cascade past the hit.
        #expect(baitedWords.count == cleanWords.count)
        for (was, now) in zip(cleanWords, baitedWords) where was != now {
            #expect(terms.contains { now.localizedCaseInsensitiveContains($0) },
                    "'\(was)' became '\(now)', which is not one of the terms")
        }
        #expect(baited.map(\.text) == baited.map(\.text).map { $0.trimmingCharacters(in: .whitespaces) })
        // The stopword guard is what stops a term eating the grammar around it.
        for stopword in ["And", "we", "at", "and", "it", "was", "just"] {
            #expect(baitedWords.contains(stopword), "'\(stopword)' was eaten")
        }
        // And the timings still describe the audio: monotonic, non-empty, inside the file.
        #expect(baited.allSatisfy { $0.endMs >= $0.startMs })
        #expect(baited.map(\.startMs) == baited.map(\.startMs).sorted())
    }
}
