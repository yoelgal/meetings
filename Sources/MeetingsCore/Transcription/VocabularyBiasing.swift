import FluidAudio
import Foundation

/// What one batch pass did with the custom vocabulary in effect.
///
/// The feature is invisible by construction — it changes words inside a transcript nobody has read
/// yet — so it has to be able to say what it did. A report with an empty `applied` and no
/// `unavailable` is the honest "the terms were in play and nothing needed correcting"; an
/// `unavailable` is the honest "your jargon may be mangled, and here is why".
public struct VocabularyBiasingReport: Sendable, Hashable {
    /// The terms actually handed to the recogniser, after the length and duplicate filters.
    public var terms: [String]
    /// Terms the CTC spotter heard somewhere in the audio. A superset of ``applied``.
    public var detected: [String]
    /// Terms that replaced something in the transcript. This is the feature working, or not.
    public var applied: [String]
    /// Set when biasing could not run — the 97.5 MB CTC model would not download, the pass came back
    /// with no token timings. The transcript is still there and still written; it is just unbiased.
    public var unavailable: String?

    /// One correction as the rescorer itself describes it: the heard words it consumed, and the text
    /// it put in their place.
    ///
    /// Internal, because outside the module ``applied`` is the answer. Inside, this is the only
    /// thing that can put a correction back on the clock: a replacement is a *span*, and its text is
    /// not a word — `quokka baseline` is one replacement and two words.
    struct Replacement: Sendable, Hashable {
        var original: String
        var replacement: String
    }

    /// Carried between the rescorer and the word timings, in the order the rescorer applied them.
    var replacements: [Replacement] = []

    public init(
        terms: [String] = [],
        detected: [String] = [],
        applied: [String] = [],
        unavailable: String? = nil
    ) {
        self.terms = terms
        self.detected = detected
        self.applied = applied
        self.unavailable = unavailable
    }

    /// One line, for a caller that wants to show or log what happened.
    public var sentence: String {
        if let unavailable { return "Custom vocabulary did not run: \(unavailable)" }
        guard !terms.isEmpty else { return "No custom vocabulary was in effect." }
        guard !applied.isEmpty else {
            return "\(terms.count) vocabulary term(s) in effect; none needed applying."
        }
        return "Applied \(applied.joined(separator: ", ")) from \(terms.count) vocabulary term(s)."
    }

    /// Both channels of one pass, as one verdict. Terms are the same list on both sides; what
    /// differs is what each channel's audio actually contained.
    static func union(_ reports: [VocabularyBiasingReport]) -> VocabularyBiasingReport? {
        guard let first = reports.first else { return nil }
        var merged = first
        for report in reports.dropFirst() {
            merged.terms = unique(merged.terms + report.terms)
            merged.detected = unique(merged.detected + report.detected)
            merged.applied = unique(merged.applied + report.applied)
            merged.replacements += report.replacements
            merged.unavailable = merged.unavailable ?? report.unavailable
        }
        return merged
    }
}

