import AVFoundation
import Foundation
import Testing

@testable import MeetingsCore

/// The promise: "A crash mid-meeting loses seconds and the meeting is recoverable from the WAVs via the
/// batch pass."
///
/// Every test here failed before the recovery sweep existed. `WAVRepair` already brought the audio
/// back; nothing brought the *meeting* back, so a `kill -9` mid-recording left a row at `recording`
/// that no code path could ever move — the batch queue looks for `transcribing`, and Stop throws
/// `notRecording` because the session died with the process.
@Suite final class RecoveryTests {
    let directory: URL
    let audioRoot: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        store = try TestStore.open(directory)
    }

    deinit { TestStore.remove(directory) }

    // MARK: - Fixtures

    @discardableResult
    private func audio(
        _ meetingID: String,
        _ name: String,
        seconds: Double,
        frequency: Double = 440,
        unclosed: Bool = false
    ) throws -> URL {
        let folder = audioRoot.appendingPathComponent(meetingID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try AudioFixture.write(
            to: url, seconds: seconds, frequency: frequency, sampleRate: 16_000, channels: 1)
        if unclosed { try Self.unfinaliseHeader(at: url) }
        return url
    }

    /// Put the file back in the state a `kill -9` leaves it: every sample on disk, the `data` chunk
    /// size never written. That is what makes it read as zero frames — see the WAVRepair note.
    private static func unfinaliseHeader(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var offset: UInt64 = 12
        while offset + 8 <= size {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
            let id = String(bytes: header.prefix(4), encoding: .ascii) ?? ""
            let chunkSize = header.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            }
            if id == "data" {
                try handle.seek(toOffset: offset + 4)
                try handle.write(contentsOf: Data(repeating: 0, count: 4))
                try handle.synchronize()
                return
            }
            offset += 8 + UInt64(chunkSize) + UInt64(chunkSize % 2)
        }
    }

    /// Default `now` is past the liveness window: the fixtures were written a millisecond ago, and
    /// to the sweep a file that new means a recorder is still holding it. The tests that care about
    /// that rule pass their own clock.
    private func sweep(owning owned: Set<String> = [], now: Date = .now + 60) throws -> [RecordingRecovery.Outcome] {
        try RecordingRecovery.sweep(store: store, owning: owned, audioRoot: audioRoot, now: now)
    }

    // MARK: - 1. The stranded recording

    @Test("a crash mid-recording is recovered to transcribing, with ended_at from the audio")
    func recoversAStrandedRecording() throws {
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let meeting = try store.createMeeting(Meeting(
            title: "Torch0 weekly", state: .recording, startedAt: startedAt))
        let mic = try audio(meeting.id, "mic.wav", seconds: 16.29, unclosed: true)
        try audio(meeting.id, "system.wav", seconds: 12.0, unclosed: true)

        // The state a relaunch actually finds: the audio is on disk and reads as nothing.
        #expect(try AVAudioFile(forReading: mic).length == 0, "an unclosed WAV reads as empty")

        let outcomes = try sweep(now: .now + 3600)
        #expect(outcomes.map(\.disposition) == [.recovered])

        let recovered = try #require(try store.meeting(id: meeting.id))
        #expect(recovered.state == .transcribing, "the batch queue only ever looks for transcribing")
        // From the repaired audio, not the clock. The clock is months past `startedAt`, because
        // that is when the app was relaunched.
        // `ended_at` is INTEGER seconds like every date in this schema, so 16.29 s of audio lands on
        // 16 — and nowhere near the 3600 the clock would have given.
        let length = try #require(recovered.endedAt).timeIntervalSince(startedAt)
        #expect(length == 16, "ended_at came from the audio: got \(length)s")
        #expect(recovered.audioPath == mic.deletingLastPathComponent().path)
        #expect(try store.transcriptIssues(meetingID: meeting.id).isEmpty)
    }

    @Test("the recovered meeting is what the batch queue picks up next")
    func theRecoveredMeetingJoinsTheQueue() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try audio(meeting.id, "mic.wav", seconds: 2, unclosed: true)

        let service = TranscriptionService(store: store, engine: nil, audioRoot: audioRoot)
        #expect(await service.pendingMeetingIDs().isEmpty, "nothing is pending while it says recording")

        _ = try sweep()
        #expect(await service.pendingMeetingIDs() == [meeting.id])
    }

    @Test("a meeting whose WAVs are empty lands somewhere honest rather than silently at ready")
    func anEmptyRecordingIsReportedRatherThanPassedOff() throws {
        let startedAt = Date(timeIntervalSince1970: 1_770_000_000)
        let meeting = try store.createMeeting(Meeting(
            title: "Nothing came through", state: .recording, startedAt: startedAt))
        try audio(meeting.id, "mic.wav", seconds: 0)

        #expect(try sweep().map(\.disposition) == [.nothingCaptured])

        let swept = try #require(try store.meeting(id: meeting.id))
        #expect(swept.state == .ready)
        #expect(swept.endedAt == startedAt, "a zero-length recording ended when it began")

        let issues = try store.transcriptIssues(meetingID: meeting.id)
        #expect(issues.count == 2, "both channels are accounted for, got \(issues.map(\.channel))")
        #expect(issues.allSatisfy { $0.kind == .capture })
        #expect(issues[0].sentence.hasPrefix("The mic channel was not captured:"))
        #expect(try store.meetingIDsWithTranscriptIssues().contains(meeting.id))
    }

    @Test("a meeting another process is still recording is left strictly alone")
    func aLiveRecordingIsNotStolen() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try audio(meeting.id, "mic.wav", seconds: 2, unclosed: true)

        // A live writer appends every few milliseconds, so its WAV was just touched.
        #expect(try sweep(now: .now).map(\.disposition) == [.stillLive])
        #expect(try store.meeting(id: meeting.id)?.state == .recording)

        // And the caller's own live session is excluded even before the mtime is consulted.
        let stale = Date().addingTimeInterval(RecordingRecovery.liveGraceSeconds + 60)
        #expect(try sweep(owning: [meeting.id], now: stale).isEmpty)
        #expect(try store.meeting(id: meeting.id)?.state == .recording)

        // Once the writes stop, the same sweep recovers it.
        #expect(try sweep(now: stale).map(\.disposition) == [.recovered])
        #expect(try store.meeting(id: meeting.id)?.state == .transcribing)
    }

    @Test("the sweep claims each meeting once, so two of them racing cannot double-move a row")
    func theClaimIsExactlyOnce() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try audio(meeting.id, "mic.wav", seconds: 2, unclosed: true)
        let later = Date().addingTimeInterval(RecordingRecovery.liveGraceSeconds + 60)

        #expect(try sweep(now: later).count == 1)
        #expect(try sweep(now: later).isEmpty, "the second sweep finds nothing at recording")

        // A meeting that legitimately started recording again is not swept back out from under it.
        try store.updateMeeting(id: meeting.id) { $0.state = .recording }
        #expect(try sweep(owning: [meeting.id], now: later).isEmpty)
        #expect(try store.meeting(id: meeting.id)?.state == .recording)
    }

    @Test("sweepOnLaunch is the app's entry point and never throws")
    func theLaunchEntryPointWorks() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        // No audio directory at all — the harshest input the launch path can be handed.
        let outcomes = RecordingRecovery.sweepOnLaunch(store: store, audioRoot: audioRoot)
        #expect(outcomes.map(\.meetingID) == [meeting.id])
        #expect(try store.meeting(id: meeting.id)?.state == .ready)
    }

    /// **The ordinary case: the app crashes and you reopen it straight away.** The WAV was touched a
    /// second ago, so the launch sweep is right to call it live — and used to stop there, leaving
    /// the phantom `recording` row, red dot and climbing clock, for the whole session. The window is
    /// a window, not a verdict: once it expires the sweep has to come back.
    ///
    /// `grace` is a tenth of a second here for the same reason the app's is fifteen: it is one
    /// window. The test would otherwise have to sit through the real one.
    @Test("relaunching inside the grace window still recovers the meeting, a window later")
    func aCrashInsideTheGraceWindowIsRecoveredAnyway() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try audio(meeting.id, "mic.wav", seconds: 2, unclosed: true)

        // The relaunch: the dead recorder's file is younger than the window, so nothing moves yet.
        let atLaunch = RecordingRecovery.sweepOnLaunch(
            store: store, audioRoot: audioRoot, grace: 0.1)
        #expect(atLaunch.map(\.disposition) == [.stillLive])
        #expect(try store.meeting(id: meeting.id)?.state == .recording)

        try await waitFor("the meeting to leave recording") {
            try self.store.meeting(id: meeting.id)?.state == .transcribing
        }
        let recovered = try #require(try store.meeting(id: meeting.id))
        #expect(recovered.endedAt != nil, "ended_at came from the audio on the re-sweep too")
        #expect(try store.transcriptIssues(meetingID: meeting.id).isEmpty)
    }

    /// And the re-sweep is held to the rule the launch sweep is held to: a recorder that is still
    /// appending keeps its meeting, however many times the sweep comes back to look.
    @Test("the re-sweep will not steal a recording something is still writing to")
    func theResweepStillRefusesALiveRecording() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        let mic = try audio(meeting.id, "mic.wav", seconds: 2, unclosed: true)

        // One second, not 0.3. The window has to be long enough to survive a `Task.sleep` that
        // overruns, and under a parallel suite a 20 ms sleep can come back a quarter of a second
        // late. At 0.3 s a single overrun put the last write outside the window, the re-sweep
        // correctly recovered a recording the test still called live, and the failure looked like a
        // bug in the sweep rather than in the cadence the test was simulating.
        let grace = 1.0
        #expect(RecordingRecovery.sweepOnLaunch(store: store, audioRoot: audioRoot, grace: grace)
            .map(\.disposition) == [.stillLive])

        // A live writer, doing the one thing the sweep reads it by: appending. The cadence is the
        // real one in miniature, a capture buffer landing orders of magnitude more often than the
        // window is long, and 2.5 s of it is two windows' worth of re-sweeps, every one of which
        // must decline.
        //
        // The gap is measured rather than assumed. A sleep that overran the window means the writer
        // stopped looking live through no fault of the code, so the assertion would be testing the
        // machine's load; the write is redone and that round is skipped instead.
        for _ in 0..<125 {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: mic.path)
            let before = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(20))
            guard ContinuousClock.now - before < .seconds(grace) else { continue }
            #expect(try store.meeting(id: meeting.id)?.state == .recording,
                    "a live recording was swept out from under its writer")
        }

        // Then the writer dies, and the loop that has been declining all along picks it up.
        try await waitFor("the recording to be recovered once the writes stop") {
            try self.store.meeting(id: meeting.id)?.state == .transcribing
        }
    }

    /// The re-sweep runs off a detached task, so the store is what the test watches rather than the
    /// clock.
    ///
    /// The timeout is a backstop against hanging, not a measurement of how quick the sweep is: the
    /// loop returns the instant the condition holds, so a generous deadline costs nothing when the
    /// code works. It was two seconds, which is plenty on an idle machine and not plenty at all when
    /// the whole suite runs in parallel and the detached task is competing with fifty other ones for
    /// a core. That is what made this test flaky, and a flaky test that guards crash recovery is
    /// worse than no test, because the next person learns to re-run it.
    private func waitFor(
        _ what: String,
        timeout: Duration = .seconds(30),
        until condition: () throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for \(what)")
    }

    // MARK: - 2. The silent microphone

    @Test("a mic that delivered pure digital silence says so, in a sentence a human reads")
    @MainActor
    func aSilentMicChannelIsRecorded() async throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        // frequency 0 is sin(0) — every sample bit-exact zero, which is what macOS hands a tap when
        // microphone access is denied.
        let mic = try audio(meeting.id, "mic.wav", seconds: 30, frequency: 0)
        #expect(try AVAudioFile(forReading: mic).length == 480_000, "a full-length WAV, not an empty one")

        let controller = RecordingController(
            store: store, transcription: TranscriptionService(store: store))
        controller.auditCapturedAudio(
            meetingID: meeting.id, in: mic.deletingLastPathComponent())

        let issues = try store.transcriptIssues(meetingID: meeting.id)
        #expect(issues.count == 1)
        #expect(issues[0].channel == .mic)
        #expect(issues[0].kind == .capture)
        #expect(issues[0].sentence.contains("your own voice was not captured"))
        #expect(issues[0].sentence.contains("Privacy & Security"))
    }

    /// **The same recording must not be described two different ways depending on how it ended.**
    /// An in-person meeting with nothing playing records a system track of bit-exact zeros — that is
    /// the ordinary outcome, and the clean-stop path has always known it (`auditCapturedAudio` is
    /// mic-only). The crash path did not, so a laptop that died mid-standup came back accusing the
    /// system track of a fault every in-person meeting has.
    @Test("a silent system track is as unremarkable after a crash as it is after a clean stop")
    func aSilentSystemTrackIsNotAFaultOnTheCrashPathEither() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try audio(meeting.id, "mic.wav", seconds: 30, unclosed: true)
        // frequency 0: 30 s of bit-exact zeros — nobody else was in the room.
        try audio(meeting.id, "system.wav", seconds: 30, frequency: 0, unclosed: true)

        #expect(try sweep().map(\.disposition) == [.recovered])
        #expect(try store.transcriptIssues(meetingID: meeting.id).isEmpty,
                "an in-person meeting is not a system-audio fault")
    }

    @Test("the mic half of that rule is untouched: a dead mic still says so after a crash")
    func aSilentMicIsStillReportedOnTheCrashPath() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try audio(meeting.id, "mic.wav", seconds: 30, frequency: 0, unclosed: true)
        try audio(meeting.id, "system.wav", seconds: 30, unclosed: true)

        #expect(try sweep().map(\.disposition) == [.recovered])
        let issues = try store.transcriptIssues(meetingID: meeting.id)
        #expect(issues.map(\.channel) == [.mic])
        #expect(issues.first?.sentence.contains("your own voice was not captured") == true)
    }

    @Test("an empty system track is still reported, because that is not silence")
    func anEmptySystemTrackIsStillReported() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        try audio(meeting.id, "mic.wav", seconds: 30, unclosed: true)
        try audio(meeting.id, "system.wav", seconds: 0)

        #expect(try sweep().map(\.disposition) == [.recovered])
        let issues = try store.transcriptIssues(meetingID: meeting.id)
        #expect(issues.map(\.channel) == [.system])
        #expect(issues.first?.sentence.contains("nothing on it to transcribe") == true)
    }

    @Test("a mic that recorded a quiet room is not accused of anything")
    @MainActor
    func aQuietButLiveMicIsLeftAlone() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        // A real input floor: inaudible, but not one sample is zero.
        let folder = audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("mic.wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 160_000))
        buffer.frameLength = 160_000
        // One LSB of a 16-bit sample, alternating: the noise floor of any working converter.
        for frame in 0..<160_000 {
            buffer.floatChannelData?[0][frame] = frame.isMultiple(of: 2) ? 1.0 / 32_767 : -1.0 / 32_767
        }
        try file.write(from: buffer)

        let controller = RecordingController(
            store: store, transcription: TranscriptionService(store: store))
        controller.auditCapturedAudio(meetingID: meeting.id, in: folder)
        #expect(try store.transcriptIssues(meetingID: meeting.id).isEmpty)
    }

    @Test("under a second of silence is not enough to call a microphone dead")
    func theRuleNeedsAWholeSecond() throws {
        let short = try audio("short", "mic.wav", seconds: 0.4, frequency: 0)
        let long = try audio("long", "mic.wav", seconds: 1.5, frequency: 0)
        #expect(try #require(ChannelAudit.read(short)).deliveredNoSignal == false)
        #expect(try #require(ChannelAudit.read(long)).deliveredNoSignal)
    }

    /// The reason the capture verdict now needs its own `kind`: the batch pass reads a silent WAV
    /// perfectly well, calls the channel a success, and used to clear the warning on its way past.
    @Test("the transcriber's all-clear cannot take down a capture failure")
    func aCaptureIssueOutlivesASuccessfulTranscription() throws {
        let meeting = try store.createMeeting(TestStore.meeting(state: .ready))
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .mic, kind: .transcription, reason: "mic.wav is truncated"))
        try store.recordTranscriptIssue(TranscriptIssue(
            meetingID: meeting.id, channel: .mic, kind: .capture,
            reason: ChannelAudit.noSignalReason(.mic)))
        #expect(try store.transcriptIssues(meetingID: meeting.id).count == 2)

        #expect(try store.clearTranscriptIssue(meetingID: meeting.id, channel: .mic))

        let left = try store.transcriptIssues(meetingID: meeting.id)
        #expect(left.map(\.kind) == [.capture], "only the transcriber's own verdict comes down")
    }
}
