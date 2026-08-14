import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v3 (25 languages) through FluidAudio's Core ML port. The models are ~600 MB and
/// download once into FluidAudio's own cache under Application Support; nothing is bundled in the
/// app. After that every pass is on device, and the default configuration makes no network call.
public actor FluidAudioBatchEngine: TranscriptionEngine {
    public nonisolated let name = "fluidaudio"
    public nonisolated let model = "parakeet-tdt-0.6b-v3"

    /// v3 rather than v2: a meeting in Portuguese should not come back as English-shaped nonsense,
    /// and v3 is what is pinned. Cost is slightly weaker punctuation than v2, which is why
    /// `EngineSegment.grouped` does not rely on punctuation alone.
    private static let version: AsrModelVersion = .v3

    private var manager: AsrManager?

    /// Built eagerly, costs nothing until a pass has terms: it downloads and loads nothing until
    /// ``VocabularyBiasing/apply(to:samples:entries:progress:)`` is called with a non-empty list.
    private let biasing = VocabularyBiasing()
    private var report: VocabularyBiasingReport?

    public init() {}

    /// True when the models are already on disk, so onboarding can skip the download step and
    /// `meetings status` can answer without touching the network.
    public static func modelsAreCached() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    public func prepare(progress: @Sendable (Double) -> Void) async throws {
        guard manager == nil else {
            progress(1)
            return
        }
        // ponytail: the raw fraction is reported as FluidAudio gives it. A single `downloadAndLoad`
        // runs ~8 separate download/compile stages and each one sweeps 0→1, so a caller that wants a
        // monotonic bar has to count stages itself — worth doing in onboarding, not here.
        let models = try await withoutActuallyEscaping(progress) { report in
            try await AsrModels.downloadAndLoad(
                version: Self.version,
                progressHandler: { report($0.fractionCompleted) }
            )
        }
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
        progress(1)
    }

    public func vocabularyReport() -> VocabularyBiasingReport? { report }

    public func transcribe(
        _ audio: URL,
        vocabulary: [VocabularyTerm],
        progress: @Sendable (Double) -> Void
    ) async throws -> [EngineSegment] {
        guard let manager else {
            throw TranscriptionError.modelsUnavailable("prepare() has not run for \(name)")
        }
        // A track with no frames — the recorder died before its first buffer, or the channel was
        // never captured — makes AVFoundation raise an ObjC exception deep inside the resampler.
        // That is uncatchable from Swift and takes the whole process with it, so probe the file
        // ourselves before handing it over. (quill hit this too; see NOTICE.)
        guard let duration = try Self.probeDuration(audio) else { return [] }
        // FluidAudio throws below 0.3 s. A hair of silence on one channel is not an error worth
        // failing the other channel's transcript over.
        guard duration >= 0.3 else { return [] }

        let entries = VocabularyBiasing.entries(for: vocabulary)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        var result: ASRResult
        report = nil

        if entries.isEmpty {
            // The common case, and the cheap one: the URL overload streams the file itself, and
            // nothing about the second model is touched.
            result = try await manager.transcribe(audio, decoderState: &state)
        } else {
            // The spotter has to score the *same* samples the transcript came from — reading the
            // file a second time risks a sample count that no longer lines up with the token
            // timings — so with terms in play we decode from samples and hand those on.
            let samples = try AudioConverter().resampleAudioFile(audio)
            result = try await manager.transcribe(samples, decoderState: &state)
            let biased = await biasing.apply(
                to: result, samples: samples, entries: entries, progress: progress
            )
            result = biased.result
            report = biased.report
        }

        var words = buildWordTimings(from: result.tokenTimings ?? []).map {
            EngineSegment(startMs: Self.ms($0.startTime), endMs: Self.ms($0.endTime), text: $0.word)
        }
        // Rescoring rewrites the text and leaves the token timings alone, so the corrected words
        // have to be put back on the clock before anything anchors to them. What lands is the truth:
        // the segments below are what gets stored, so `applied` is set from them and not from what
        // the rescorer wished for.
        if let corrections = report?.replacements, !corrections.isEmpty, !words.isEmpty {
            let realigned = VocabularyBiasing.realign(words, applying: corrections)
            words = realigned.words
            report?.applied = realigned.applied
            let lost = corrections.count - realigned.placed
            if lost > 0 {
                report?.unavailable = "\(lost) of \(corrections.count) correction(s) could not be "
                    + "matched to the word timings and were left uncorrected"
            }
        }
        guard !words.isEmpty else {
            // Timings are optional and can come back empty. One whole-file segment is a worse
            // anchor than per-sentence ones but it is not a lost transcript.
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [EngineSegment(startMs: 0, endMs: Self.ms(result.duration), text: text)]
        }
        return EngineSegment.grouped(words: words)
    }

    public func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    /// Nil when the file cannot be opened or holds no frames.
    private static func probeDuration(_ audio: URL) throws -> Double? {
        guard let file = try? AVAudioFile(forReading: audio) else {
            throw TranscriptionError.unreadableAudio(audio, "cannot be opened for reading")
        }
        guard file.length > 0, file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private static func ms(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds * 1000).rounded()))
    }
}
