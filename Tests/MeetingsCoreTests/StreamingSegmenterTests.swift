import Foundation
import Testing

@testable import MeetingsCore

/// The live pass's own rule is *when* a segment is finished, not how words are grouped — grouping is
/// `EngineSegment.grouped`, shared with the batch pass. These cover the three ways a segment closes
/// and the one thing the recogniser cannot tell us: where a word ends.
struct StreamingSegmenterTests {
    private func word(_ text: String, at ms: Int) -> EngineSegment {
        EngineSegment(startMs: ms, endMs: ms + 80, text: text)
    }

    @Test func holdsWordsUntilSomethingClosesTheSegment() {
        var segmenter = StreamingSegmenter()
        let emitted = segmenter.ingest(
            [word("Sofia", at: 1_000), word("can", at: 1_400)], fedMs: 1_600)
        #expect(emitted.isEmpty)
        #expect(segmenter.pending.count == 2)
    }

    @Test func closesOnSentencePunctuationImmediately() {
        var segmenter = StreamingSegmenter()
        _ = segmenter.ingest([word("the", at: 1_000), word("rig", at: 1_300)], fedMs: 1_500)
        let emitted = segmenter.ingest([word("is", at: 1_600), word("free.", at: 1_900)], fedMs: 2_100)
        #expect(emitted.count == 1)
        #expect(emitted.first?.text == "the rig is free.")
        #expect(emitted.first?.startMs == 1_000)
        #expect(segmenter.pending.isEmpty)
    }

    /// A gap is the absence of anything arriving, so it can only be measured against how much audio
    /// has been fed. Nothing new comes in here at all — the segment closes because the meeting has
    /// moved on without it.
    @Test func closesOnASilenceGapWithNoNewWords() {
        var segmenter = StreamingSegmenter()
        #expect(segmenter.ingest([word("ptychography", at: 4_000)], fedMs: 4_200).isEmpty)
        let emitted = segmenter.ingest([], fedMs: 4_600)
        #expect(emitted.map(\.text) == ["ptychography"])
    }

    /// The wait before handing words on and the gap that separates one phrase from the next are two
    /// different numbers, and making them one is what put the live transcript over the
    /// one-second bar: every segment arrived 1 000 ms after its last word by construction, measured
    /// at a median of 1 044 ms. Holding words back bought nothing, because the phrase is assembled
    /// in the row afterwards — so the hold is short and the grouping gap is untouched.
    @Test func theEmitWaitIsShorterThanThePhraseGap() {
        var segmenter = StreamingSegmenter()
        #expect(segmenter.emitGapMs < segmenter.silenceGapMs)

        // Two words 800 ms apart — more than the emit wait, less than a phrase break. They come out
        // as separate segments because the first was handed on before the second arrived, and
        // `RecordingController` is what joins them back into one row.
        #expect(segmenter.ingest([word("Torch0", at: 1_000)], fedMs: 1_500).map(\.text) == ["Torch0"])
        #expect(segmenter.ingest([word("calibration", at: 1_800)], fedMs: 2_300).map(\.text) == ["calibration"])

        // And within one flush the grouping gap is still a full second: two words 900 ms apart that
        // arrive together are one phrase, not two.
        var together = StreamingSegmenter()
        _ = together.ingest([word("the", at: 3_000)], fedMs: 3_050)
        let phrase = together.ingest([word("rig", at: 3_900)], fedMs: 4_400)
        #expect(phrase.map(\.text) == ["the rig"])
    }

    @Test func closesAtTheWordCapSoAMonologueStaysAnchorable() {
        var segmenter = StreamingSegmenter()
        var emitted: [EngineSegment] = []
        for index in 0..<60 {
            emitted += segmenter.ingest([word("word\(index)", at: 100 * index)], fedMs: 100 * index + 80)
        }
        #expect(emitted.count == 1)
        #expect(emitted.first?.text.split(separator: " ").count == 60)
    }

    /// Timestamps from the streaming model are token onsets only. Without the back-fill every segment
    /// would end on the first millisecond of its last word.
    @Test func backFillsEachWordEndFromTheNextWordStart() {
        var segmenter = StreamingSegmenter()
        let emitted = segmenter.ingest(
            [word("Torch0", at: 2_000), word("calibration.", at: 2_600)], fedMs: 2_800)
        #expect(emitted.count == 1)
        #expect(emitted.first?.startMs == 2_000)
        #expect(emitted.first?.endMs == 2_680)
        // The last word keeps its nominal frame, not the whole pause that follows it.
        #expect(segmenter.pending.isEmpty)
    }

    /// Two sentences arriving in one poll must not become one segment: the grouping rule splits them,
    /// and the live path defers to it rather than keeping a second copy.
    @Test func splitsInsideOnePollTheSameWayTheBatchPassWould() {
        var segmenter = StreamingSegmenter()
        let emitted = segmenter.ingest(
            [word("Right.", at: 500), word("Next", at: 900), word("item.", at: 1_200)], fedMs: 1_400)
        #expect(emitted.map(\.text) == ["Right.", "Next item."])
    }
}
