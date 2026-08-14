import Foundation

/// One candidate, run on this machine, with the numbers the run produced.
///
/// Every field is measured. There is no place in this struct to put an expectation, which is
/// deliberate: the expectation table lives in ``MachineProfile/startingIndex(among:)`` and its only
/// job is to choose what to measure first.
public struct FitMeasurement: Sendable, Codable, Equatable {
    public let optionID: String
    /// Real-time factor with **two channels decoding at once**, which is the workload a meeting
    /// actually is. A single-channel number is roughly twice as flattering and was the thing every
    /// measurement before this one got wrong. 1.0 means it exactly keeps up and has nothing left for
    /// capture, the UI, or the other things the Mac is doing.
    public let realTimeFactor: Double
    /// Wall milliseconds from the audio being fed to the first text arriving, fed at real time.
    public let timeToFirstTextMs: Int
    /// Peak `phys_footprint` of this process during the run.
    public let peakMemoryBytes: Int64
    /// How much audio the numbers rest on.
    public let audioSeconds: Double
    /// Scored against the fixture's script. Nil when the fixture had no script to score against.
    public let wordErrorPercent: Double?

    public init(
        optionID: String, realTimeFactor: Double, timeToFirstTextMs: Int,
        peakMemoryBytes: Int64, audioSeconds: Double, wordErrorPercent: Double?
    ) {
        self.optionID = optionID
        self.realTimeFactor = realTimeFactor
        self.timeToFirstTextMs = timeToFirstTextMs
        self.peakMemoryBytes = peakMemoryBytes
        self.audioSeconds = audioSeconds
        self.wordErrorPercent = wordErrorPercent
    }

    public func meets(_ bar: FitThresholds) -> Bool {
        realTimeFactor >= bar.realTimeFactor && timeToFirstTextMs <= bar.timeToFirstTextMs
    }

    /// The measured numbers, in a sentence, for Settings and for `fit`'s own output.
    public var sentence: String {
        let wer = wordErrorPercent.map { String(format: ", %.1f%% word error", $0) } ?? ""
        return String(
            format: "%.1fx real-time on two channels, %d ms to first text%@",
            realTimeFactor, timeToFirstTextMs, wer)
    }
}

/// What a candidate has to clear to be accepted.
///
/// Both numbers are judgements rather than measurements, and both err toward rejecting:
///
///   * **1.5x, not 1.0x.** At exactly 1.0 the decoder consumes audio precisely as fast as the
///     meeting produces it, with nothing left for capture, the window, or whatever else is running —
///     and once it falls behind during a meeting it never catches up, because the audio keeps
///     coming. Half again is the smallest headroom worth calling real time.
///   * **2 s to first text.** Live text exists to anchor a note you are typing now. Text that lands
///     two seconds after the sentence it belongs to has stopped being live.
public struct FitThresholds: Sendable, Codable, Equatable {
    public let realTimeFactor: Double
    public let timeToFirstTextMs: Int

    public init(realTimeFactor: Double = 1.5, timeToFirstTextMs: Int = 2_000) {
        self.realTimeFactor = realTimeFactor
        self.timeToFirstTextMs = timeToFirstTextMs
    }

    public static let standard = FitThresholds()
}

/// What `meetings fit` decided, why, and everything it measured on the way. Stored whole in
/// `transcribe.fit.record` so Settings can show the reason without re-running anything.
public struct FitRecord: Sendable, Codable, Equatable {
    public let chosenOptionID: String
    /// One sentence naming the measurement that justified the choice, or the reason there is none.
    public let reason: String
    /// False when nothing could be measured and the fallback was taken. A record with this false is
    /// a record that must never be presented as a fit.
    public let verified: Bool
    public let machine: MachineProfile
    public let thresholds: FitThresholds
    /// Every candidate tried, in the order tried, including the ones that were rejected.
    public let measurements: [FitMeasurement]
    /// Whole seconds, always — see the initialiser for why that is enforced there rather than left to
    /// whoever constructs one.
    public let ranAt: Date
    /// The wall-clock ceiling the run was given, in seconds, so a short run is legible as a capped
    /// one rather than a broken one.
    public let capSeconds: Double

