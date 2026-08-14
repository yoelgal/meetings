import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import MeetingsCore

/// The real streaming model, fed in real time. Downloads the Parakeet EOU 320 ms models the first
/// time (~80 MB) and needs the ANE, so it is off unless `MEETINGS_LIVE_STREAM=1` is set:
///
///     MEETINGS_LIVE_STREAM=1 MEETINGS_HOME=$(mktemp -d) swift test --filter LiveStreaming
///
/// Speech is synthesised with `say -o` straight to a file — nothing reaches the speakers.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_LIVE_STREAM"] != nil))
struct LiveStreamingTests {
    static let micLine = """
        Sofia, can you confirm the ptychography rig is free on Thursday? \
        I want to run the Torch0 calibration before the Airbus review. \
        Mateus said the alignment drifted again on Tuesday.
        """
    static let systemLine = """
        The rig is booked for Torch0 until Thursday afternoon. \
        Mateus will hand the alignment notes over on Friday. \
        Nothing else is scheduled that week.
        """

    @Test func liveSegmentsArriveWhileTheAudioIsStillPlaying() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let wav = directory.appendingPathComponent("mic.wav")
        try Self.synthesise(Self.micLine, voice: "Samantha", to: wav)

        try await Self.download()
        let transcriber = FluidAudioStreamingTranscriber()
        try await transcriber.start(channel: .mic)

        print("\nground truth: \(Self.micLine)\n")
        let run = try await Self.play(wav, into: transcriber, label: "mic")

        print(String(format: "\n%d segments, %.2f s of audio", run.segments.count, run.audioSeconds))
        for line in run.lines { print(line) }
        let latencies = run.segments.map(\.latencyMs)
        print(String(
            format: "latency from last sample of a segment to the segment landing: "
                + "min %d ms, median %d ms, max %d ms",
            latencies.min() ?? 0, Self.median(latencies), latencies.max() ?? 0))
        print("first text on screen: \(run.firstTextMs) ms after the word that produced it was fed")

