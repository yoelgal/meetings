import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

/// Records everything the machine plays to `system.wav` via a ScreenCaptureKit audio-only stream
///. "Audio-only" is a slight fiction: SCK has no filter that means "no video", so we
/// describe a display and simply never add a `.screen` output.
///
/// **The stream is restarted in place, never trusted to survive the meeting.** A real call moves
/// the audio route underneath it — AirPods connecting, a call app switching a Bluetooth headset into
/// its hands-free profile, a display coming or going — and the failure that cost real meetings was
/// not the stream dying but the stream *carrying on*: buffers kept arriving for the rest of the call,
/// every one of them bit-exact zeros. So the stream is rebuilt whenever the default output device or
/// its rate changes, whenever it stops on its own, and whenever the controller's watchdog asks
/// (``RecordingController/SystemAudioWatch``). The writer outlives every rebuild and pads the gap
/// with silence, so the file stays on the recording's clock.
///
/// Lifecycle (`start`, `stop`, `restart`) is main-actor only, which is what serialises a restart
/// against a stop. The capture state is touched only on `queue`.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yoelgal.Meetings.system-audio")
    private static let log = Logger(subsystem: "com.yoelgal.Meetings", category: "system-audio")
    /// Main actor only.
    private var stream: SCStream?
    private var running = false
    private var restarting = false
    /// Bumped by every `start`. A restart still in flight from the *previous* recording — asleep
    /// between attempts when the user stopped and started again — must not install its stream
    /// over the new session's, so it checks this after every await, not just `running`.
    private var session = 0
    private var routeObserver: OutputRouteObserver?
    /// The user stopped capture from the system's own control. Main actor. Honoured for the rest
    /// of the recording: no route change, watchdog or retry brings the stream back.
    private(set) var stoppedByUser = false
    /// Bumped every time a new stream is installed — at start, and by every successful restart,
    /// whoever asked for it. Main actor. The watchdog reads it to give a new stream its start grace.
    private(set) var generation = 0
    /// A restart asked for while one was running; main actor.
    private var pendingRestart: String?
    /// The user's stop, read from where the delegate records it first. `stoppedByUser` follows on
    /// the main actor a hop later; until it does, this is the one that is already true.
    var userStoppedCapture: Bool {
        queue.sync { (stopError as? SCStreamError)?.code == .userStopped }
    }
    private var restartCount = 0
    /// Everything below is written only on `queue`.
    private var writer: ChannelWriter?
    private var bufferCount = 0
    private var lastFormat: AVAudioFormat?
    private var stopError: Error?

    /// A silent check — unlike `SCShareableContent`, which *prompts* when the state is
    /// notDetermined and is therefore a request dressed up as a query.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Live transcription's tap on the resampled 16 kHz stream, forwarded to the writer when the
    /// stream starts. Set before `start`; the writer only exists from then on.
    var onSamples16k: (([Float], Int) -> Void)?

    var level: Float { writer?.level ?? 0 }
    var framesWritten: Int64 { queue.sync { writer?.framesWritten ?? 0 } }
    /// Why this track stopped growing, when it has. See ``ChannelWriter/writeFailure``.
    var writeFailure: ChannelWriter.WriteFailure? { queue.sync { writer?.writeFailure } }
    var buffersReceived: Int { queue.sync { bufferCount } }
    /// The watchdog's two reads in one hop onto the sample queue rather than two.
    var watchSnapshot: (buffers: Int, lastSignalAt: Date?) {
        queue.sync { (bufferCount, writer?.lastSignalAt) }
    }
    /// The ASBD actually delivered, which is not necessarily the one we asked for.
    var deliveredFormat: AVAudioFormat? { queue.sync { lastFormat } }
    /// Set when the stream is gone for good — the user stopped it from the menu bar, or every
    /// attempt to restart it failed.
    var failure: Error? { queue.sync { stopError } }
    /// When a buffer with any sound in it last arrived. See ``ChannelWriter/lastSignalAt``.
    var lastSignalAt: Date? { queue.sync { writer?.lastSignalAt } }
    /// How many times the stream has been rebuilt this recording. Main actor.
    @MainActor var restarts: Int { restartCount }

    @MainActor
    func start(writingTo url: URL, origin: Date) async throws {
        guard Self.isAuthorized else {
            throw RecordingError.systemAudioUnavailable(
                "Meetings needs Screen & System Audio Recording under Privacy & Security in "
                    + "System Settings")
        }
        let writer: ChannelWriter
        do {
            writer = try ChannelWriter(url: url, origin: origin)
        } catch {
            throw RecordingError.systemAudioUnavailable(
                "cannot write \(url.lastPathComponent): \(error)")
        }
        writer.onSamples16k = onSamples16k
        queue.sync {
            self.writer = writer
            self.bufferCount = 0
            self.stopError = nil
        }
        do {
            stream = try await makeStream()
            generation += 1
        } catch {
            queue.sync { self.writer = nil }
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        running = true
        stoppedByUser = false
        restartCount = 0
        session += 1
        routeObserver = OutputRouteObserver { [weak self] in
            Task { @MainActor in await self?.restart(because: "the audio output changed") }
        }
    }

    /// A fresh stream on whatever display exists *now* — the one the last stream was attached to
    /// may be the monitor that was just unplugged.
    @MainActor
    private func makeStream() async throws -> SCStream {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            throw RecordingError.systemAudioUnavailable("\(error)")
        }
        guard let display = content.displays.first else {
            throw RecordingError.systemAudioUnavailable("no display to attach the audio stream to")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000  // ask for the native rate and resample ourselves
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true  // our own chimes must not land in the transcript
        config.captureMicrophone = false  // the mic is AVAudioEngine's job, on its own track
        // Video is unavoidable, only unconsumed: SCK composites for the filter whether or not we
        // read it, and the 1920×1080 @ 60 fps default is real GPU for a two-hour meeting. 2×2 at
        // 1 fps is the floor — zero is an invalid parameter, not a smaller number.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            throw RecordingError.systemAudioUnavailable("\(error)")
        }
        return stream
    }

    /// Tear the stream down and build a new one into the same file. A no-op when not recording or
    /// when a restart is already under way — route changes arrive in bursts, and the one restart
    /// in flight will attach to whatever the route settles on.
    ///
    /// A few attempts a couple of seconds apart, because the moment a route changes is the moment
    /// the new device is least ready. Only when all of them fail is the track declared lost.
    @MainActor
    func restart(because reason: String) async {
        guard running, !stoppedByUser, !userStoppedCapture else { return }
        // A route change landing while a restart is under way is not dropped: the stream being
        // built may be attaching to the route that just went away. It runs once more after.
        guard !restarting else {
            pendingRestart = reason
            return
        }
        restarting = true
        let mine = session
        defer {
            if session == mine {
                restarting = false
                if let again = pendingRestart {
                    pendingRestart = nil
                    Task { @MainActor in await self.restart(because: again) }
                }
            }
        }
        var current: Bool { running && session == mine && !stoppedByUser && !userStoppedCapture }
        Self.log.notice("restarting system audio: \(reason, privacy: .public)")
        if let old = stream {
            stream = nil
            // Detach first: if `stopCapture` fails the old stream keeps running, and it must not
            // keep writing into the file the new one is about to write to.
            try? old.removeStreamOutput(self, type: .audio)
            try? await old.stopCapture()
        }
        guard current else { return }
        // After `stopCapture` returns no callback is still writing, so the tail and the gap are
        // the writer's alone to deal with.
        queue.sync { writer?.markDiscontinuity() }

        var lastError: Error?
        for attempt in 0..<Self.restartAttempts {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            guard current else { return }
            do {
                let fresh = try await makeStream()
                // Stopped while the new stream was starting: it must not outlive the recording.
                guard current else {
                    // Detached first, as the old stream is: until its stop lands it would otherwise
                    // write into whatever writer the next recording has installed.
                    try? fresh.removeStreamOutput(self, type: .audio)
                    try? await fresh.stopCapture()
                    return
                }
                stream = fresh
                generation += 1
                restartCount += 1
                queue.sync { stopError = nil }
                return
            } catch {
                lastError = error
            }
        }
        Self.log.error("system audio could not be restarted: \(String(describing: lastError), privacy: .public)")
        queue.sync { stopError = lastError }
    }

    static let restartAttempts = 3

    /// Idempotent. Flushes on the sample queue *after* `stopCapture` returns, so no callback can
    /// still be writing into a file we are closing.
    @MainActor
    func stop() async {
        guard running else { return }
        running = false
        // A stop clears a restart in flight; its own session check makes it stand down.
        restarting = false
        pendingRestart = nil
        routeObserver?.invalidate()
        routeObserver = nil
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        queue.sync {
            writer?.finish()
            writer = nil
        }
    }

    // MARK: - SCStreamOutput

    // `of type:` — not `ofType:`. The protocol's only method is optional, so the wrong selector
    // compiles cleanly and gives you a stream that starts, reports no error, and delivers nothing.
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0,
            let pcm = Self.pcmBuffer(from: sampleBuffer)
        else { return }
        bufferCount += 1
        lastFormat = pcm.format
        writer?.append(pcm, capturedAt: Self.captureDate(of: sampleBuffer))
    }

    /// The wall-clock instant a buffer's first frame was captured, from its host-time stamp — so
    /// the padding after a restart is measured to when the audio happened, not to when the
    /// callback got round to it.
    private static func captureDate(of sampleBuffer: CMSampleBuffer) -> Date {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard pts.isValid else { return Date() }
        let age = CMTimeGetSeconds(CMTimeSubtract(now, pts))
        // A stamp from the future, or from minutes ago, is not a host-time stamp.
        guard age.isFinite, age >= 0, age < 5 else { return Date() }
        return Date().addingTimeInterval(-age)
    }

    // MARK: - SCStreamDelegate

    /// -3821 systemStoppedStream and -3817 userStopped arrive here — sleep, a display going away, a
    /// permission hiccup. A system-side stop is restarted; the meeting is still going, and the
    /// writer is still open. A user stop (the menu bar's "stop sharing") is the user's decision and
    /// is honoured: the track is declared lost and the mic carries on.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if (error as? SCStreamError)?.code == .userStopped {
            queue.async { self.stopError = error }
            Task { @MainActor in
                self.stoppedByUser = true
                self.routeObserver?.invalidate()
                self.routeObserver = nil
            }
            return
        }
        let stopped = ObjectIdentifier(stream)
        Task { @MainActor in
            // A stream that is no longer the current one is a restart's own teardown.
            guard let current = self.stream, ObjectIdentifier(current) == stopped else { return }
            self.stream = nil
            await self.restart(because: "the stream stopped: \(error)")
        }
    }

    // MARK: - Is anything playing?

    /// Whether any process other than this one is sending audio to an output device right now.
    ///
    /// This is what tells a quiet call from a broken capture: a system track of pure zeros while
    /// nothing plays is an in-person meeting, while the same zeros with a call app running its
    /// output is the track being lost. Core Audio's process objects (macOS 14.2+) answer it directly
    /// and without any permission. Our own process is excluded because the mic's voice-processing
    /// unit keeps an output running for the whole recording.
    static func othersArePlayingAudio() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return false }
        var processes = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr
        else { return false }
        let me = getpid()
        return processes.contains { process in
            readUInt32(process, kAudioProcessPropertyIsRunningOutput) == 1
                && pid_t(bitPattern: readUInt32(process, kAudioProcessPropertyPID) ?? 0) != me
        }
    }

    private static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
        -> UInt32?
    {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    // MARK: -

    /// The copying form. The zero-copy `withAudioBufferList` variant hands back memory that SCK
    /// reuses the moment this callback returns, and the writer is not guaranteed to be done with it.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buffer
    }
}

