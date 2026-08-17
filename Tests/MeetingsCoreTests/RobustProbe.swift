import AVFoundation
import FluidAudio
import Foundation
import Network
import Testing

@testable import MeetingsCore

/// SCRATCH PROBE — deleted before the unit lands. Drives the real engine against a doctored
/// environment so each failure can be written down with what the user actually sees.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_PROBE"] != nil))
struct RobustProbe {
    static func say(_ text: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEI16@16000", "-v", "Samantha", text]
        try process.run()
        process.waitUntilExit()
    }

    /// One meeting, one real mic.wav, the real local engine. Prints the outcome.
    @Test func batchPassAgainstWhateverCacheIsOnDisk() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        let store = try TestStore.open(directory)
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        let meetingDirectory = audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try Self.say("The Torch0 calibration is on Thursday.",
                     to: meetingDirectory.appendingPathComponent("mic.wav"))
        _ = try store.insertSegment(TestStore.segment(
            meetingID: meeting.id, from: 0, to: 2_000, text: "rough live text", pass: .live))

        let service = TranscriptionService(store: store, engine: nil, audioRoot: audioRoot)
        do {
            try await service.runBatchPass(meetingID: meeting.id, progress: { _ in })
            print("PROBE pass: OK")
        } catch {
            print("PROBE pass THREW: \(String(describing: error))")
            print("PROBE localizedDescription: \(error.localizedDescription)")
        }
        let after = try #require(try store.meeting(id: meeting.id))
        print("PROBE meeting state: \(after.state.rawValue)")
        print("PROBE segments: \(try store.segments(meetingID: meeting.id).map { "\($0.pass.rawValue):\($0.text)" })")
        print("PROBE issues: \(try store.transcriptIssues(meetingID: meeting.id).map(\.sentence))")
    }

    /// Same, through the queue, which is what an app launch actually runs.
    @Test func queueAgainstWhateverCacheIsOnDisk() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        let store = try TestStore.open(directory)
        let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
        let meetingDirectory = audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: true)
        try Self.say("The Torch0 calibration is on Thursday.",
                     to: meetingDirectory.appendingPathComponent("mic.wav"))

        let service = TranscriptionService(store: store, engine: nil, audioRoot: audioRoot)
        await service.resumePendingOnLaunch()
        await service.waitForQueue()
        print("PROBE queue state: \(try #require(try store.meeting(id: meeting.id)).state.rawValue)")
        print("PROBE queue issues: \(try store.transcriptIssues(meetingID: meeting.id).map(\.sentence))")
    }

    /// Pathological audio, straight at the engine.
    @Test func pathologicalAudio() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let engine = StreamingFileEngine(variant: LocalTranscriber.current.variant)

        var cases: [(String, URL)] = []

        func file(_ name: String, _ build: (URL) throws -> Void) rethrows -> URL {
            let url = directory.appendingPathComponent(name)
            FileHandle.standardError.write(Data("PROBE building \(name)\n".utf8))
            try build(url)
            return url
        }

        cases.append(("0.1 s", try file("tiny.wav") { url in
            try Self.writePCM(to: url, sampleRate: 16_000, frames: 1_600, generator: { _ in 0.1 })
        }))
        cases.append(("pure silence 5 s", try file("silence.wav") { url in
            try Self.writePCM(to: url, sampleRate: 16_000, frames: 80_000, generator: { _ in 0 })
        }))
        cases.append(("pure noise 5 s", try file("noise.wav") { url in
            var seed: UInt64 = 12_345
            try Self.writePCM(to: url, sampleRate: 16_000, frames: 80_000, generator: { _ in
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
            })
        }))
        cases.append(("exotic rate 11025", try file("exotic.wav") { url in
            try Self.writePCM(to: url, sampleRate: 11_025, frames: 22_050, generator: { i in
                sin(Float(i) * 0.05) * 0.3
            })
        }))
        cases.append(("not audio", try file("notaudio.wav") { url in
            try Data("this is not a wav at all, it is a text file".utf8).write(to: url)
        }))
        cases.append(("empty file", try file("empty.wav") { url in
            try Data().write(to: url)
        }))
        cases.append(("header lies (truncated data)", try file("liar.wav") { url in
            try Self.writePCM(to: url, sampleRate: 16_000, frames: 48_000, generator: { i in
                sin(Float(i) * 0.05) * 0.3
            })
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 8_000)
            try handle.close()
        }))
        cases.append(("missing file", directory.appendingPathComponent("nope.wav")))

        FileHandle.standardError.write(Data("PROBE preparing engine\n".utf8))
        try await engine.prepare(progress: { _ in })
        FileHandle.standardError.write(Data("PROBE engine ready\n".utf8))
        for (label, url) in cases {
            FileHandle.standardError.write(Data("PROBE trying \(label)\n".utf8))
            do {
                let start = Date()
                let segments = try await engine.transcribe(url, vocabulary: [], progress: { _ in })
                print("PROBE audio [\(label)]: OK \(segments.count) segments in "
                    + String(format: "%.2f s", Date().timeIntervalSince(start))
                    + " -> \(segments.prefix(2).map(\.text))")
            } catch {
                print("PROBE audio [\(label)]: THREW \(String(describing: error))")
            }
        }
    }

    /// Offline, no usable models, five meetings queued: how many download attempts?
    @Test func queueWithNoModels() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        let store = try TestStore.open(directory)
        for _ in 0..<5 {
            let meeting = try store.createMeeting(TestStore.meeting(state: .transcribing))
            let meetingDirectory = audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
            try FileManager.default.createDirectory(
                at: meetingDirectory, withIntermediateDirectories: true)
            try Self.say("Hello.", to: meetingDirectory.appendingPathComponent("mic.wav"))
        }
        let service = TranscriptionService(store: store, engine: nil, audioRoot: audioRoot)
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await service.resumePendingOnLaunch()
            await service.waitForQueue()
        }
        print("PROBE queue-no-models elapsed \(elapsed)")
        print("PROBE queue-no-models states: "
            + "\(try store.meetings(state: .transcribing).count) still transcribing")
        print("PROBE queue-no-models issues: "
            + "\(try store.meetingIDsWithTranscriptIssues().count) meetings flagged")
    }

    /// The migration case: 200 meetings through the queue with a stub engine.
    @Test func twoHundredMeetings() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        let store = try TestStore.open(directory)
        var poison: String?
        for index in 0..<200 {
            let meeting = try store.createMeeting(TestStore.meeting(
                title: "Meeting \(index)", state: .transcribing,
                startedAt: TestStore.referenceDate.addingTimeInterval(Double(index))))
            let meetingDirectory = audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
            try FileManager.default.createDirectory(
                at: meetingDirectory, withIntermediateDirectories: true)
            try Data("RIFF".utf8).write(to: meetingDirectory.appendingPathComponent("mic.wav"))
            if index == 3 { poison = meeting.id }
        }
        // One meeting that always throws, third in line.
        let engine = ProbeEngine(poisonDirectory: poison)
        let service = TranscriptionService(store: store, engine: engine, audioRoot: audioRoot)
        let before = Self.residentBytes()
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await service.resumePendingOnLaunch()
            await service.waitForQueue()
        }
        let after = Self.residentBytes()
        print("PROBE 200 meetings in \(elapsed); rss \(before / 1_048_576) MB -> \(after / 1_048_576) MB")
        print("PROBE still transcribing: \(try store.meetings(state: .transcribing).map(\.title))")
        print("PROBE ready: \(try store.meetings(state: .ready).count)")
        print("PROBE transcribe calls: \(await engine.calls)")
        print("PROBE issues: \(try store.meetingIDsWithTranscriptIssues().count)")
        // Second launch: does it retry the poison meeting forever?
        await service.resumePendingOnLaunch()
        await service.waitForQueue()
        print("PROBE after a second resume, calls: \(await engine.calls)")
    }

    actor ProbeEngine: TranscriptionEngine {
        nonisolated let name = "probe"
        nonisolated let model = "probe"
        let poisonDirectory: String?
        var calls = 0
        init(poisonDirectory: String?) { self.poisonDirectory = poisonDirectory }
        func prepare(progress: @Sendable (Double) -> Void) async throws { progress(1) }
        func vocabularyReport() async -> VocabularyBiasingReport? { nil }
        func release() async {}
        func transcribe(
            _ audio: URL, vocabulary: [VocabularyTerm], progress: @Sendable (Double) -> Void
        ) async throws -> [EngineSegment] {
            calls += 1
            if let poisonDirectory, audio.path.contains(poisonDirectory) {
                throw TranscriptionError.unreadableAudio(audio, "poison")
            }
            return [EngineSegment(startMs: 0, endMs: 1_000, text: "ok")]
        }
    }

    /// 1 000 terms and hostile ones, against the real CTC model.
    @Test func vocabularyStress() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        let store = try TestStore.open(directory)
        let meeting = try store.createMeeting(TestStore.meeting(state: .recording))
        let meetingDirectory = audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: meetingDirectory, withIntermediateDirectories: true)
        try Self.say("Sofia can you confirm the ptychography rig is free on Thursday.",
                     to: meetingDirectory.appendingPathComponent("mic.wav"))

        let hostile = [
            "ptychography",
            "term\u{0}with\u{0}nul",
            "line\nbreak\r\nterm",
            String(repeating: "A", count: 10_000),
            "\u{202E}gnihsalf\u{202C}",
            "🙈🙉🙊 emoji term",
            "'; DROP TABLE meetings; --",
            "<script>alert(1)</script>",
            "  \t  ",
            "../../etc/passwd",
        ]
        let mode = ProcessInfo.processInfo.environment["MEETINGS_PROBE_VOCAB"] ?? "all"
        if mode != "bulk" {
            for term in hostile {
                _ = try? store.addVocabularyTerm(VocabularyTerm(term: term))
            }
        }
        if mode != "hostile" {
            let bulk = Int(ProcessInfo.processInfo.environment["MEETINGS_PROBE_BULK"] ?? "1000")!
            for index in 0..<bulk {
                _ = try? store.addVocabularyTerm(VocabularyTerm(term: "jargonterm\(index)"))
            }
        }
        let inEffect = try store.vocabularyInEffect(meetingID: meeting.id)
        print("PROBE vocab rows in effect: \(inEffect.count)")
        print("PROBE entries: \(VocabularyBiasing.entries(for: inEffect).count)")

        let service = TranscriptionService(store: store, engine: nil, audioRoot: audioRoot)
        let clock = ContinuousClock()
        let before = Self.residentBytes()
        do {
            let elapsed = try await clock.measure {
                try await service.runBatchPass(meetingID: meeting.id, progress: { _ in })
            }
            print("PROBE vocab pass in \(elapsed); rss \(before / 1_048_576) -> "
                + "\(Self.residentBytes() / 1_048_576) MB")
        } catch {
            print("PROBE vocab pass THREW \(String(describing: error).prefix(200))")
        }
        print("PROBE segments: \(try store.segments(meetingID: meeting.id).map(\.text))")
        let report = await service.lastVocabularyReport
        print("PROBE report terms=\(report?.terms.count ?? -1) applied=\(report?.applied ?? []) "
            + "unavailable=\(report?.unavailable ?? "nil")")
        print("PROBE issues: \(try store.transcriptIssues(meetingID: meeting.id).map(\.sentence))")
    }

    /// Downloads the 97.5 MB CTC repo into a scratch directory (never the operator's cache) so the
    /// process can be killed mid-flight and the leftovers inspected. MEETINGS_PROBE_DL=<dir>.
    @Test func interruptedDownload() async throws {
        let target = try #require(ProcessInfo.processInfo.environment["MEETINGS_PROBE_DL"])
        let directory = URL(fileURLWithPath: target, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("PROBE download into \(directory.path)")
        _ = try await ModelHub.loadModels(
            .parakeetCtc110m,
            modelNames: [ModelNames.CTC.melSpectrogramPath, ModelNames.CTC.audioEncoderPath],
            directory: directory,
            progressHandler: { step in
                FileHandle.standardError.write(
                    Data(String(format: "PROBE dl %.3f\n", step.fractionCompleted).utf8))
            }
        )
        print("PROBE download finished")
    }

    /// A three-hour file, and a file that vanishes mid-pass.
    @Test func longAndVanishingAudio() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let engine = StreamingFileEngine(variant: LocalTranscriber.current.variant)
        try await engine.prepare(progress: { _ in })

        let long = directory.appendingPathComponent("long.wav")
        try Self.writePCM(to: long, sampleRate: 16_000, frames: 16_000 * 3 * 3_600) { index in
            index % 32_000 < 16_000 ? sin(Float(index) * 0.02) * 0.2 : 0
        }
        let bytes = (try FileManager.default.attributesOfItem(atPath: long.path)[.size] as? Int) ?? 0
        print("PROBE 3 h file is \(bytes / 1_048_576) MB")
        let before = Self.residentBytes()
        let clock = ContinuousClock()
        do {
            let elapsed = try await clock.measure {
                _ = try await engine.transcribe(long, vocabulary: [], progress: { _ in })
            }
            print("PROBE 3 h pass in \(elapsed); rss \(before / 1_048_576) -> "
                + "\(Self.residentBytes() / 1_048_576) MB")
        } catch {
            print("PROBE 3 h THREW \(String(describing: error))")
        }
        try? FileManager.default.removeItem(at: long)

        let vanishing = directory.appendingPathComponent("vanishing.wav")
        try Self.writePCM(to: vanishing, sampleRate: 16_000, frames: 16_000 * 120) { index in
            sin(Float(index) * 0.02) * 0.2
        }
        let deleter = Task {
            try? await Task.sleep(for: .milliseconds(150))
            try? FileManager.default.removeItem(at: vanishing)
            print("PROBE deleted the file mid-pass")
        }
        do {
            let segments = try await engine.transcribe(vanishing, vocabulary: [], progress: { _ in })
            print("PROBE vanishing: OK \(segments.count) segments")
        } catch {
            print("PROBE vanishing: THREW \(String(describing: error))")
        }
        await deleter.value
    }

    /// The remote engine against a local throwaway server. Nothing external is contacted.
    /// MEETINGS_PROBE_REMOTE=<port> of scratchpad/badserver.py.
    @Test func remoteEngineMisbehaviour() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["MEETINGS_PROBE_REMOTE"])
        let paths = (ProcessInfo.processInfo.environment["MEETINGS_PROBE_PATHS"]
            ?? "html,badjson,500,redirect,huge,drop").split(separator: ",").map(String.init)
        let audio = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-remote-\(UUID().uuidString).wav")
        try Self.say("Hello there.", to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        for path in paths {
            let base = URL(string: "http://127.0.0.1:\(port)/\(path)")!
            let engine = OpenAICompatibleRemoteEngine(
                configuration: .init(baseURL: base, model: "whisper-1", apiKey: "probe"))
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let segments = try await engine.transcribe(audio, vocabulary: [], progress: { _ in })
                print("PROBE remote [\(path)]: OK \(segments.count) segments after "
                    + "\(started.duration(to: clock.now))")
            } catch {
                print("PROBE remote [\(path)]: THREW after \(started.duration(to: clock.now)) — "
                    + String(describing: error).prefix(160))
            }
        }
    }

    static func residentBytes() -> UInt64 {
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

    static func writePCM(
        to url: URL, sampleRate: Double, frames: Int, generator: (Int) -> Float
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for index in 0..<frames {
            channel[index] = max(-1, min(1, generator(index)))
        }
        try file.write(from: buffer)
    }
}