/// Custom vocabulary over a finished transcript, assembled by hand because FluidAudio does not
/// expose it as a transcription argument. There is no `transcribe(_:customVocabulary:)`: the caller
/// runs the pipeline itself — CTC keyword spotter → rescorer → `ctcTokenRescore` — as a post-process
/// over text that has already been recognised.
///
/// It needs a second model, `parakeet-ctc-110m-coreml`, ~97.5 MB on top of the transcriber's own
/// download. That is why nothing here happens until a pass actually has terms in effect: a user who
/// never added a term must never wait for it, and onboarding must never fetch it.
///
/// The live pass is deliberately left alone — corrections arrive when the meeting stops, not while
/// it runs. FluidAudio's streaming vocabulary support costs a second full CTC encoder pass over
/// every confirmed 15-second window and roughly doubles ASR peak memory, and its own docs call
/// streaming rescoring accuracy "Reduced". This trade was authorised from the start: live stays
/// approximate, and the pass on stop fixes it.
actor VocabularyBiasing {
    /// One per process, because what it holds belongs to the process rather than to a caller: the
    /// ~97.5 MB CTC model, the tokenizer, the memo of a load that failed, and the rescorer built for
    /// the current term list. Both callers — ``StreamingFileEngine`` and the promote-the-live-rows
    /// branch of ``TranscriptionService`` — can run in the same session (import one meeting, stop
    /// another), and an instance each meant loading the same 97.5 MB twice and re-attempting a
    /// failed download that the other had already given up on.
    static let shared = VocabularyBiasing()

    /// FluidAudio skips terms below `minTermLength` without a word, and a two-letter term is a false
    /// positive generator anyway. Drop them here so a report never claims a term is in effect when
    /// the library is about to ignore it.
    static let minimumTermLength = 3

    /// One term as FluidAudio wants it, before tokenisation. Hashable so a term list that has not
    /// changed since the last meeting can reuse the rescorer instead of rebuilding it.
    struct Entry: Hashable, Sendable {
        let text: String
        let minSimilarity: Float?
    }

    private struct Prepared {
        let signature: [Entry]
        let context: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
    }

    private var loaded: (models: CtcModels, tokenizer: CtcTokenizer)?
    /// A failed load is remembered for the life of the process. Without it, a laptop off the network
    /// re-attempts 97.5 MB on every channel of every meeting in the queue.
    private var loadFailure: String?
    private var prepared: Prepared?

    // MARK: - The term list

    /// The store's terms as FluidAudio's, in a stable order.
    ///
    /// **`threshold` maps straight onto `minSimilarity`, and that is the correct direction.** Both
    /// are a *floor the candidate has to clear*: 0.9 demands a near-exact match and so replaces
    /// almost nothing, 0.3 will rewrite loosely similar words. It only reads backwards if you take
    /// "threshold" to mean "how hard to push this term", which it is not — that knob is `cbw`, and we
    /// leave it to FluidAudio's size-aware tuning. A nil threshold means exactly that: let the
    /// library pick, which it does better than we would — **except on a term short enough that the
    /// library's pick is measurably wrong**; see ``shortTermMinSimilarity(for:)``.
    static func entries(for terms: [VocabularyTerm]) -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        for term in terms where term.enabled {
            let text = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= minimumTermLength, seen.insert(text.lowercased()).inserted else {
                continue
            }
            let threshold = term.threshold.map { Float(min(1, max(0, $0))) } ?? shortTermMinSimilarity(for: text)
            result.append(Entry(text: text, minSimilarity: threshold))
        }
        return result
    }

    /// The over-firing guard, as a number.
    ///
    /// FluidAudio's size-aware default is a 0.50 similarity floor, and on a short term that is not a
    /// gate at all — measured on `say`-generated audio with the term `CRAN` in effect:
    ///
    /// ```
    /// 'ran' vs 'CRAN' (sim=0.75, span=1)  ->  REPLACE   "so we ran the job" -> "so we CRAN the job"
    /// ```
    ///
    /// The short-term cbw taper had already cut that term's boost from 4.5 to 0.72 and it fired
    /// anyway, so acoustics alone will not hold the line; the *word the term was added to fix* was
    /// left alone in the same pass, because it was already spelled right. The transcript came out
    /// worse than the unbiased one and the report called it a success.
    ///
    /// Similarity cannot separate a good short fire from a bad one — the arithmetic says so. Against
    /// a four-character term the scale is that coarse: one edit is 0.75 whether the word it lands on
    /// is the mangled jargon or an unrelated common word, so no threshold below that keeps the first
    /// and drops the second. The only honest floor sits above a single edit, which is FluidAudio's own
    /// `shortWordSimilarity`, 0.80 — the value they apply when the *transcript* word is short, here
    /// applied when the *term* is, which is the case they leave open.
    ///
    /// What it costs, measured on one sentence with `CRAN` in effect: `crane → CRAN` still fires at
    /// exactly 0.80 and `ran → CRAN` no longer fires at 0.75, in the same pass. So a four-character
    /// term can still take a five-character word one edit away, and can no longer take any
    /// three-character word — 0.75 is the arithmetic maximum there — which is the whole
    /// `ran → CRAN`, `you → Yu`, `or → VR` family. A *three*-character term can no longer fire at
    /// all without a threshold of its own, and that is the intended reading of the "skip
    /// any token under 4 characters". Nothing five characters or longer is touched, so
    /// every term this feature exists for keeps the behaviour it was measured with: `Takamak →
    /// tokamak` 0.86, `Quoker Baseline → quokka baseline` 0.87, `Brian → Bhriain` 0.71,
    /// `Sapanska → Szczepanska` 0.64 all still fire.
    ///
    /// A term with its own `threshold` overrides this: a user who types 0.5 against a four-letter
    /// term has asked for the loose gate, and gets it.
    static func shortTermMinSimilarity(for text: String) -> Float? {
        guard text.count <= ContextBiasingConstants.shortWordMaxLength else { return nil }
        return ContextBiasingConstants.shortWordSimilarity
    }

    // MARK: - The pass

    /// Rescore a finished transcript against the terms in effect.
    ///
    /// **Engine-agnostic on purpose.** This used to take FluidAudio's `ASRResult`, which only the
    /// deleted Parakeet TDT batch engine ever produced — so the moment the app went to one streaming
    /// model for everything, the whole Vocabulary settings tab silently stopped doing anything at
    /// all. What it takes now is what every path in this app already has: timed segments, and the
    /// samples they were recognised from. ``StreamingFileEngine`` hands over what it has just
    /// recognised; the promote-the-live-rows branch of
    /// ``TranscriptionService/runBatchPass(meetingID:progress:)`` hands over the rows the live pane
    /// wrote, which is what keeps a *recorded* meeting getting its jargon corrected.
    ///
    /// Never throws. Every failure here — no model, no network, a spotter that cannot read the audio
    /// — comes back as the segments it was given plus a reason, because a transcript with mangled
    /// jargon beats no transcript at all.
    ///
    /// Segmentation is preserved rather than rebuilt: only the *text* of a segment changes, and its
    /// start and end are the ones it arrived with. Regrouping the corrected words through
    /// ``EngineSegment/grouped(words:silenceGapMs:maxWords:)`` was the alternative and it is worse —
    /// a correction that merges two heard words into one shortens the word list, so phrase boundaries
    /// would shift under notes already anchored to them, buying nothing a reader would notice.
    func apply(
        to segments: [EngineSegment],
        samples: [Float],
        entries: [Entry],
        progress: @Sendable (Double) -> Void
    ) async -> (segments: [EngineSegment], report: VocabularyBiasingReport) {
        var report = VocabularyBiasingReport(terms: entries.map(\.text))
        guard !entries.isEmpty else { return (segments, report) }

        let split = Self.words(in: segments)
        guard !split.words.isEmpty else {
            report.unavailable = "the transcript had no words to correct"
            return (segments, report)
        }

        let ready: Prepared
        do {
            ready = try await prepare(entries, progress: progress)
        } catch {
            report.unavailable = "the vocabulary model could not be loaded (\(error))"
            return (segments, report)
        }

        guard !ready.context.terms.isEmpty else {
            report.unavailable = "none of the terms could be tokenised for the vocabulary model"
            return (segments, report)
        }

        do {
            let spotted = try await ready.spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: ready.context,
                minScore: nil
            )
            guard !spotted.logProbs.isEmpty else {
                report.unavailable = "the vocabulary model produced no frames for this audio"
                return (segments, report)
            }
            // FluidAudio's own tuned numbers, by vocabulary size. `ctcTokenRescore`'s parameter
            // defaults are *not* these — they are the untuned 3.0/0.50 — so they are passed
            // explicitly, exactly as FluidAudio's own CLI does.
            let tuning = ContextBiasingConstants.rescorerConfig(forVocabSize: ready.context.terms.count)
            let output = ready.rescorer.ctcTokenRescore(
                transcript: split.words.map(\.text).joined(separator: " "),
                tokenTimings: split.words.map(Self.tokenTiming),
                logProbs: spotted.logProbs,
                frameDuration: spotted.frameDuration,
                cbw: tuning.cbw,
                // Widened by however far a word's timing can be from the word: see
                // ``words(in:)``. Left at the 0.10 s default, a term inside a multi-word segment
                // would be searched for in the wrong tenth of a second and never found.
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds + split.slackSeconds,
                minSimilarity: tuning.minSimilarity
            )
            report.detected = unique(spotted.detections.map(\.term.text))
            report.applied = unique(output.replacements.compactMap(\.replacementWord))
            report.replacements = output.replacements.compactMap { replacement in
                replacement.replacementWord.map {
                    VocabularyBiasingReport.Replacement(
                        original: replacement.originalWord, replacement: $0
                    )
                }
            }
            // Nothing to put back on the clock, so the segments are handed back exactly as they
            // arrived — same rows, same ids downstream, no reassembly to get wrong.
            guard !report.replacements.isEmpty else { return (segments, report) }

            // What lands is the truth: `applied` is set from the corrections that were actually
            // placed, never from what the rescorer wished for.
            let realigned = Self.realign(split.words, applying: report.replacements)
            report.applied = realigned.applied
            let lost = report.replacements.count - realigned.placed
            if lost > 0 {
                report.unavailable = "\(lost) of \(report.replacements.count) correction(s) could "
                    + "not be matched to the word timings and were left uncorrected"
            }
            return (Self.reassemble(realigned.words, into: segments), report)
        } catch {
            report.unavailable = "the vocabulary pass failed (\(error))"
            return (segments, report)
        }
    }

    /// The segments as one word list, and how far a word's timing can be from the word itself.
    ///
    /// A segment is a phrase — "the rig is free on Thursday", one start and one end — and both the
    /// rescorer and ``realign(_:applying:)`` work in words, so the span has to be shared out. It is
    /// shared out evenly, which assumes even pacing and is therefore wrong by some amount inside
    /// every multi-word segment.
    ///
    /// That amount is returned rather than shrugged at, because the rescorer only searches the CTC
    /// frames within `marginSeconds` of a word's timing and the default margin is 0.10 s — narrower
    /// than the error. The bound is the widest interpolated slice: no word can be further from its
    /// slice than the slice is wide, under the even-pacing assumption.
    ///
    /// A segment that is already one word contributes no slack, because its timing is not
    /// interpolated at all — it is the recogniser's own. Capped at one second so a pathological
    /// 60-word segment cannot open a window wide enough for a term to match almost anything.
    private static func words(
        in segments: [EngineSegment]
    ) -> (words: [EngineSegment], slackSeconds: Double) {
        var words: [EngineSegment] = []
        var slackMs = 0
        for segment in segments {
            let pieces = segment.text.split(separator: " ").map(String.init)
            guard pieces.count > 1 else {
                if let only = pieces.first {
                    words.append(EngineSegment(
                        startMs: segment.startMs, endMs: segment.endMs, text: only))
                }
                continue
            }
            let span = max(0, segment.endMs - segment.startMs)
            slackMs = max(slackMs, span / pieces.count)
            for (index, piece) in pieces.enumerated() {
                words.append(EngineSegment(
                    startMs: segment.startMs + span * index / pieces.count,
                    endMs: segment.startMs + span * (index + 1) / pieces.count,
                    text: piece
                ))
            }
        }
        return (words, min(1, Double(slackMs) / 1000))
    }

    /// One synthesised `TokenTiming` per word.
    ///
    /// Verified against FluidAudio 0.15.5 rather than assumed, because synthesising a library's
    /// input type is only safe if you know which fields it reads: `ctcTokenRescore` reduces
    /// `tokenTimings` to `[WordTiming]` through `buildWordTimings(from:)` on its first line and never
    /// reads `tokenId` or `confidence` at all, and `buildWordTimings` starts a new word on the
    /// SentencePiece marker `▁`. So one marker-prefixed token per word gives a 1:1 word mapping,
    /// which is exactly what ``realign(_:applying:)`` needs afterwards to put the corrections back on
    /// the clock.
    private static func tokenTiming(_ word: EngineSegment) -> TokenTiming {
        TokenTiming(
            token: "\u{2581}" + word.text,
            tokenId: 0,
            startTime: Double(word.startMs) / 1000,
            endTime: Double(word.endMs) / 1000,
            confidence: 1
        )
    }

    /// Put the corrected words back into the segments they came out of.
    ///
    /// Every word's timing came from inside exactly one segment, so the segment a word belongs to is
    /// the last one that starts at or before it. Both lists ascend — one file, one channel, one pass
    /// — so this is a single walk rather than a search per word.
    ///
    /// A replacement that spanned a segment boundary lands wholly in the earlier segment, because
    /// that is where its span starts. A segment left with no words at all is dropped rather than kept
    /// as an empty row: it can only happen when every one of its words was eaten by such a
    /// replacement, and an empty transcript row is noise in every surface that renders one.
    private static func reassemble(
        _ words: [EngineSegment], into segments: [EngineSegment]
    ) -> [EngineSegment] {
        guard !segments.isEmpty else { return [] }
        var pieces = [[String]](repeating: [], count: segments.count)
        var index = 0
        for word in words {
            while index + 1 < segments.count, segments[index + 1].startMs <= word.startMs {
                index += 1
            }
            pieces[index].append(word.text)
        }
        return segments.indices.compactMap { position in
            guard !pieces[position].isEmpty else { return nil }
            return EngineSegment(
                startMs: segments[position].startMs,
                endMs: segments[position].endMs,
                text: pieces[position].joined(separator: " ")
            )
        }
    }

    // MARK: - Models

    private func prepare(
        _ entries: [Entry],
        progress: @Sendable (Double) -> Void
    ) async throws -> Prepared {
        if let prepared, prepared.signature == entries {
            progress(1)
            return prepared
        }
        let (models, tokenizer) = try await loadModels(progress: progress)

        // A term with no CTC token ids is silently dropped by both the spotter and the rescorer, so
        // tokenising here is not an optimisation — it is the difference between a term working and
        // a term doing nothing at all.
        let terms = entries.compactMap { entry -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(entry.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: entry.text, ctcTokenIds: ids, minSimilarity: entry.minSimilarity
            )
        }
        let context = CustomVocabularyContext(terms: terms, minTermLength: Self.minimumTermLength)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: context,
            // The over-firing guard, at the one place it can still be set. Both of these are
            // FluidAudio's own opt-in anti-over-fire controls, and they are opt-in only because
            // their benchmarks trade a little keyword recall for them — a trade worth making
            // explicitly, because a term that fires on a word nobody said poisons every summary
            // drawn from the transcript.
            //
            // `spotterRescueEnabled: false` — the acoustic rescue is, by their measurement, the
            // dominant source of short-keyword over-firing: on a 90-clip distractor set it takes
            // false insertions from ~19 to ~94, at 0.97 → 0.92 recall. Off is better on both.
            //
            // `shortTermCbwTaperPivot: 5` — a short term scores close to zero per token and can beat
            // a correctly transcribed common word on the flat boost alone (`ran` → `CRAN`,
            // `sync` → `Snyk`). Below five tokens the boost is scaled down quadratically, so a short
            // term has to earn its replacement acoustically; their distractor set goes from 12 false
            // positives to 0. Long jargon — the terms this feature exists for — is untouched:
            // `ptychography` is seven tokens and keeps the full boost.
            //
            // It is not a cure. A four-letter term the user typed in deliberately can still take a
            // similar-sounding common word (measured: `ran` → `CRAN` survives the taper at cbw 0.72).
            // What the guards do buy is containment — the hit stays inside the word it landed on.
            config: VocabularyRescorer.Config(
                shortTermCbwTaperPivot: 5,
                spotterRescueEnabled: false
            ),
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: models.variant)
        )
        let ready = Prepared(
            signature: entries, context: context, spotter: spotter, rescorer: rescorer
        )
        prepared = ready
        progress(1)
        return ready
    }

    private func loadModels(
        progress: @Sendable (Double) -> Void
    ) async throws -> (CtcModels, CtcTokenizer) {
        if let loaded {
            progress(1)
            return loaded
        }
        if let loadFailure { throw BiasingError.modelUnavailable(loadFailure) }
        do {
            let directory = CtcModels.defaultCacheDirectory(for: Self.variant)
            if !CtcModels.modelsExist(at: directory) {
                try await download(into: directory, progress: progress)
            }
            let models = try await CtcModels.load(from: directory, variant: Self.variant)
            let tokenizer = try await CtcTokenizer.load(from: directory)
            loaded = (models, tokenizer)
            return (models, tokenizer)
        } catch {
            loadFailure = String(describing: error)
            throw error
        }
    }

    private static let variant = CtcModelVariant.ctc110m

    /// `CtcModels.download` takes no progress handler, and 97.5 MB with no bar is the kind of wait
    /// that reads as a hang. So the two files are fetched the way it fetches them — one at a time
    /// through `ModelHub` — with the handler it does not pass on.
    ///
    /// If FluidAudio's file list ever drifts from this one, `CtcModels.load` throws on the next line
    /// and the pass degrades to an unbiased transcript rather than to no transcript.
    private func download(into directory: URL, progress: @Sendable (Double) -> Void) async throws {
        let names = [ModelNames.CTC.melSpectrogramPath, ModelNames.CTC.audioEncoderPath]
        let parent = directory.deletingLastPathComponent()
        try await withoutActuallyEscaping(progress) { report in
            for (index, name) in names.enumerated() {
                _ = try await ModelHub.loadModels(
                    Self.variant.repo,
                    modelNames: [name],
                    directory: parent,
                    progressHandler: { step in
                        report((Double(index) + step.fractionCompleted) / Double(names.count))
                    }
                )
            }
        }
    }

    enum BiasingError: Error, CustomStringConvertible {
        case modelUnavailable(String)

        var description: String {
            switch self {
            case .modelUnavailable(let why): why
            }
        }
    }

    // MARK: - Putting the rescored text back on the clock

    /// Put the rescorer's corrections back on the clock, one correction at a time.
    ///
    /// The rescorer works on the same word list we build — FluidAudio's `buildWordTimings` over the
    /// same token timings — and reports each correction as the heard phrase it consumed and the text
    /// it put there. So the correction is a *span*, and its text is not a word: `quokka baseline` is
    /// one replacement over two heard words, and `Renata Szczepanska` is one over two more.
    ///
    /// Diffing its finished text against the heard words cannot recover that, which is what the old
    /// implementation tried: one output token per heard word, a replacement containing a space read
    /// as an insertion it documented as impossible, and — measured — a whole pass thrown away
    /// because a two-word term changed the capitalisation of its second word:
    ///
    /// ```
    /// FluidAudio: Final: The Tokamak team beat Quokka baseline again.   Replacements: 2
    /// stored:     The Takamak team beat Quoker Baseline again.          applied=[]
    /// ```
    ///
    /// So walk the replacements instead. Each one names the words it ate; find them, and give the
    /// whole correction the span from the first word's start to the last word's end.
    ///
    /// **A correction that cannot be placed is dropped on its own.** Its fix is lost and every other
    /// fix stands — one unplaceable term taking a good term's correction down with it is the bug
    /// above. Timings still never lie: a dropped correction leaves the heard word and its own
    /// timing exactly where they were.
    ///
    /// Returns the new word list, the terms that landed (deduped, for the report), and how many of
    /// the corrections landed — which is not the same number when one term is corrected twice.
    static func realign(
        _ words: [EngineSegment],
        applying replacements: [VocabularyBiasingReport.Replacement]
    ) -> (words: [EngineSegment], applied: [String], placed: Int) {
        // ponytail: first unconsumed occurrence of the phrase. The rescorer knows the exact index
        // and does not report it; the only ambiguity left is a transcript that says the same
        // misheard phrase twice and has only one of them corrected, which lands the fix on the
        // earlier one. Upgrade path if that ever matters: FluidAudio exposing `spanIndices`.
        var consumed = [Bool](repeating: false, count: words.count)
        var landed: [Int: (span: Int, text: String)] = [:]
        var applied: [String] = []

        for replacement in replacements {
            let phrase = replacement.original.split(separator: " ").map(String.init)
            guard !phrase.isEmpty, !replacement.replacement.isEmpty else { continue }
            guard let start = firstOccurrence(of: phrase, in: words, skipping: consumed) else { continue }
            for index in start..<(start + phrase.count) { consumed[index] = true }
            landed[start] = (phrase.count, replacement.replacement)
            applied.append(replacement.replacement)
        }
        guard !landed.isEmpty else { return (words, [], 0) }

        var out: [EngineSegment] = []
        var index = 0
        while index < words.count {
            if let correction = landed[index] {
                out.append(EngineSegment(
                    startMs: words[index].startMs,
                    endMs: words[index + correction.span - 1].endMs,
                    text: correction.text
                ))
                index += correction.span
            } else {
                out.append(words[index])
                index += 1
            }
        }
        return (out, unique(applied), landed.count)
    }

    private static func firstOccurrence(
        of phrase: [String], in words: [EngineSegment], skipping consumed: [Bool]
    ) -> Int? {
        guard phrase.count <= words.count else { return nil }
        return (0...(words.count - phrase.count)).first { start in
            phrase.indices.allSatisfy { !consumed[start + $0] && words[start + $0].text == phrase[$0] }
        }
    }
}

/// Order-preserving, case-sensitive dedupe. Term lists are short and their order is the order the
/// user reads them in.
private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}