        #expect(!run.segments.isEmpty)
        let transcript = run.segments.map(\.text).joined(separator: " ").lowercased()
        #expect(transcript.contains("thursday"))
        #expect(transcript.contains("rig"))
        // Real time in, real time out: the whole transcript is done within a second of the audio.
        #expect(run.wallSeconds < run.audioSeconds + 2)
    }

    /// Mic and system at once, which is what an actual call looks like. Two managers, two model
    /// loads, one ANE — the load is serialised because FluidAudio's downloader has no in-flight
    /// de-duplication.
    @Test func twoChannelsStreamConcurrently() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let micWAV = directory.appendingPathComponent("mic.wav")
        let systemWAV = directory.appendingPathComponent("system.wav")
        try Self.synthesise(Self.micLine, voice: "Samantha", to: micWAV)
        try Self.synthesise(Self.systemLine, voice: "Daniel", to: systemWAV)

        try await Self.download()
        let mic = FluidAudioStreamingTranscriber()
        let system = FluidAudioStreamingTranscriber()
        let clock = ContinuousClock()
        let loaded = try await clock.measure {
            async let a: Void = mic.start(channel: .mic)
            async let b: Void = system.start(channel: .system)
            _ = try await (a, b)
        }
        print("\nboth models loaded in \(loaded)")

        async let micRun = Self.play(micWAV, into: mic, label: "mic")
        async let systemRun = Self.play(systemWAV, into: system, label: "system")
        let (left, right) = try await (micRun, systemRun)

        for line in (left.lines + right.lines).sorted() { print(line) }
        print(String(
            format: "mic %d segments in %.2fs wall / %.2fs audio; system %d segments in %.2fs / %.2fs",
            left.segments.count, left.wallSeconds, left.audioSeconds,
            right.segments.count, right.wallSeconds, right.audioSeconds))
        #expect(!left.segments.isEmpty)
        #expect(!right.segments.isEmpty)
        #expect(left.segments.map(\.text) != right.segments.map(\.text))
    }

    // MARK: -

    struct Landed: Sendable {
        let startMs: Int
        let endMs: Int
        let text: String
        /// Wall-clock milliseconds between the audio at `endMs` being fed and this segment arriving.
        let latencyMs: Int
    }

    struct Run: Sendable {
        let segments: [Landed]
        let lines: [String]
        let audioSeconds: Double
        let wallSeconds: Double
        let firstTextMs: Int
    }

    /// Feeds a WAV at the rate a capture tap would, in 80 ms buffers, and collects what comes back.
    static func play(_ url: URL, into transcriber: FluidAudioStreamingTranscriber, label: String) async throws -> Run {
        let samples = try readSamples(url)
        let bufferFrames = 1_280  // 80 ms at 16 kHz
        let started = ContinuousClock.now

        let collector = Task { () -> [Landed] in
            var landed: [Landed] = []
            for await segment in transcriber.segments {
                let elapsed = Int((ContinuousClock.now - started) / .milliseconds(1))
                landed.append(Landed(
                    startMs: segment.startMs, endMs: segment.endMs, text: segment.text,
                    latencyMs: elapsed - segment.endMs))
            }
            return landed
        }

        var offset = 0
        while offset < samples.count {
            let end = min(offset + bufferFrames, samples.count)
            let atMs = offset * 1000 / 16_000
            // Real time: wait until this buffer would actually have been captured.
            let due = started + .milliseconds(atMs)
            try? await Task.sleep(until: due, clock: ContinuousClock())
            try await transcriber.feed(Array(samples[offset..<end]), atMs: atMs)
            offset = end
        }
        await transcriber.finish()
        let landed = await collector.value
        let wall = Double((ContinuousClock.now - started) / .milliseconds(1)) / 1000

        let lines = landed.map { segment in
            String(format: "  [%@] %6d–%6d ms  (+%4d ms)  %@", label, segment.startMs, segment.endMs,
                   segment.latencyMs, segment.text)
        }
        return Run(
            segments: landed, lines: lines,
            audioSeconds: Double(samples.count) / 16_000, wallSeconds: wall,
            firstTextMs: landed.first.map { $0.latencyMs + ($0.endMs - $0.startMs) } ?? -1)
    }

    static func download() async throws {
        guard !FluidAudioStreamingTranscriber.modelsAreCached() else { return }
        print("downloading the streaming models to \(FluidAudioStreamingTranscriber.modelDirectory.path)")
        try await FluidAudioStreamingTranscriber.prepareModels { _ in }
    }

    static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    static func synthesise(_ text: String, voice: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEI16@16000", "-v", voice, text]
        try process.run()
        process.waitUntilExit()
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// The one thing the app's live path owes the model: to not be worse than it.
///
/// `meetings fit` measured `accurate-en` at 16.4% word error on a Mac where the same Nemotron 560 ms
/// checkpoint benchmarks at 2.9%, and the transcript assembly was the suspect. It was not — driven on
/// the same audio the two paths agree word for word. What differed was the warm-up: the app fed 700
/// ms of silence to make Core ML compile, the recogniser slices from the first sample it is ever
/// handed, and 700 is not a whole number of 560 ms chunks, so the meeting began 140 ms inside a chunk
/// and every boundary after it landed inside a word. 2.9% became 4.0% for that and nothing else.
///
/// The warm-up is now thrown away with `reset()` before the meeting starts, so the app decodes what
/// a cold recogniser decodes. This pins that as an invariant rather than pinning the constant: the
/// live path must score what the model scores on the same audio, whatever either of them is doing.
///
///     MEETINGS_LIVE_STREAM=1 MEETINGS_HOME=$(mktemp -d) swift test --filter LiveStreamingAssembly
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_LIVE_STREAM"] != nil))
struct LiveStreamingAssemblyTests {
    /// Long enough for the number to mean something: on the 13 s fixture `fit` uses, two hard proper
    /// nouns are eight points of word error between them.
    static let script = LiveStreamingTests.micLine + " " + """
        The interferometry bench is the one I am worried about, because the last characterization \
        run came back unrepresentative and we shipped it anyway. \
        If the superconductivity numbers are controversially low again, we will have to redo the \
        whole sweep before the quarterly review. \
        I have asked Renata to pull the raw frames off the array and stage them somewhere we can \
        all read them. \
        Dan wants the summary by Wednesday, which means the calibration has to be finished on \
        Monday at the latest.
        """

    @Test func theAppsAssemblyCostsNoAccuracyAgainstTheModelDrivenDirectly() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let wav = directory.appendingPathComponent("assembly.wav")
        try LiveStreamingTests.synthesise(Self.script, voice: "Samantha", to: wav)
        let samples = try LiveStreamingTests.readSamples(wav)

        let variant = StreamingModelVariant.nemotron560ms
        try await FluidAudioStreamingTranscriber.prepareModels(variant: variant) { _ in }

        let direct = try await Self.throughTheManager(variant, samples: samples)
        let app = try await Self.throughTheApp(variant, samples: samples)
        let directWER = TranscriptScore.wordErrorPercent(reference: Self.script, heard: direct)
        let appWER = TranscriptScore.wordErrorPercent(reference: Self.script, heard: app)

        print("\n  manager : \(String(format: "%.1f", directWER))%  \(direct)")
        print("  app     : \(String(format: "%.1f", appWER))%  \(app)\n")

        // Half a point of slack for the tail: the app pads the last utterance with a second of
        // silence and the manager pads to a whole chunk, so the final word can differ.
        // Suspect what `start()` leaves in front of the meeting before suspecting the word assembly.
        #expect(appWER <= directWER + 0.5, "the live path lost accuracy the model did not")
    }

    // MARK: -

    /// The benchmark's path: append, decode, and read the whole transcript out at the end.
    static func throughTheManager(
        _ variant: StreamingModelVariant, samples: [Float]
    ) async throws -> String {
        guard let manager = variant.createManager() as? StreamingNemotronAsrManager else { return "" }
        try await manager.loadModels()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1_280, samples.count)
            if let buffer = FluidAudioStreamingTranscriber.buffer(from: Array(samples[offset..<end])) {
                try await manager.appendAudio(buffer)
                try await manager.processBufferedAudio()
            }
            offset = end
        }
        let text = try await manager.finishWithTokenTimings().text
        await manager.cleanup()
        return text
    }

    /// The app's path: warm up, feed, poll, assemble words, group them into segments.
    static func throughTheApp(
        _ variant: StreamingModelVariant, samples: [Float]
    ) async throws -> String {
        let transcriber = FluidAudioStreamingTranscriber(variant: variant)
        try await transcriber.start(channel: .mic)
        let collector = Task { () -> [String] in
            var pieces: [String] = []
            for await segment in transcriber.segments { pieces.append(segment.text) }
            return pieces
        }
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1_280, samples.count)
            try await transcriber.feed(Array(samples[offset..<end]), atMs: offset * 1000 / 16_000)
            offset = end
        }
        await transcriber.finish()
        return await collector.value.joined(separator: " ")
    }
}