/// Calls `onChange` when the default output device changes, or the current one changes rate — the
/// two shapes a route change takes from here. AirPods connecting is the first; a call app moving a
/// Bluetooth headset from A2DP to its hands-free profile is often only the second.
///
/// Debounced: a single route change fires several of these within a few hundred milliseconds, and
/// the stream should be rebuilt once, against the route it settled on.
private final class OutputRouteObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yoelgal.Meetings.output-route")
    private let onChange: @Sendable () -> Void
    private var pending: DispatchWorkItem?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?

    private static let defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static let nominalRate = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.watchCurrentDevice()
            self?.fire()
        }
        defaultListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), [Self.defaultOutput], queue, listener)
        queue.sync { watchCurrentDevice() }
    }

    /// Remove both listeners. On `queue`, which is where every other touch of this state happens —
    /// and not in `deinit`, which can run on `queue` itself when a listener held the last reference.
    func invalidate() {
        queue.sync {
            if let defaultListener {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), [Self.defaultOutput], queue,
                    defaultListener)
            }
            if let rateListener, device != kAudioObjectUnknown {
                AudioObjectRemovePropertyListenerBlock(device, [Self.nominalRate], queue, rateListener)
            }
            defaultListener = nil
            rateListener = nil
            pending?.cancel()
            pending = nil
        }
    }

    /// On `queue`. Moves the rate listener to whichever device is the default now.
    private func watchCurrentDevice() {
        if let rateListener, device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, [Self.nominalRate], queue, rateListener)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), [Self.defaultOutput], 0, nil, &size, &id)
        device = id
        guard id != kAudioObjectUnknown else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fire() }
        rateListener = listener
        AudioObjectAddPropertyListenerBlock(id, [Self.nominalRate], queue, listener)
    }

    /// On `queue`.
    private func fire() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
