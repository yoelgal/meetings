import Foundation

/// The real probe: downloads a candidate's models and runs it on this Mac's Neural Engine.
///
/// Two channels, always. A meeting decodes the microphone and the system audio at the same time on
/// one ANE, and every number anyone had for these models before this was measured on one stream —
/// which is the flattering half of the workload. A tier that keeps up alone and falls behind in
/// pairs is exactly the failure this exists to catch.
///
/// The fixture is played twice, because the two numbers cannot come from one run:
///
///   * **Paced** — every buffer handed over at the wall-clock instant a capture tap would have
///     handed it over. This is the only way "time to first text" means anything; unpaced, the model
///     is fed a whole meeting instantly and first text arrives when the CPU says so.
///   * **Unpaced** — fed as fast as it will take it, so wall time is pure decode cost and the
///     real-time factor is honest. Paced, RTFx would only ever measure the pacing.
public struct LiveFitProbe: FitProbe {
    public init() {}

    public func download(
        _ option: LocalTranscriptionOption,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        // Only the live model. The batch model of a two-model option plays no part in what is being
        // measured — it runs after the meeting, where being slower than real time costs a wait
        // rather than a transcript — and fetching 600 MB to not measure it would blow the cap.
        guard !FluidAudioStreamingTranscriber.modelsAreCached(option.liveVariant) else {
            return progress(1)
        }
        try await FluidAudioStreamingTranscriber.prepareModels(
            variant: option.liveVariant, progress: progress)
    }

    public func measure(
        _ option: LocalTranscriptionOption, fixture: SpeechFixture
    ) async throws -> FitMeasurement {
        var peak = ProcessMemory.footprintBytes() ?? 0

        let paced = try await play(option, fixture: fixture, paced: true, peak: &peak)
        let unpaced = try await play(option, fixture: fixture, paced: false, peak: &peak)

        let heard = unpaced.transcripts.joined(separator: " ")
        let reference = [fixture.mic.script, fixture.system.script].joined(separator: " ")
        return FitMeasurement(
            optionID: option.id,
            realTimeFactor: unpaced.wallSeconds > 0 ? fixture.audioSeconds / unpaced.wallSeconds : 0,
            timeToFirstTextMs: paced.firstTextMs,
            peakMemoryBytes: peak,
            audioSeconds: fixture.audioSeconds,
            wordErrorPercent: heard.isEmpty
                ? 100
                : TranscriptScore.wordErrorPercent(reference: reference, heard: heard)
        )
    }

    // MARK: -

    private struct Pass: Sendable {
        let transcripts: [String]
        let wallSeconds: Double
        /// Wall milliseconds to the first segment landing, or the whole run when none ever did —
        /// "never" has to fail the bar, not skip it.
        let firstTextMs: Int
    }

    private func play(
        _ option: LocalTranscriptionOption, fixture: SpeechFixture, paced: Bool, peak: inout Int64
    ) async throws -> Pass {
        let mic = FluidAudioStreamingTranscriber(variant: option.liveVariant)
        let system = FluidAudioStreamingTranscriber(variant: option.liveVariant)
        // Serialised inside `start`, which is what keeps two cold loads of the same repo from
        // writing over each other. Started together so the pair is loaded the way a meeting loads it.
        async let micStart: Void = mic.start(channel: .mic)
        async let systemStart: Void = system.start(channel: .system)
        _ = try await (micStart, systemStart)

        let started = ContinuousClock.now
        async let left = Self.feed(fixture.mic.samples, into: mic, paced: paced, from: started)
        async let right = Self.feed(fixture.system.samples, into: system, paced: paced, from: started)
        let (a, b) = try await (left, right)
        let wall = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000
        peak = max(peak, ProcessMemory.footprintBytes() ?? 0)

        let firstText = [a.firstTextMs, b.firstTextMs].filter { $0 >= 0 }.min()
        return Pass(
            transcripts: [a.text, b.text], wallSeconds: wall,
            firstTextMs: firstText ?? Int(wall * 1000))
    }

    private struct Channel: Sendable {
        let text: String
        let firstTextMs: Int
    }

    private static func feed(
        _ samples: [Float], into transcriber: FluidAudioStreamingTranscriber,
        paced: Bool, from started: ContinuousClock.Instant
    ) async throws -> Channel {
        let collector = Task { () -> (String, Int) in
            var pieces: [String] = []
            var first = -1
            for await segment in transcriber.segments {
                if first < 0 { first = Int((ContinuousClock.now - started) / .milliseconds(1)) }
                pieces.append(segment.text)
            }
            return (pieces.joined(separator: " "), first)
        }

        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1_280, samples.count)  // 80 ms at 16 kHz, the capture tap's size
            let atMs = offset * 1000 / 16_000
            if paced {
                try? await Task.sleep(until: started + .milliseconds(atMs), clock: ContinuousClock())
            }
            try await transcriber.feed(Array(samples[offset..<end]), atMs: atMs)
            offset = end
        }
        await transcriber.finish()
        let (text, first) = await collector.value
        return Channel(text: text, firstTextMs: first)
    }
}