    public init(
        chosenOptionID: String, reason: String, verified: Bool, machine: MachineProfile,
        thresholds: FitThresholds, measurements: [FitMeasurement], ranAt: Date, capSeconds: Double
    ) {
        self.chosenOptionID = chosenOptionID
        self.reason = reason
        self.verified = verified
        self.machine = machine
        self.thresholds = thresholds
        self.measurements = measurements
        // Rounded to the second on the way in, because this type is `Equatable` and its stored form
        // is ISO 8601, which has no room for the fraction. Left alone, a record never equals itself
        // after a round trip through the store — by a difference too small to print, so the two
        // values look identical in any failure message. Rounding here rather than comparing with a
        // tolerance at the call sites: a value type whose stored form cannot equal its in-memory form
        // is broken for every caller, not just the one that noticed. When `fit` ran is a fact about a
        // minute of somebody's afternoon; the microseconds were never meaningful.
        self.ranAt = Date(timeIntervalSince1970: ranAt.timeIntervalSince1970.rounded())
        self.capSeconds = capSeconds
    }

    public var chosen: LocalTranscriptionOption { .named(chosenOptionID) }

    /// "Balanced, chosen because 6.4x real-time on two channels, 780 ms to first text on your
    /// Apple M1 Pro." Never claims a measurement an unverified record does not have.
    public var headline: String {
        verified
            ? "\(chosen.title), chosen because \(reason)"
            : "\(chosen.title) — \(reason)"
    }

    // MARK: - Persistence

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension LocalTranscriptionOption {
    /// The one performance line shown under this option: what `fit` measured on this Mac if it has
    /// ever measured this option, and the shipped ``measured`` claim otherwise.
    ///
    /// One or the other, never both, and the run from this machine wins. The two are not comparable
    /// and were free to contradict each other on screen: `accurate-en` ships "2.9% word error",
    /// scored on a 54.5 s fixture, while `fit` on the same M1 Pro reported 16.4% on the much shorter
    /// fixture it synthesises. Both read as claims about the same thing, so both forms name the
    /// length of audio they rest on — the numbers then differ legibly rather than one looking wrong.
    ///
    /// Nil where nothing has been measured at all, which is still the honest answer for a tier
    /// nobody has run.
    public func performanceLine(measuredBy record: FitRecord?) -> String? {
        if let run = record?.measurements.last(where: { $0.optionID == id }) {
            let wer = run.wordErrorPercent.map { String(format: ", %.1f%% word error", $0) } ?? ""
            return String(
                format: "Measured on this Mac: %d ms to first text%@, on %.0f s of audio",
                run.timeToFirstTextMs, wer, run.audioSeconds)
        }
        guard let measured else { return nil }
        return String(
            format: "Measured on an %@: %d ms to first text, %.1f%% word error, on %.0f s of audio",
            measured.machine, measured.timeToFirstTextMs, measured.wordErrorPercent,
            measured.fixtureSeconds)
    }
}

extension MeetingStore {
    /// Nil until `fit` has run. A row that will not decode — written by an older build, or edited by
    /// hand — reads as nil rather than throwing: a stale fit record is a missing explanation, not a
    /// reason to fail opening Settings.
    public func fitRecord() -> FitRecord? {
        guard let raw = (try? setting(.transcribeFitRecord)) ?? nil, let data = raw.data(using: .utf8)
        else { return nil }
        return try? FitRecord.decoder.decode(FitRecord.self, from: data)
    }

    /// Writes the record **and** the choice it justifies, in that order, so a store can never end up
    /// with an explanation for a model it is not running.
    public func applyFitRecord(_ record: FitRecord) throws {
        let data = try FitRecord.encoder.encode(record)
        try setSetting(.transcribeFitRecord, String(decoding: data, as: UTF8.self))
        try setSetting(.transcribeLocalModel, record.chosenOptionID)
        try setSetting(.transcribeBatchEngine, TranscriptionEngineChoice.local.rawValue)
    }
}
