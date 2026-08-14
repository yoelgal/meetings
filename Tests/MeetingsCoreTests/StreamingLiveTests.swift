import AVFoundation
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
