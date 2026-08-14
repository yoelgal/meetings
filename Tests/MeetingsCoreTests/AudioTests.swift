import AVFoundation
import Foundation
import Testing

@testable import MeetingsCore

/// Everything here runs on synthesised buffers, never on a device: `swift test` must not light the
/// orange mic indicator or need a permission. The real capture paths are proven by the harness in
/// `scratchpad/audio-proof`, which does open a microphone and a ScreenCaptureKit stream.
@Suite("Audio")
struct AudioTests {
    let directory: URL

    init() throws {
        directory = try TestStore.makeDirectory()
    }

    // MARK: - Fixtures

    /// A tone at `frequency`, in the shape a capture callback would hand us.
    static func buffer(
        frames: AVAudioFrameCount, rate: Double, channels: AVAudioChannelCount,
        frequency: Double = 440, amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        // Above two channels there is no implicit layout, so a discrete one has to be supplied —
        // which is exactly the shape the nine-channel routes in the wild arrive in.
        let format: AVAudioFormat
        if channels > 2 {
            let layout = AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false,
                channelLayout: layout)
        } else {
            format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels,
                interleaved: false)!
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            let data = buffer.floatChannelData![c]
            for i in 0..<Int(frames) {
                data[i] = amplitude * Float(sin(2 * .pi * frequency * Double(i) / rate))
            }
        }
        return buffer
    }

    static func peak(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        return peak
    }

    // MARK: - Resample and write

    @Test("48 kHz stereo in, 16 kHz mono WAV out, at a third of the frames")
    func resamplesToSixteenKMono() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        for _ in 0..<10 {
            writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 2))
        }
        writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        // 48 000 input frames at 48 kHz is one second, so one second at 16 kHz out — every sample,
        // because the drain at finish flushes what the resampler was still holding. The leading
        // pad back to the origin is however long opening the file took and is discounted here.
        let audio = file.length - writer.paddedFrames
        #expect(abs(audio - 16_000) < 200, "got \(audio) converted frames of \(file.length)")
        #expect(try Self.peak(of: url) > 0.4)
    }

    @Test("a nine-channel route is averaged down rather than dropped or amplified")
    func mixesDownAboveTwoChannels() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        for _ in 0..<5 {
            writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 9, amplitude: 0.5))
        }
        writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 7_000)
        let peak = try Self.peak(of: url)
        // Averaging, not summing: nine identical channels at 0.5 must not arrive at 4.5.
        #expect(peak > 0.4 && peak < 0.6, "peak \(peak)")
    }

    @Test("a track that starts late is padded back to the recording origin")
    func padsToOrigin() throws {
        let url = directory.appendingPathComponent("system.wav")
        // The stream took half a second to deliver its first buffer, as ScreenCaptureKit does.
        let writer = try ChannelWriter(url: url, origin: Date().addingTimeInterval(-0.5))
        writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1))
        writer.finish()

        let file = try AVAudioFile(forReading: url)
        // 8 000 frames of silence for the half second, plus 1 600 for the tone.
        #expect(file.length > 9_000, "got \(file.length) frames")

        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let data = buffer.floatChannelData![0]
        #expect(data[0] == 0)
        #expect(data[4_000] == 0)
    }

    // MARK: - Crash safety

    @Test("an unclosed WAV reads as zero frames and the repair pass gets them all back")
    func repairsAnUnclosedFile() throws {
        let url = directory.appendingPathComponent("mic.wav")
        // Deliberately never call finish(), and keep the writer alive for the rest of the test so
        // its AVAudioFile is never released. That is exactly the state a crash mid-meeting leaves
        // on disk: every sample written, the header never finalised.
        let writer = try ChannelWriter(url: url, origin: Date())
        for _ in 0..<10 { writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1)) }

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(size > 30_000, "the samples should already be on disk, got \(size) bytes")
        #expect(try AVAudioFile(forReading: url).length == 0, "an unclosed WAV reads as empty")

        try WAVRepair.repair(at: url)

        // A second of audio back, less the ~100 ms still inside the mastering resampler's filter
        // when the process died. That tail is the honest cost of a crash; the rest is recovered.
        let repaired = try AVAudioFile(forReading: url)
        #expect(repaired.length > 14_000, "got \(repaired.length) frames")
        #expect(try Self.peak(of: url) > 0.4, "the recovered frames must be the real audio")
        withExtendedLifetime(writer) {}
    }

    @Test("repairing a healthy file changes nothing")
    func repairIsIdempotent() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1))
        writer.finish()

        let before = try Data(contentsOf: url)
        try WAVRepair.repair(at: url)
        try WAVRepair.repair(at: url)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("the launch sweep walks every meeting directory")
    func repairsTheWholeTree() throws {
        let root = directory.appendingPathComponent("audio", isDirectory: true)
        var unclosed: [ChannelWriter] = []
        for id in ["meeting-a", "meeting-b"] {
            let meetingDirectory = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
            let writer = try ChannelWriter(
                url: meetingDirectory.appendingPathComponent("mic.wav"), origin: Date())
            for _ in 0..<10 { writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1)) }
            unclosed.append(writer)
        }

        let repaired = WAVRepair.repairTree(at: root)
        #expect(repaired.count == 2)
        for url in repaired { #expect(try AVAudioFile(forReading: url).length > 1_000) }
        withExtendedLifetime(unclosed) {}

        // And the second sweep changes nothing. This is the launch path: every healthy WAV in the
        // store used to be rewritten and fsynced on every launch, for the life of the store, to put
        // back the eight bytes it already had.
        let before = try repaired.map { try modified($0) }
        #expect(WAVRepair.repairTree(at: root).isEmpty)
        #expect(try repaired.map { try modified($0) } == before)
    }

    private func modified(_ url: URL) throws -> Date {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    // MARK: - Metering

    @Test("the meter tracks the signal and falls back to zero when the track stops")
    func metersTheSignal() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        #expect(writer.level == 0)
        writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1, amplitude: 0.8))
        #expect(writer.level > 0.5)
        writer.finish()
        #expect(writer.level == 0)
    }

    // MARK: - Live-transcriber seam

    @Test("the 16 kHz hook sees the same samples the file does, with their offset")
    func feedsTheSampleHook() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        var offsets: [Int] = []
        var total = 0
        writer.onSamples16k = { samples, atMs in
            offsets.append(atMs)
            total += samples.count
        }
        for _ in 0..<5 { writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1)) }
        writer.finish()

        // Five appends plus the drain at finish, so the hook sees every sample the file does.
        #expect(offsets.count >= 6)
        // The first hook offset is exactly the leading pad back to the origin — however long opening
        // the file took. Asserting a wall-clock bound here would flake under load and teach the wrong
        // lesson: the pad is correct, so the assertion is that the hook agrees with it.
        #expect(offsets.first! == Int(writer.paddedFrames * 1000 / 16_000), "offsets \(offsets)")
        #expect(offsets == offsets.sorted(), "offsets must advance monotonically: \(offsets)")
        #expect(abs(total - 8_000) < 300, "\(total) samples")
    }
}
