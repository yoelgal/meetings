import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// `FluidAudioStreaming`: Parakeet realtime EOU 120M at the 320 ms tier, one instance per
/// channel.
///
/// Three things about this model shape the code, all verified against FluidAudio 0.15.5 rather than
/// its documentation:
///
/// 1. **End-of-utterance is not a segmentation signal.** `eouDetected` latches on the first confirmed
///    utterance end and only `reset()` clears it — and `reset()` restarts the millisecond timeline at
///    zero, which would silently move every note anchored after it. So EOU is ignored entirely and
///    segmentation is ours (``StreamingSegmenter``), against one continuous monotonic timeline.
/// 2. **The partial-transcript callback re-decodes the whole meeting on every chunk.** Over an hour
///    that is quadratic. Nothing here sets a callback; we poll the two index-aligned accumulator
///    arrays and diff by count against a cursor we keep.
/// 3. **Timestamps are token onsets on an 80 ms grid, derived from samples fed rather than a clock.**
///    Each word's end is back-filled from the next word's start, and a dropped capture buffer is
///    resynchronised with injected silence so the ASR timeline cannot drift away from the WAV's.
///
/// "320 ms" is the output cadence, not the window: the model buffers 630 ms before its first output.
public actor FluidAudioStreamingTranscriber: StreamingTranscriber {
    public nonisolated let name = "FluidAudioStreaming"
    public nonisolated let model = "parakeet-realtime-eou-120m/320ms"

    public nonisolated let segments: AsyncStream<EngineSegment>
    private nonisolated let continuation: AsyncStream<EngineSegment>.Continuation

    private let asr: StreamingEouAsrManager
    private var started = false
    /// Measured against audio *fed* rather than audio *decoded*, deliberately: the recogniser runs
    /// 310–630 ms behind what it has been given, so waiting for a second of *decoded* silence puts
    /// the text on screen at 1.4 s. Live text is for anchoring notes against while the meeting runs;
    /// the batch pass on stop is what gets read.
    ///
    /// Its hold is 400 ms, not the second the batch pass groups on — see ``StreamingSegmenter`` for
    /// why those were the same number and should not have been.
    private var segmenter = StreamingSegmenter()

    /// Our cursor into the recogniser's accumulators. It only ever moves forward, so nothing is
    /// retained here that the recogniser is already holding.
    private var ingested = 0
    /// Offset of the first sample we were handed. The capture writer pads the head of the WAV with
    /// silence back to the recording origin but does not feed that padding to us, so without this
    /// every live segment on the slower channel would land early by the padding's length.
    private var originMs: Int?
    private var fedSamples = 0
    /// Silence fed to warm the model up, discounted out of every timestamp so the recording's clock
    /// and the recogniser's stay the same clock.
    private var warmUpMs = 0
    private var partialWord = ""
    private var partialWordStartMs = 0
    private var lastTokenMs = 0

    public init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        // Constructed directly rather than through `StreamingModelVariant.createManager()`: the
        // factory returns `any StreamingAsrManager`, and the protocol has no timestamp accessors.
        asr = StreamingEouAsrManager(configuration: configuration, chunkSize: .ms320)
        (segments, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Models

    /// Where FluidAudio caches the 320 ms EOU models. Checked rather than assumed, because a missing
    /// model must degrade the transcript and never the recording.
    public static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent(Repo.parakeetEou320.folderName, isDirectory: true)
    }

    public static func modelsAreCached() -> Bool {
        ModelNames.ParakeetEOU.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
    }

    /// Downloads the live models. Onboarding's job, never recording's — this is ~80 MB and a first
    /// run of it in `start()` would put a network fetch between the user pressing record and the
    /// meeting being captured.
    public static func prepareModels(progress: @Sendable @escaping (Double) -> Void) async throws {
        let manager = StreamingEouAsrManager(chunkSize: .ms320)
        try await ModelLoadGate.shared.serialised {
            try await manager.loadModels(progressHandler: { progress($0.fractionCompleted) })
        }
        await manager.cleanup()
    }

    // MARK: - StreamingTranscriber

    public func start(channel: Channel) async throws {
        guard !started else { return }
        guard Self.modelsAreCached() else {
            throw StreamingTranscriptionError.modelsNotDownloaded(Self.modelDirectory.path)
        }
        do {
            // Serialised because FluidAudio's downloader has no in-flight de-duplication: two cold
            // loads of the same repo write into the same directory and corrupt each other.
            try await ModelLoadGate.shared.serialised { [asr] in try await asr.loadModels() }
        } catch {
            throw StreamingTranscriptionError.loadFailed(String(describing: error))
        }
        // Core ML compiles onto the Neural Engine on the *first* prediction, not at load: measured
        // 4.2 s before the first segment without this, against 1 s after it. Paying that here, on
        // one chunk of silence, means the opening sentence of the meeting is not what pays for it.
        await asr.injectSilence(0.7)
        fedSamples += 11_200
        warmUpMs = 700
        try? await asr.processBufferedAudio()
        // Silence decodes to nothing, but if it ever did, it is not part of the meeting.
        ingested = await asr.getRawTokenStrings().count
        started = true
    }

    public func feed(_ samples: [Float], atMs: Int) async throws {
        guard started, !samples.isEmpty else { return }
        if originMs == nil { originMs = atMs }

        // The recogniser's clock counts samples it was given, so a buffer the writer dropped would
        // pull every later timestamp earlier by its length. Silence keeps the two clocks equal.
        let expected = fedMs
        if atMs - expected >= 100 {
            let gap = Double(atMs - expected) / 1000
            await asr.injectSilence(gap)
            fedSamples += Int(gap * 16_000)
        }

        if let buffer = Self.buffer(from: samples) {
            try await asr.appendAudio(buffer)
            fedSamples += samples.count
            try await asr.processBufferedAudio()
        }
        await drain()
    }

    public func finish() async {
        guard started else {
            continuation.finish()
            return
        }
        started = false
        // Not `asr.finish()`: it pads the tail, decodes it, and then clears the accumulators, so the
        // last utterance would come back as a bare string with no timings. Padding it ourselves runs
        // the same tail through the normal path and keeps the timestamps.
        await asr.injectSilence(1.0)
        fedSamples += 16_000
        try? await asr.processBufferedAudio()
        await drain(closingPartialWord: true)
        for segment in segmenter.flush() { continuation.yield(segment) }
        continuation.finish()
        await asr.cleanup()
    }

    // MARK: -

    private var fedMs: Int { (originMs ?? 0) + fedSamples * 1000 / 16_000 - warmUpMs }

    /// How far the recogniser has actually decoded to, derived the way it advances: it fills a
    /// 10 080-sample window, then steps 5 120 samples per chunk, emitting the first 320 ms of each
    /// window and keeping the rest as lookahead. So it is permanently 310–630 ms behind the audio
    /// fed to it — which is why "has this word finished" has to be asked of *this* clock and not of
    /// `fedMs`, where a word mid-decode looks like a second of silence.
    private var decodedMs: Int {
        let chunks = fedSamples < 10_080 ? 0 : (fedSamples - 10_080) / 5_120 + 1
        return (originMs ?? 0) + chunks * 320 - warmUpMs
    }

    /// Poll-and-diff. Both getters hand back the accumulator arrays themselves — copy-on-write makes
    /// that a retain, not a copy — and they stay index-aligned, so a count is a valid cursor.
    private func drain(closingPartialWord force: Bool = false) async {
        let pieces = await asr.getRawTokenStrings()
        let stamps = await asr.getTokenTimestampsMs()
        let available = min(pieces.count, stamps.count)

        var words: [EngineSegment] = []
        if available > ingested {
            for index in ingested..<available {
                let piece = pieces[index]
                let ms = (originMs ?? 0) + stamps[index] - warmUpMs
                // SentencePiece: "▁" marks a word start and is not a character of the word.
                // `Tokenizer.decode` does this substitution; `getRawTokenStrings` does not.
                if piece.hasPrefix("\u{2581}") {
                    if let word = closeWord() { words.append(word) }
                    partialWord = String(piece.dropFirst())
                    partialWordStartMs = ms
                } else if partialWord.isEmpty {
                    partialWord = piece
                    partialWordStartMs = ms
                } else {
                    partialWord += piece
                }
                lastTokenMs = ms
            }
            ingested = available
        }

        // A word is only known to be over when the next one starts, which would strand the last word
        // before every pause. The decoder having moved a chunk past it is the other proof, and it is
        // the one measured here: against fed audio instead, "calibration" arrived as "calib" and
        // "ration" — the token pieces were right, the impatience was ours.
        //
        // One chunk (320 ms), not the 400 ms it was: `decodedMs` moves in 320 ms steps, so 400 was
        // buying a second step's worth of wait for nothing. Measured on three speaking rates of a
        // polysyllable-heavy script (140/175/215 wpm), 320 emits text identical to 400 — every one
        // of interferometry, unrepresentative, controversially, characterization and
        // superconductivity comes out whole — and takes 30 ms off the median and 75 ms off the worst
        // case. 240 is where it breaks: the same script comes back with "inter | ferometry",
        // "controvers | ially" and "characterizat | ion". This is the floor, not a knob to keep
        // turning.
        if force || (!partialWord.isEmpty && decodedMs - lastTokenMs > 320) {
            if let word = closeWord() { words.append(word) }
        }
        for segment in segmenter.ingest(words, fedMs: fedMs) { continuation.yield(segment) }
    }

    private func closeWord() -> EngineSegment? {
        guard !partialWord.isEmpty else { return nil }
        defer { partialWord = "" }
        // One frame of nominal duration; the segmenter back-fills the real end from the next word.
        return EngineSegment(
            startMs: partialWordStartMs, endMs: partialWordStartMs + 80, text: partialWord)
    }

    /// `appendAudio` takes an `AVAudioPCMBuffer` and nothing else — there is no `[Float]` entry
    /// point, and hand-slicing bytes past it produces an empty transcript with no error.
    private static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: ChannelWriter.target, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// Runs model loads one at a time, process-wide.
///
/// An actor alone would not do it: `await`ing inside an actor method lets the next call in. Chaining
/// each load onto the previous one's completion is what actually serialises them.
actor ModelLoadGate {
    static let shared = ModelLoadGate()
    private var tail: Task<Void, Never> = Task {}

    func serialised<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let work = Task { () async throws -> T in
            await previous.value
            return try await body()
        }
        tail = Task { _ = await work.result }
        return try await work.value
    }
}
