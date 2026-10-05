import AVFoundation
import Foundation
import Testing

@testable import MeetingsCore

/// The recovery rules behind a capture source being rebuilt mid-meeting, on synthesised buffers and
/// a hand-driven clock. The real triggers — a route change, a stream ScreenCaptureKit stops — need
/// hardware and a real call; what can be got wrong quietly is decidable without either.
@Suite("Capture recovery")
struct CaptureRecoveryTests {
    let directory: URL

    init() throws {
        directory = try TestStore.makeDirectory()
    }

    static func silence(frames: AVAudioFrameCount, rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: 0, count: Int(frames))
        return buffer
    }

    // MARK: - Writer

    @Test("a restarted source is padded forward to the moment it resumed, so offsets still line up")
    func discontinuityRealignsToTheRecordingClock() throws {
        let url = directory.appendingPathComponent("system.wav")
        let origin = Date()
        let writer = try ChannelWriter(url: url, origin: origin)
        // One second of audio, captured at the origin.
        for i in 0..<10 {
            writer.append(
                AudioTests.buffer(frames: 4800, rate: 48_000, channels: 1),
                capturedAt: origin.addingTimeInterval(Double(i) * 0.1))
        }
        writer.markDiscontinuity()
        // The stream comes back eight seconds into the meeting.
        writer.append(
            AudioTests.buffer(frames: 4800, rate: 48_000, channels: 1),
            capturedAt: origin.addingTimeInterval(8))
        writer.finish()

        let file = try AVAudioFile(forReading: url)
        // 8 s of clock plus the 0.1 s buffer that resumed it, give or take the resampler's latency.
        let seconds = Double(file.length) / 16_000
        #expect(abs(seconds - 8.1) < 0.05, "file is \(seconds) s")
    }

    @Test("a stream restarted before it ever delivered is padded in full, not capped at ten seconds")
    func restartBeforeFirstBufferKeepsTheWholeGap() throws {
        let url = directory.appendingPathComponent("late.wav")
        let origin = Date()
        let writer = try ChannelWriter(url: url, origin: origin)
        // The watchdog restarted a stream that never delivered; its first buffer is 14 s in.
        writer.markDiscontinuity()
        writer.append(
            AudioTests.buffer(frames: 4800, rate: 48_000, channels: 1),
            capturedAt: origin.addingTimeInterval(14))
        writer.finish()
        #expect(writer.paddedFrames == 14 * 16_000)
    }

    @Test("a source that resumes on time is not padded, and a writer ahead of the clock is not trimmed")
    func discontinuityNeverPadsBackwards() throws {
        let url = directory.appendingPathComponent("mic.wav")
        let origin = Date()
        let writer = try ChannelWriter(url: url, origin: origin)
        for _ in 0..<20 {
            writer.append(AudioTests.buffer(frames: 4800, rate: 48_000, channels: 1), capturedAt: origin)
        }
        let before = writer.framesWritten
        writer.markDiscontinuity()
        // Claims to resume one second in, but two seconds are already written.
        writer.append(
            AudioTests.buffer(frames: 4800, rate: 48_000, channels: 1),
            capturedAt: origin.addingTimeInterval(1))
        writer.finish()
        // The one 1 600-frame buffer plus the resampler tails flushed at the discontinuity and at
        // finish — no padding, which would have been a whole second.
        #expect(writer.framesWritten - before < 4_000)
    }

    @Test("digital silence never counts as signal; a single audible buffer does")
    func lastSignalTracksOnlyRealSound() throws {
        let writer = try ChannelWriter(url: directory.appendingPathComponent("s.wav"), origin: Date())
        for _ in 0..<10 { writer.append(Self.silence(frames: 4800)) }
        #expect(writer.lastSignalAt == nil)
        let at = Date().addingTimeInterval(3)
        writer.append(AudioTests.buffer(frames: 4800, rate: 48_000, channels: 1), capturedAt: at)
        #expect(writer.lastSignalAt == at)
        writer.finish()
    }

    // MARK: - Watchdog

    typealias Watch = RecordingController.SystemAudioWatch

    @Test("silence with nothing playing is an in-person meeting, not a fault")
    func quietRoomIsLeftAlone() {
        let t0 = Date()
        var watch = Watch(startedAt: t0)
        for s in stride(from: 0.0, through: 600, by: 1) {
            let action = watch.evaluate(
                now: t0 + s, lastSignalAt: nil, buffers: Int(s) * 10, othersPlaying: false)
            #expect(action == .none, "at \(s) s")
        }
    }

    @Test("zeros while a call plays: restart first, warn only if the restart did not help, clear on sound")
    func silentWhilePlayingRestartsThenWarns() {
        let t0 = Date()
        var watch = Watch(startedAt: t0)
        var actions: [(TimeInterval, Watch.Action)] = []
        func tick(_ s: TimeInterval, signal: Date?, playing: Bool = true) {
            let action = watch.evaluate(
                now: t0 + s, lastSignalAt: signal, buffers: Int(s * 10), othersPlaying: playing)
            if action != .none { actions.append((s, action)) }
        }
        // The call is audible for the first minute, then the track goes to zeros at 60 s.
        for s in stride(from: 0.0, through: 60, by: 1) { tick(s, signal: t0 + s) }
        #expect(actions.isEmpty)
        for s in stride(from: 61.0, through: 120, by: 1) { tick(s, signal: t0 + 60) }

        // Restarted once the quiet passed 20 s, then warned 20 s after that restart failed to help.
        #expect(actions.count == 2)
        guard actions.count == 2 else { return }
        #expect(actions[0].0 == 81)
        if case .restart = actions[0].1 {} else { Issue.record("expected a restart, got \(actions[0].1)") }
        #expect(actions[1].0 == 102 && actions[1].1 == .warn)

        // Another restart is tried a minute after the first, and sound returning clears the warning.
        tick(141, signal: t0 + 60)
        if case .restart = actions.last?.1 {} else { Issue.record("expected a second restart") }
        tick(150, signal: t0 + 150)
        #expect(actions.last?.1 == .clear)
    }

    @Test("a stream that stops delivering buffers is restarted without a warning")
    func stalledStreamRestarts() {
        let t0 = Date()
        var watch = Watch(startedAt: t0)
        #expect(watch.evaluate(now: t0 + 1, lastSignalAt: nil, buffers: 10, othersPlaying: false) == .none)
        #expect(watch.evaluate(now: t0 + 5, lastSignalAt: nil, buffers: 10, othersPlaying: false) == .none)
        guard case .restart = watch.evaluate(
            now: t0 + 12, lastSignalAt: nil, buffers: 10, othersPlaying: false)
        else {
            Issue.record("a ten-second stall should restart the stream")
            return
        }
        // Buffers resume after the restart: back to normal, and never a warning for nothing playing.
        for s in 13...200 {
            #expect(watch.evaluate(
                now: t0 + Double(s), lastSignalAt: nil, buffers: s * 10, othersPlaying: false) == .none)
        }
    }
}
