import Foundation

/// The live surface. Deliberately not `TranscriptionEngine`: the batch engine is handed a
/// finished file and returns everything at once, while this one is fed as the meeting happens and
/// answers over time, so one protocol covering both would be two protocols wearing a coat.
///
/// Offsets are milliseconds from the recording origin — the same clock a note anchors at — not from
/// the first sample the transcriber happened to receive.
public protocol StreamingTranscriber: Sendable {
    var name: String { get }
    /// Loads the models. Throws rather than downloading: recording must never stall behind a model
    /// fetch, so an absent model is a degrade (`StreamingTranscriptionError.modelsNotDownloaded`),
    /// not a wait.
    func start(channel: Channel) async throws
    /// 16 kHz mono. `atMs` is where these samples sit in the recording, so a dropped buffer shifts
    /// nothing downstream.
    func feed(_ samples: [Float], atMs: Int) async throws
    /// Finished segments, in order. Ends when `finish()` has drained the tail.
    var segments: AsyncStream<EngineSegment> { get }
    func finish() async
}

public enum StreamingTranscriptionError: Error, CustomStringConvertible {
    case modelsNotDownloaded(String)
    case loadFailed(String)

    public var description: String {
        switch self {
        case .modelsNotDownloaded(let path):
            "the live transcription model has not been downloaded yet (\(path))"
        case .loadFailed(let why):
            "the live transcription model failed to load: \(why)"
        }
    }
}

/// Turns a stream of timed words into the same segments the batch pass would have produced.
///
/// It does not decide *how* to group — `EngineSegment.grouped` does, and there is exactly one copy
/// of that rule. What lives here is only *when* to hand the buffer over, which is the one thing the
/// live path knows and the batch path does not: the batch pass has the whole file, so it can see a
/// silence at the end of a sentence; live, a silence is the absence of anything arriving, which you
/// can only recognise against how much audio has been fed so far.
struct StreamingSegmenter {
    /// What counts as a break *between* phrases when the buffer is grouped. A second of real
    /// silence is a paragraph break, and this is the number `EngineSegment.grouped` shares with the
    /// batch pass so a phrase reads the same either side of a re-transcription.
    var silenceGapMs = 1_000
    /// How long to hold the buffer before handing it on, which is a different question and used to
    /// be answered with the same number. It is not the same question: holding words back buys
    /// nothing here, because `RecordingController` assembles the phrase *in the row* — a burst that
    /// continues the previous one extends it rather than starting a new line. So the wait bought no
    /// better phrasing and cost a millisecond of latency for every millisecond of it, and the
    /// one-second bar was measured to be missed by exactly this: median 1044 ms against a 1 000 ms
    /// hold, which is the hold plus 44 ms of everything else.
    ///
    /// 400 ms rather than zero because the word-close rule upstream is already the real floor: by
    /// the time a word is known to be over, the recogniser has been fed 550–870 ms past it, so
    /// anything under about 500 here changes nothing except how often the store is written to.
    var emitGapMs = 400
    var maxWords = 60

    /// Bounded by `maxWords` — the accumulators inside the recogniser grow over a meeting, ours
    /// must not.
    private(set) var pending: [EngineSegment] = []

    /// - Parameter fedMs: offset of the newest audio handed to the recogniser.
    /// - Returns: the segments that are now final.
    mutating func ingest(_ words: [EngineSegment], fedMs: Int) -> [EngineSegment] {
        for word in words {
            // Back-fill the previous word's end from this word's start. The recogniser gives token
            // onsets only, so without this every segment would end on its last word's first
            // millisecond and a note taken mid-sentence would anchor to the wrong side of a gap.
            if let previous = pending.last, previous.endMs < word.startMs {
                pending[pending.count - 1] = EngineSegment(
                    startMs: previous.startMs, endMs: word.startMs, text: previous.text)
            }
            pending.append(word)
        }
        guard let last = pending.last else { return [] }
        let silent = fedMs - last.endMs > emitGapMs
        let endsSentence = last.text.hasSuffix(".") || last.text.hasSuffix("?")
            || last.text.hasSuffix("!")
        guard silent || endsSentence || pending.count >= maxWords else { return [] }
        return flush()
    }

    mutating func flush() -> [EngineSegment] {
        defer { pending = [] }
        return EngineSegment.grouped(
            words: pending, silenceGapMs: silenceGapMs, maxWords: maxWords)
    }
}
