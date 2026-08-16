import AVFoundation
import os
import Foundation
import Testing

@testable import MeetingsCore

/// Attacks on the recording path under conditions a healthy Mac never shows: the device changing
/// underneath the writer, a full disk, hours of buffers, and float garbage in the samples.
@Suite("Robust recording")
struct RobustRecordingTests {
    let directory: URL

    init() throws {
        directory = try TestStore.makeDirectory()
    }

    static func buffer(
        frames: AVAudioFrameCount, rate: Double, channels: AVAudioChannelCount,
        frequency: Double = 440, amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        AudioTests.buffer(
            frames: frames, rate: rate, channels: channels, frequency: frequency,
            amplitude: amplitude)
    }

    // MARK: - The device changing underneath the writer

    @Test("the nominal rate changing mid-recording does not pitch-shift the rest of the meeting")
    func survivesSampleRateChange() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        // One second at each rate: 48 kHz (AirPods on A2DP), then 16 kHz (the same AirPods
        // switching to HFP the moment the mic opens), then 44.1 kHz.
        for _ in 0..<10 { writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 2)) }
        for _ in 0..<10 { writer.append(Self.buffer(frames: 1600, rate: 16_000, channels: 1)) }
        for _ in 0..<10 { writer.append(Self.buffer(frames: 4410, rate: 44_100, channels: 1)) }
        writer.finish()

        let file = try AVAudioFile(forReading: url)
        let audio = file.length - writer.paddedFrames
        // Three seconds in, three seconds out. A cached converter would have written the second
        // second at a third of its length (and three times its pitch).
        #expect(abs(audio - 48_000) < 1_500, "got \(audio) frames, expected ~48000")
        #expect(try AudioTests.peak(of: url) > 0.4)
    }

    @Test("the channel count changing mid-recording keeps writing")
    func survivesChannelCountChange() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        for _ in 0..<5 { writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1)) }
        for _ in 0..<5 { writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 9)) }
        for _ in 0..<5 { writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 2)) }
        writer.finish()

        let audio = try AVAudioFile(forReading: url).length - writer.paddedFrames
        #expect(abs(audio - 24_000) < 1_500, "got \(audio) frames")
    }

    // MARK: - Pathological input

    @Test("NaN and infinity in the buffer do not poison the rest of the file")
    func survivesNaNAndInfinity() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1))
        let poison = Self.buffer(frames: 4800, rate: 48_000, channels: 1)
        let data = poison.floatChannelData![0]
        for i in 0..<1200 { data[i] = .nan }
        for i in 1200..<2400 { data[i] = .infinity }
        for i in 2400..<3600 { data[i] = -.infinity }
        writer.append(poison)
        #expect(writer.level.isFinite, "the meter must not go NaN: \(writer.level)")
        for _ in 0..<5 { writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1)) }
        writer.finish()

        let file = try AVAudioFile(forReading: url)
        // Seven buffers of 100 ms, so 0.7 s at 16 kHz: the poisoned one costs its own samples and
        // nothing else's.
        let audio = file.length - writer.paddedFrames
        #expect(abs(audio - 11_200) < 400, "got \(audio) frames")
        #expect(try AudioTests.peak(of: url) > 0.4, "the good audio after the poison must survive")
        #expect(writer.level.isFinite, "meter \(writer.level)")
    }

    @Test("a hook consumer never sees a non-finite sample")
    func hookSamplesAreFinite() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        var bad = 0
        writer.onSamples16k = { samples, _ in bad += samples.filter { !$0.isFinite }.count }
        let poison = Self.buffer(frames: 4800, rate: 48_000, channels: 1)
        let data = poison.floatChannelData![0]
        for i in 0..<4800 where i % 3 == 0 { data[i] = .nan }
        writer.append(poison)
        writer.finish()
        #expect(bad == 0, "\(bad) non-finite samples reached the live transcriber")
    }

    @Test("a zero-frame buffer is a no-op")
    func ignoresEmptyBuffer() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        let empty = Self.buffer(frames: 4800, rate: 48_000, channels: 1)
        empty.frameLength = 0
        writer.append(empty)
        #expect(writer.framesWritten == 0)
        writer.append(Self.buffer(frames: 4800, rate: 48_000, channels: 1))
        writer.finish()
        #expect(try AVAudioFile(forReading: url).length > 1_000)
    }

    @Test("an 8 kHz device upsamples rather than being dropped")
    func handlesEightKilohertzDevice() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        for _ in 0..<10 { writer.append(Self.buffer(frames: 800, rate: 8_000, channels: 1)) }
        writer.finish()
        let audio = try AVAudioFile(forReading: url).length - writer.paddedFrames
        #expect(abs(audio - 16_000) < 500, "got \(audio) frames")
        #expect(try AudioTests.peak(of: url) > 0.4)
    }

    // MARK: - A very long recording

    /// **This one has to have the process to itself, so it is not in the default run.**
    ///
    /// `residentBytes()` is `mach_task_basic_info.resident_size` — the RSS of the whole test
    /// process, not of the writer. swift-testing runs suites in parallel inside that one process,
    /// and appending three hours of buffers takes about a hundred seconds, so the window between
    /// the baseline and the second reading is not this test's window: it is the entire test run's.
    /// Measured here, 844 lines of other tests' output landed between the two readings, and every
    /// allocation any of them made counted as growth against a 32 MB threshold.
    ///
    /// That is the flake this gate closes. It failed twice immediately after the round-7 merge —
    /// which put `StoreOpenRaceTests` (forty subprocesses) and the snapshot tests (`VACUUM INTO`
    /// of a whole store) into that same parallel pool — and then passed nine times running, because
    /// whether a heavy test lands inside the window is a scheduling accident. A green run of a test
    /// like that proves nothing, and this suite is what decides a release.
    ///
    /// Run alone the reading means what it says it means, so the check gets stronger, not weaker.
    /// `scripts/verify.sh` runs it as its own step, the way it already runs the editor suites.
    @Test("three hours of buffers do not grow memory", .timeLimit(.minutes(5)),
          .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_MEMORY_CHECK"] == "1"))
    func longRecordingIsFlat() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        var seen = 0
        writer.onSamples16k = { samples, _ in seen += samples.count }
        let chunk = Self.buffer(frames: 4800, rate: 48_000, channels: 1)

        // Warm up, then measure: the first appends allocate the converter and the file's buffers.
        for _ in 0..<600 { writer.append(chunk) }
        let baseline = residentBytes()
        // Three hours at 100 ms a buffer.
        for _ in 0..<(3 * 3600 * 10) { writer.append(chunk) }
        let growth = Int64(residentBytes()) - Int64(baseline)
        writer.finish()

        // Printed on the way past, not only on failure: the number is the whole point of the test,
        // and a headroom that has quietly shrunk from 30 MB to 2 is the warning before the break.
        print("longRecordingIsFlat: RSS grew \(growth / (1 << 20)) MB of a 32 MB budget")

        #expect(seen > 16_000 * 3 * 3600, "the hook must have seen the whole meeting")
        #expect(growth < 32 << 20, "RSS grew \(growth / (1 << 20)) MB over three hours")
    }

    // MARK: - The disk filling up under a live recording

    /// The one test here that needs a real filesystem to run out of space, so it makes one: a 3 MB
    /// disk image, which a 16 kHz mono WAV fills in about ninety seconds of audio.
    ///
    /// Before this, a full disk was the worst outcome an audio path has — `AVAudioFile.write`
    /// throws, the buffer was dropped on the floor, the meter went on bouncing off the last value
    /// it saw and the clock went on climbing. The recording simply stopped growing and nobody was
    /// told, in the one situation where telling them is the whole fix.
    @Test("a full disk is reported rather than silently truncating the recording")
    func reportsAFullDisk() throws {
        let volume = try #require(TestVolume(megabytes: 3), "could not make a disk image")
        defer { volume.detach() }

        let url = volume.mountPoint.appendingPathComponent("mic.wav")
        let writer = try ChannelWriter(url: url, origin: Date())
        let chunk = Self.buffer(frames: 4800, rate: 48_000, channels: 1)
        for _ in 0..<1_200 { writer.append(chunk) }  // two minutes of audio into three megabytes
        let failure = try #require(writer.writeFailure, "the disk filled and nothing said so")
        #expect(failure.reason.contains("disk filled up"), "\(failure.reason)")
        #expect(failure.reason.contains("mic.wav"), "\(failure.reason)")
        #expect(failure.framesDropped > 16_000, "\(failure.framesDropped) frames dropped")
        writer.finish()

        // And what was captured before the disk gave out is on disk, whole and readable.
        let audit = try #require(ChannelAudit.read(url))
        #expect(audit.durationMs > 60_000, "only \(audit.durationMs) ms survived")
        #expect(!audit.isDigitalSilence)
    }

    // MARK: - The mic going away mid-meeting

    @MainActor
    @Test("a mic that stops delivering is called stalled, and start latency is not")
    func noticesAStalledMic() {
        let t0 = Date()
        var progress: (frames: Int64, at: Date)?
        // Before the first buffer there is nothing to be suspicious of.
        #expect(!RecordingController.hasStalled(frames: 0, progress: &progress, now: t0))
        #expect(!RecordingController.hasStalled(frames: 0, progress: &progress, now: t0 + 60))
        // Audio arrives, then stops.
        #expect(!RecordingController.hasStalled(frames: 16_000, progress: &progress, now: t0 + 1))
        #expect(!RecordingController.hasStalled(frames: 16_000, progress: &progress, now: t0 + 5))
        #expect(RecordingController.hasStalled(frames: 16_000, progress: &progress, now: t0 + 12))
        // And a track that starts moving again is not stalled.
        #expect(!RecordingController.hasStalled(frames: 32_000, progress: &progress, now: t0 + 13))
        #expect(!RecordingController.hasStalled(frames: 48_000, progress: &progress, now: t0 + 30))
    }

    // MARK: - Dying politely

    @MainActor
    @Test("a real SIGTERM reaches the handler instead of killing the process")
    func trapsTermination() async throws {
        let arrived = OSAllocatedUnfairLock(initialState: false)
        let sources = RecordingController.trap([SIGTERM]) { arrived.withLock { $0 = true } }
        defer {
            for source in sources { source.cancel() }
            signal(SIGTERM, SIG_DFL)
        }
        // If the guard does not work this line ends the whole test run, which is the honest way to
        // find out. The controller's own handler finalises the WAVs and then exits; here the
        // exiting is all that is left out.
        kill(getpid(), SIGTERM)
        for _ in 0..<500 where !arrived.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(arrived.withLock { $0 }, "the SIGTERM handler never ran")
    }

    /// Resident size of this process, for the growth check.
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

/// A small writable volume, for the one failure that cannot be faked: a filesystem with no room
/// left on it. `hdiutil` rather than a fixture because the failure has to come from the kernel —
/// the point of the test is what `AVAudioFile` does when the write really does not fit.
struct TestVolume {
    let mountPoint: URL
    private let image: URL

    init?(megabytes: Int) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetings-volume-\(UUID().uuidString)", isDirectory: true)
        image = base.appendingPathExtension("dmg")
        mountPoint = base
        guard (try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true))
            != nil,
            Self.run(["hdiutil", "create", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname",
                      "MeetingsTest", "-quiet", image.path]),
            // -nobrowse: nothing appears on the desktop of whoever is running the tests.
            Self.run(["hdiutil", "attach", image.path, "-mountpoint", mountPoint.path, "-nobrowse",
                      "-noautoopen", "-quiet"])
        else {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: image)
            return nil
        }
    }

    func detach() {
        _ = Self.run(["hdiutil", "detach", mountPoint.path, "-force", "-quiet"])
        try? FileManager.default.removeItem(at: mountPoint)
        try? FileManager.default.removeItem(at: image)
    }

    private static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
