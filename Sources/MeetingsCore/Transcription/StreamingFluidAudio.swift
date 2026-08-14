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
    public nonisolated let model: String

    public nonisolated let segments: AsyncStream<EngineSegment>
    private nonisolated let continuation: AsyncStream<EngineSegment>.Continuation

    /// Which streaming checkpoint this instance runs. Everything below that used to be a constant of
    /// the 320 ms EOU model — the cache directory, the decode-progress arithmetic, the wait before a
    /// word is called finished — is derived from it, so a new tier is a new case in ``Backend`` and
    /// a row in ``LocalTranscriptionOption/all``, not a fork of this actor.
    private nonisolated let variant: StreamingModelVariant
    private let backend: Backend
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

    /// Defaults to the tier that has always shipped, so every existing call site — the recording
    /// controller's test seam, the live tests — keeps meaning what it meant.
    public init(variant: StreamingModelVariant = .parakeetEou320ms) {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        self.variant = variant
        self.model = variant.rawValue
        // Constructed concretely rather than through `StreamingModelVariant.createManager()`: the
        // factory returns `any StreamingAsrManager`, and the token accessors this actor is built on
        // are optional capabilities the protocol does not carry.
        backend = Backend(variant: variant, configuration: configuration)
        (segments, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - Models

    /// Where FluidAudio caches this variant's models. Checked rather than assumed, because a missing
    /// model must degrade the transcript and never the recording.
    ///
    /// The two families nest differently and both layouts are copied from the manager that does the
    /// downloading, not guessed: EOU roots itself at `Models/parakeet-eou-streaming` and *then*
    /// appends a folder name that starts with `parakeet-eou-streaming` again, and Nemotron roots at
    /// `Models`. Getting this wrong does not fail loudly — it reports "not downloaded" forever and
    /// re-fetches on every launch.
    public static func modelDirectory(for variant: StreamingModelVariant = .parakeetEou320ms) -> URL {
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let root = variant.engineFamily == .parakeetEou
            ? models.appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
            : models
        return root.appendingPathComponent(variant.repo.folderName, isDirectory: true)
    }

    /// Kept as a property so the existing call sites and log lines read unchanged.
    public static var modelDirectory: URL { modelDirectory(for: .parakeetEou320ms) }

    public static func modelsAreCached(_ variant: StreamingModelVariant = .parakeetEou320ms) -> Bool {
        let directory = modelDirectory(for: variant)
        // Each family is checked with the same file list its own loader checks. Nemotron's
        // `requiredModels` includes the fused decoder+joint, which only some tiers ship, so asking
        // for all of it would report a complete 560 ms download as missing; its loader looks at the
        // int8 encoder alone and so does this.
        let required: [String]
        switch variant.engineFamily {
        case .parakeetEou:
            required = Array(ModelNames.ParakeetEOU.requiredModels)
        case .nemotron:
            required = [ModelNames.NemotronStreaming.encoderInt8File]
        case .parakeetUnified:
            // A third manager shape that ``Backend`` cannot drive — no `injectSilence`, and its
            // timings drain rather than accumulate. Reporting its models as never cached is the
            // honest answer for a variant this app cannot run; an option naming one would fail
            // visibly rather than transcribe nothing quietly.
            return false
        }
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Downloads the live models. Onboarding's job, never recording's — a first run of it in
    /// `start()` would put a network fetch between the user pressing record and the meeting being
    /// captured.
    public static func prepareModels(
        variant: StreamingModelVariant = .parakeetEou320ms,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let backend = Backend(variant: variant, configuration: nil)
        try await ModelLoadGate.shared.serialised {
            try await backend.load(progress: progress)
        }
        await backend.cleanup()
    }

    // MARK: - StreamingTranscriber

    public func start(channel: Channel) async throws {
        guard !started else { return }
        guard Self.modelsAreCached(variant) else {
            throw StreamingTranscriptionError.modelsNotDownloaded(Self.modelDirectory(for: variant).path)
        }
        do {
            // Serialised because FluidAudio's downloader has no in-flight de-duplication: two cold
            // loads of the same repo write into the same directory and corrupt each other.
            try await ModelLoadGate.shared.serialised { [backend] in try await backend.load(progress: { _ in }) }
        } catch {
            throw StreamingTranscriptionError.loadFailed(String(describing: error))
        }
        // Core ML compiles onto the Neural Engine on the *first* prediction, not at load: measured
        // 4.2 s before the first segment without this, against 1 s after it. Paying that here, on
        // one chunk of silence, means the opening sentence of the meeting is not what pays for it.
        await backend.injectSilence(0.7)
        fedSamples += 11_200
        warmUpMs = 700
        try? await backend.processBuffered()
        // Silence decodes to nothing, but if it ever did, it is not part of the meeting.
        ingested = await backend.tokens().count
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
            await backend.injectSilence(gap)
            fedSamples += Int(gap * 16_000)
        }

        if let buffer = Self.buffer(from: samples) {
            try await backend.append(buffer)
            fedSamples += samples.count
            try await backend.processBuffered()
        }
        await drain()
    }

    public func finish() async {
        guard started else {
            continuation.finish()
            return
        }
        started = false
        // Not the manager's own `finish()`: it pads the tail, decodes it, and then clears the
        // accumulators, so the last utterance would come back as a bare string with no timings.
        // (Nemotron does the same — `finishWithTokenTimings` snapshots, then clears.) Padding it
        // ourselves runs the same tail through the normal path and keeps the timestamps.
        await backend.injectSilence(1.0)
        fedSamples += 16_000
        try? await backend.processBuffered()
        await drain(closingPartialWord: true)
        for segment in segmenter.flush() { continuation.yield(segment) }
        continuation.finish()
        await backend.cleanup()
    }

    // MARK: -

    private var fedMs: Int { (originMs ?? 0) + fedSamples * 1000 / 16_000 - warmUpMs }

    /// How far the recogniser has actually decoded to, derived the way it advances: it fills a
    /// 10 080-sample window, then steps 5 120 samples per chunk, emitting the first 320 ms of each
    /// window and keeping the rest as lookahead. So it is permanently 310–630 ms behind the audio
    /// fed to it — which is why "has this word finished" has to be asked of *this* clock and not of
    /// `fedMs`, where a word mid-decode looks like a second of silence.
    private var decodedMs: Int {
        let chunks: Int
        switch variant.engineFamily {
        case .parakeetEou:
            chunks = fedSamples < 10_080 ? 0 : (fedSamples - 10_080) / 5_120 + 1
        default:
            // Nemotron buffers and decodes whole chunks with no prefill window and no right context
            // held back — `processBufferedAudio` loops while the buffer holds a full chunk — so how
            // far it has decoded is simply how many whole chunks it has been handed.
            chunks = fedSamples / (chunkStepMs * 16)
        }
        return (originMs ?? 0) + chunks * chunkStepMs - warmUpMs
    }

    /// How far `decodedMs` advances per step, which is also the shortest honest wait before a word
    /// with no successor can be called finished.
    ///
    /// 320 for EOU is measured, not chosen: at 240 the same script comes back with "inter |
    /// ferometry" and "controvers | ially", and 400 buys a whole extra step for output identical to
    /// 320. For a Nemotron tier it is the chunk size, because a shorter wait cannot resolve —
    /// `decodedMs` does not move at all inside a chunk.
    private nonisolated var chunkStepMs: Int { variant.nemotronChunkSize?.rawValue ?? 320 }

    /// Poll-and-diff over whichever accumulator this backend keeps. Both shapes hand back the array
    /// itself — copy-on-write makes that a retain, not a copy — and both only ever append, so a
    /// count is a valid cursor.
    private func drain(closingPartialWord force: Bool = false) async {
        let decoded = await backend.tokens()
        let available = decoded.count

        var words: [EngineSegment] = []
        if available > ingested {
            for index in ingested..<available {
                let piece = decoded[index].piece
                let ms = (originMs ?? 0) + decoded[index].ms - warmUpMs
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
        if force || (!partialWord.isEmpty && decodedMs - lastTokenMs > chunkStepMs) {
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
    static func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
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

/// The two manager shapes this app can drive, behind the five calls the transcriber above makes.
///
/// They are not interchangeable through `StreamingAsrManager`: the token accessors are optional
/// capability protocols, only `StreamingEouAsrManager` adopts them, and `injectSilence` exists on
/// EOU alone. What they do share is a buffer you append 16 kHz mono into and an accumulator of
/// decoded tokens that only grows, and that is the whole of what poll-and-diff needs.
///
/// The one asymmetry worth naming: EOU exposes raw SentencePiece pieces and a parallel array of
/// millisecond stamps, and Nemotron exposes `TokenTiming`s carrying the same piece with a start time
/// in seconds. Both are normalised to `(piece, ms)` here so the word assembly above — the part that
/// knows about `▁`, partial words and when a word is over — is written once and runs for both.
private enum Backend: Sendable {
    case eou(StreamingEouAsrManager)
    case nemotron(StreamingNemotronAsrManager)

    init(variant: StreamingModelVariant, configuration: sending MLModelConfiguration?) {
        let mlConfiguration = configuration ?? MLModelConfiguration()
        switch variant.engineFamily {
        case .nemotron:
            self = .nemotron(StreamingNemotronAsrManager(
                configuration: mlConfiguration,
                requestedChunkSize: variant.nemotronChunkSize ?? .ms560))
        default:
            self = .eou(StreamingEouAsrManager(
                configuration: mlConfiguration,
                chunkSize: variant.eouChunkSize ?? .ms320))
        }
    }

    func load(progress: @Sendable @escaping (Double) -> Void) async throws {
        switch self {
        case .eou(let manager):
            try await manager.loadModels(progressHandler: { progress($0.fractionCompleted) })
        case .nemotron(let manager):
            try await manager.loadModels(progressHandler: { progress($0.fractionCompleted) })
        }
    }

    func append(_ buffer: sending AVAudioPCMBuffer) async throws {
        switch self {
        case .eou(let manager): try await manager.appendAudio(buffer)
        case .nemotron(let manager): try await manager.appendAudio(buffer)
        }
    }

    func processBuffered() async throws {
        switch self {
        case .eou(let manager): try await manager.processBufferedAudio()
        case .nemotron(let manager): try await manager.processBufferedAudio()
        }
    }

    /// EOU has this natively. For Nemotron it is a buffer of zeros through the ordinary path, which
    /// is the same thing: silence keeps the recogniser's sample clock equal to the recording's when
    /// the capture writer dropped a buffer, and warms Core ML up before the meeting's first word.
    func injectSilence(_ seconds: Double) async {
        switch self {
        case .eou(let manager):
            await manager.injectSilence(seconds)
        case .nemotron(let manager):
            let frames = Int(seconds * 16_000)
            guard frames > 0, let buffer = FluidAudioStreamingTranscriber.buffer(
                from: [Float](repeating: 0, count: frames))
            else { return }
            try? await manager.appendAudio(buffer)
        }
    }

    /// Every token decoded so far, oldest first, normalised. Cumulative — never draining — so the
    /// caller's cursor stays valid.
    func tokens() async -> [(piece: String, ms: Int)] {
        switch self {
        case .eou(let manager):
            let pieces = await manager.getRawTokenStrings()
            let stamps = await manager.getTokenTimestampsMs()
            return (0..<min(pieces.count, stamps.count)).map { (pieces[$0], stamps[$0]) }
        case .nemotron(let manager):
            return await manager.getTokenTimings().map {
                ($0.token, Int(($0.startTime * 1000).rounded()))
            }
        }
    }

    func cleanup() async {
        switch self {
        case .eou(let manager): await manager.cleanup()
        case .nemotron(let manager): await manager.cleanup()
        }
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
