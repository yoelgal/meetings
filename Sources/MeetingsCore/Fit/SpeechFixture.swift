import AVFoundation
import Foundation

/// Two channels of synthesised speech on disk, plus the script each one says.
///
/// Synthesised with `say -o`, which writes a file and **never opens an audio device** — nothing
/// reaches the speakers, which matters because `fit` runs during onboarding on a Mac somebody is
/// using. Two different voices for two different scripts, because the workload being measured is two
/// simultaneous decodes, and feeding the same audio twice would let a cache flatter the result.
public struct SpeechFixture: Sendable {
    public struct Track: Sendable {
        public let url: URL
        public let script: String
        public let samples: [Float]
    }

    public let mic: Track
    public let system: Track
    /// The longer of the two, which is how long the decode has to keep up for.
    public var audioSeconds: Double {
        max(Double(mic.samples.count), Double(system.samples.count)) / 16_000
    }

    /// Deliberately short. `fit` runs inside onboarding under a wall-clock cap, and the question is
    /// whether the decoder keeps up, which a quarter of a minute answers as well as a minute does.
    /// Long enough to leave the warm-up behind and produce several segments; short enough that two
    /// passes over two channels fit in the budget.
    ///
    /// "Torch zero" rather than this repo's usual "Torch0", which `say` pronounces identically and no
    /// recogniser will ever write back: the scorer splits on non-alphanumerics, so `torch0` is one
    /// reference word against two heard ones and costs two edits every time it appears, in every
    /// model, forever. Over 67 reference words that alone was five points of word error that said
    /// nothing about the decoder. What is left wrong here — ptychography, Mateus — is the fixture
    /// being hard on purpose, and it is why this number is not comparable to a longer run's: see
    /// ``FitMeasurement/wordErrorPercent``.
    public static let micScript = """
        Sofia, can you confirm the ptychography rig is free on Thursday? \
        I want to run the Torch zero calibration before the Airbus review on Friday morning. \
        Mateus said the alignment drifted again, and nobody has looked at it since.
        """

    public static let systemScript = """
        The rig is booked for Torch zero until Thursday afternoon. \
        Mateus will hand the alignment notes over on Friday morning. \
        Nothing else is scheduled for the interferometry bench that week.
        """

    public enum Failure: Error, CustomStringConvertible {
        case sayUnavailable(String)
        case emptyAudio(URL)

        public var description: String {
            switch self {
            case .sayUnavailable(let why): "speech could not be synthesised: \(why)"
            case .emptyAudio(let url): "\(url.lastPathComponent) came back with no audio in it"
            }
        }
    }

    /// Writes both tracks into `directory`. Throws rather than degrading: a fixture that is silent,
    /// or half a fixture, would produce a real-looking number measured on nothing.
    public static func make(in directory: URL) throws -> SpeechFixture {
        SpeechFixture(
            mic: try track(micScript, voice: "Samantha", to: directory.appendingPathComponent("fit-mic.wav")),
            system: try track(systemScript, voice: "Daniel", to: directory.appendingPathComponent("fit-system.wav"))
        )
    }

    private static func track(_ script: String, voice: String, to url: URL) throws -> Track {
        try synthesise(script, voice: voice, to: url)
        let samples = try readSamples(url)
        guard samples.count > 16_000 else { throw Failure.emptyAudio(url) }
        return Track(url: url, script: script, samples: samples)
    }

    /// `-o` writes the file; no audio device is opened and nothing is played. The voice is a
    /// *request*: `say` falls back to the system voice when the named one is not installed, which is
    /// why a missing voice is not treated as a failure here — an empty file is.
    static func synthesise(_ text: String, voice: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEI16@16000", "-v", voice, text]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure.sayUnavailable(String(describing: error))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.sayUnavailable("/usr/bin/say exited \(process.terminationStatus)")
        }
    }

    static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, file.length)))
        else { throw Failure.emptyAudio(url) }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData?[0] else { throw Failure.emptyAudio(url) }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}

/// Word error rate, and the words behind it.
///
/// Lifted whole from `StreamingVariantBenchmarkTests` (branch `spike/streaming-variant-benchmark`)
/// so `meetings fit` and that benchmark score the same transcript the same way. Two scorers would
/// drift, and the drift would show up as `fit` accepting a tier the benchmark had rejected.
public enum TranscriptScore {
    /// Lowercased, punctuation stripped. Some models emit punctuation and capitals and some do not,
    /// so scoring raw would measure formatting rather than recognition.
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Edits per reference word, as a percentage. 0 for an empty reference — there is nothing to be
    /// wrong about — and 100 for a reference that came back as nothing.
    public static func wordErrorPercent(reference: String, heard: String) -> Double {
        let truth = words(reference)
        guard !truth.isEmpty else { return 0 }
        let edits = distance(truth, words(heard))
        return 100 * Double(edits) / Double(truth.count)
    }

    /// Two-row Levenshtein. `fit` needs the count and not the backtrace — the benchmark keeps the
    /// full matrix because it renders the diff, and this is the same number by a cheaper route.
    static func distance(_ reference: [String], _ hypothesis: [String]) -> Int {
        guard !reference.isEmpty else { return hypothesis.count }
        var previous = Array(0...reference.count)
        var current = previous
        for (column, word) in hypothesis.enumerated() {
            current[0] = column + 1
            for row in 1...reference.count {
                current[row] = reference[row - 1] == word
                    ? previous[row - 1]
                    : min(previous[row - 1], previous[row], current[row - 1]) + 1
            }
            swap(&previous, &current)
        }
        return previous[reference.count]
    }
}

/// This process's current physical footprint, in bytes, or nil when the kernel will not say.
///
/// `phys_footprint` rather than `resident_size`: it is the number the memory pressure system and
/// Activity Monitor use, and Core ML's ANE allocations show up in it.
public enum ProcessMemory {
    public static func footprintBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }
}
