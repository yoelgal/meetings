import AVFoundation
import Foundation
import Testing

@testable import MeetingsCore

/// The real thing: Parakeet TDT v3, two real WAVs, the real store. Downloads ~600 MB the first time
/// and takes seconds of ANE time, so it is off unless `MEETINGS_LIVE_TRANSCRIBE=1` is set. Run it
/// against a throwaway store:
///
///     MEETINGS_LIVE_TRANSCRIBE=1 MEETINGS_HOME=$(mktemp -d) swift test --filter LiveBatchPass
///
/// Speech is synthesised with `say -o` straight to a file — nothing ever reaches the speakers.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_LIVE_TRANSCRIBE"] != nil))
struct LiveBatchPassTests {
    static let micLine = """
        Sofia, can you confirm the ptychography rig is free on Thursday? \
        I want to run the Torch0 calibration before the Airbus review.
        """
    static let systemLine = """
        The rig is booked for Torch0 until Thursday afternoon. \
        Mateus will hand the alignment notes over on Friday.
        """

    @Test func transcribesBothChannelsAndRemapsNoteAnchors() async throws {
        try Paths.ensureDirectories()
        let store = try MeetingStore()
        let service = TranscriptionService(store: store)

        let meeting = try store.createMeeting(Meeting(
            title: "Torch0 rig handover",
            state: .recording,
            startedAt: Date()
        ))
        let audio = Paths.audioDirectory(meetingID: meeting.id)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Self.synthesise(Self.micLine, voice: "Samantha", to: audio.appendingPathComponent("mic.wav"))
        try Self.synthesise(Self.systemLine, voice: "Daniel", to: audio.appendingPathComponent("system.wav"))

        // A live transcript and a note anchored into it, exactly as a recording would leave them.
        let live = try store.insertSegments([
            TranscriptSegment(meetingID: meeting.id, channel: .mic, tStartMs: 0, tEndMs: 4_000,
                              text: "sofia can you confirm the rig", pass: .live),
            TranscriptSegment(meetingID: meeting.id, channel: .system, tStartMs: 4_000, tEndMs: 8_000,
                              text: "booked until thursday", pass: .live),
        ])
        let note = try store.addNote(meetingID: meeting.id, tOffsetMs: 5_000, text: "Book the rig for Thursday")
        print("note \(note.id ?? -1) anchored to live segment \(note.anchorSegmentID ?? -1)")

        let downloadProgress = Recorder()
        let clock = ContinuousClock()
        let prepared = try await clock.measure {
            try await service.prepareModels(progress: { downloadProgress.append($0) })
        }
        let seen = downloadProgress.values
        print("prepareModels: \(seen.count) progress callbacks in \(prepared)")
        print("  first ten: \(seen.prefix(10).map { String(format: "%.3f", $0) }.joined(separator: " "))")
        print("  last five: \(seen.suffix(5).map { String(format: "%.3f", $0) }.joined(separator: " "))")
        #expect(!seen.isEmpty)
        #expect(await service.modelsReady())

        let passProgress = Recorder()
        let elapsed = try await clock.measure {
            try await service.runBatchPass(meetingID: meeting.id, progress: { passProgress.append($0) })
        }
        print("runBatchPass progress: \(passProgress.values.map { String(format: "%.2f", $0) }.joined(separator: " "))")

        let segments = try store.segments(meetingID: meeting.id)
        print("\n\(segments.count) segments for meeting \(meeting.id):")
        for segment in segments {
            print("  [\(segment.channel.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))] "
                + "\(segment.tStartMs)–\(segment.tEndMs) ms  (\(segment.pass.rawValue))  \(segment.text)")
        }

        let anchor = try #require(try store.notes(meetingID: meeting.id).first?.anchorSegmentID)
        let anchored = try #require(segments.first { $0.id == anchor })
        print("\nnote now anchored to segment \(anchor) (pass=\(anchored.pass.rawValue), "
            + "channel=\(anchored.channel.rawValue)): \(anchored.text)")
        #expect(anchored.pass == .final)
        #expect(!live.compactMap(\.id).contains(anchor))

        let audioSeconds = try Self.duration(audio.appendingPathComponent("mic.wav"))
            + Self.duration(audio.appendingPathComponent("system.wav"))
        let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(String(format: "\n%.2f s of audio in %.2f s wall clock — real-time factor %.1fx",
                     audioSeconds, wall, audioSeconds / wall))
        print("state: \(try #require(try store.meeting(id: meeting.id)).state.rawValue)")

        #expect(segments.contains { $0.channel == .mic })
        #expect(segments.contains { $0.channel == .system })
        #expect(segments.allSatisfy { $0.pass == .final })
        #expect(try store.meeting(id: meeting.id)?.state == .ready)
    }

    // MARK: -

    /// `say -o` renders to a file. It never opens an output device, so this is silent.
    static func synthesise(_ text: String, voice: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEI16@16000", "-v", voice, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.unreadableAudio(url, "say exited \(process.terminationStatus)")
        }
    }

    static func duration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        var values: [Double] { lock.withLock { storage } }
        func append(_ value: Double) { lock.withLock { storage.append(value) } }
    }
}

