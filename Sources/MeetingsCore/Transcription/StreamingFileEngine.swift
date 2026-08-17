import AVFoundation
import FluidAudio
import Foundation

/// Transcribes a finished file by driving the *live* streaming model over it unpaced, so one
/// downloaded model serves both the live pane and any file that needs transcribing.
///
/// This exists because the app used to download two models: a small one for the pane you watch
/// while talking, and Parakeet TDT — another ~600 MB — to re-transcribe the recording after. That is
/// a second download, a second wait, and a second transcript that disagrees with the one you already
/// read. With one streaming model there is no second pass, which leaves exactly one hole: a file
/// nobody streamed. An import has no live rows, and neither does a recording whose live model failed
/// to load. Something has to be able to transcribe a finished WAV, and this is it — the same model,
/// fed the file as fast as it will take it instead of at the speed somebody spoke.
///
/// "Unpaced" is the whole difference from the live path. ``FluidAudioStreamingTranscriber`` derives
/// its timestamps from samples *fed*, not from a clock, so feeding an hour of audio in ten seconds
/// produces the same timings as an hour of speaking would. Nothing about the model's own clock cares
/// that it is being fed faster than real time.
///
/// One instance of the transcriber per file, deliberately: ``FluidAudioStreamingTranscriber/finish()``
/// pads the tail, drains the segmenter and cleans the manager up, and its timeline cannot be
/// restarted — `reset()` restarts the millisecond clock at zero, which would silently move every
/// timestamp of the second file into the first file's span. Loading the model twice for a two-channel
/// meeting is what the live path already does, and it is a load off disk rather than a download.
public actor StreamingFileEngine: TranscriptionEngine {
    public nonisolated let name = "fluidaudio-streaming"
    public nonisolated let model: String

    private let variant: StreamingModelVariant
    private var report: VocabularyBiasingReport?

    public init(variant: StreamingModelVariant) {
        self.variant = variant
        self.model = variant.rawValue
    }

    /// True when the model is already on disk, so onboarding can skip the download step and
    /// `meetings status` can answer without touching the network.
    ///
    /// Deliberately the *same* check the live pane uses, not a second one that could disagree: one
    /// model serves both, so "the live transcript will appear" and "an import can be transcribed"
    /// are now one fact. They used to be two, and a store that had the live model and not the batch
    /// one reported ready and then produced an empty transcript.
    public static func modelsAreCached(_ variant: StreamingModelVariant) -> Bool {
        FluidAudioStreamingTranscriber.modelsAreCached(variant)
    }

    /// Downloads the model if it is absent. On a fresh install this is what the first batch pass
    /// pays for; onboarding normally pays it first through ``TranscriptionService/prepareModels(progress:)``.
    public func prepare(progress: @Sendable (Double) -> Void) async throws {
        guard !Self.modelsAreCached(variant) else { return progress(1) }
        try await withoutActuallyEscaping(progress) { report in
            try await FluidAudioStreamingTranscriber.prepareModels(
                variant: variant, progress: { report($0) })
        }
        progress(1)
    }

    public func vocabularyReport() -> VocabularyBiasingReport? { report }

    public func transcribe(
        _ audio: URL,
        vocabulary: [VocabularyTerm],
        progress: @Sendable (Double) -> Void
    ) async throws -> [EngineSegment] {
        // A track with no frames — the recorder died before its first buffer, or the channel was
        // never captured — makes AVFoundation raise an ObjC exception deep inside the resampler.
        // That is uncatchable from Swift and takes the whole process with it, so probe the file
        // ourselves before handing it over. (quill hit this too; see NOTICE.)
        guard let duration = try Self.probeDuration(audio) else { return [] }
        // FluidAudio throws below 0.3 s. A hair of silence on one channel is not an error worth
        // failing the other channel's transcript over.
        guard duration >= 0.3 else { return [] }

        report = nil
        let samples = try AudioConverter().resampleAudioFile(audio)
        guard !samples.isEmpty else { return [] }

        // Feeding owns the first four fifths of this file's slice of the bar; the vocabulary pass,
        // which on its first run fetches another ~97.5 MB, owns the rest. A frozen bar for the
        // length of that fetch is what reads as a hang.
        let segments = try await Self.recognise(
            samples, variant: variant, progress: { progress($0 * 0.8) })

        let entries = VocabularyBiasing.entries(for: vocabulary)
        guard !entries.isEmpty else {
            progress(1)
            return segments
        }
        let biased = await VocabularyBiasing.shared.apply(
            to: segments, samples: samples, entries: entries,
            progress: { progress(0.8 + $0 * 0.2) }
        )
        report = biased.report
        progress(1)
        return biased.segments
    }

    /// Nothing to release: the transcriber is per-file and cleans its own manager up in `finish()`,
    /// so there is no loaded model outliving a pass to drop.
    public func release() async {}

    // MARK: -

    /// Drive one instance of the live transcriber over the whole sample buffer and collect what it
    /// yields.
    ///
    /// The collector is started *before* the first sample is fed and awaited *after* `finish()`,
    /// which is the only correct order: the stream is unbounded but the tail — the last utterance,
    /// flushed by `finish()` — is only yielded during that call, so a collector started afterwards
    /// races the finish and a collector awaited before it deadlocks.
    ///
    /// 1280 samples is 80 ms at 16 kHz, which is the capture tap's buffer size. Feeding the model
    /// the same chunk size a meeting feeds it means the file path exercises the identical code path,
    /// including the dropped-buffer padding arithmetic, rather than a bulk path nothing else uses.
    private static func recognise(
        _ samples: [Float],
        variant: StreamingModelVariant,
        progress: @Sendable (Double) -> Void
    ) async throws -> [EngineSegment] {
        let transcriber = FluidAudioStreamingTranscriber(variant: variant)
        // `channel` is the live path's label for which capture stream this instance belongs to and
        // plays no part in recognition; a file is one stream, and the service tags the channel back
        // on from the file name it read.
        try await transcriber.start(channel: .mic)

        let collector = Task { () -> [EngineSegment] in
            var collected: [EngineSegment] = []
            for await segment in transcriber.segments { collected.append(segment) }
            return collected
        }

        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1_280, samples.count)
            try await transcriber.feed(
                Array(samples[offset..<end]), atMs: offset * 1_000 / 16_000)
            offset = end
            progress(Double(offset) / Double(samples.count))
        }
        await transcriber.finish()
        return await collector.value
    }

    /// Nil when the file holds no frames; throws when it cannot be opened at all, because those are
    /// different outcomes — an empty channel is a channel with nothing to say, and an unreadable
    /// file is a failure the user has to be told about.
    private static func probeDuration(_ audio: URL) throws -> Double? {
        guard let file = try? AVAudioFile(forReading: audio) else {
            throw TranscriptionError.unreadableAudio(audio, "cannot be opened for reading")
        }
        guard file.length > 0, file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
