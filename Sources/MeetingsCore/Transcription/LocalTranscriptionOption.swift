import FluidAudio
import Foundation

/// One measured run of one model tier on one machine.
///
/// Every field here came off a real run. Nothing is interpolated, and a tier nobody has measured
/// carries `nil` rather than a plausible-looking guess — a number in this struct is a promise that
/// somebody watched it happen.
public struct MeasuredTier: Sendable, Hashable, Codable {
    /// Wall milliseconds from the first word being spoken to the first text on screen.
    public let timeToFirstTextMs: Int
    /// Word error rate as a percentage, scored against the fixture's script.
    public let wordErrorPercent: Double
    /// The one machine this was measured on. Named because it is the only one: see
    /// ``MachineProfile/startingTier(for:)`` for what is and is not extrapolated from it.
    public let machine: String
    /// How long the fixture was, so a reader can tell how much audio the number rests on.
    public let fixtureSeconds: Double

    public init(timeToFirstTextMs: Int, wordErrorPercent: Double, machine: String, fixtureSeconds: Double) {
        self.timeToFirstTextMs = timeToFirstTextMs
        self.wordErrorPercent = wordErrorPercent
        self.machine = machine
        self.fixtureSeconds = fixtureSeconds
    }
}

/// A local model set the user can run transcription on.
///
/// A value type on purpose, and the whole catalogue is ``all``. Adding the Nemotron 80 ms and 160 ms
/// tiers the benchmark is currently measuring is a new element in that array and nothing else: the
/// wizard's picker, Settings, `meetings fit`'s ladder and `meetings config` all read this list, and
/// none of them branches on a particular option's identity.
public struct LocalTranscriptionOption: Identifiable, Sendable, Hashable {
    /// Stored in `transcribe.localModel`. Stable — it is a persisted value, not a label.
    public let id: String
    public let title: String
    /// A one-line "what you are trading", in the user's terms.
    public let summary: String
    /// What runs while you are talking, named as the model.
    public let liveModel: String
    /// What produces the transcript you actually read.
    public let finalModel: String
    /// Roughly what has to come down the wire, in bytes, counting every model the option needs.
    public let downloadBytes: Int64
    public let languages: String
    /// The live streaming variant. Also the *only* model when ``runsSeparateBatchPass`` is false.
    public let liveVariant: StreamingModelVariant
    /// Whether a second, larger model re-transcribes the recording when the meeting stops. False
    /// means the live transcript is the final transcript, and there is nothing to download twice.
    public let runsSeparateBatchPass: Bool
    /// Ordering for ``FitRunner``'s ladder: 0 is the most demanding candidate, and the runner steps
    /// *up* through the numbers when a candidate misses. The last element is the fallback, so it has
    /// to be the option that has always shipped.
    public let tier: Int
    /// Nil where nobody has run it. Never filled in by inference.
    public let measured: MeasuredTier?

    /// Nemotron 0.6B at the 560 ms tier: one model does the live pane and the final transcript, so
    /// there is no second pass and nothing downloaded twice. English only — the checkpoint is
    /// `nemotron-speech-streaming-en-0.6b`.
    public static let accurateEnglish = LocalTranscriptionOption(
        id: "accurate-en",
        title: "Accurate, English only",
        summary: "One larger model does both passes. More accurate live text, slower to appear, "
            + "and English only.",
        liveModel: "Nemotron 0.6B, 560 ms",
        finalModel: "The same model — there is no second pass",
        downloadBytes: 643_000_000,
        languages: "English",
        liveVariant: .nemotron560ms,
        runsSeparateBatchPass: false,
        tier: 0,
        measured: MeasuredTier(
            timeToFirstTextMs: 1_132, wordErrorPercent: 2.9, machine: "M1 Pro", fixtureSeconds: 54.5)
    )

    /// What has shipped since the first release: a small live model for the pane you watch, and
    /// Parakeet TDT 0.6b v3 re-transcribing the recording when you stop.
    ///
    /// Last in ``all`` because it is the fallback: `FitRunner` ends here when nothing more demanding
    /// verifies, and an install that has never run `fit` is on it by default.
    public static let balanced = LocalTranscriptionOption(
        id: "balanced",
        title: "Balanced",
        summary: "A small model keeps up while you talk, and a larger one re-transcribes the "
            + "recording when you stop.",
        liveModel: "Parakeet EOU 120M, 320 ms",
        finalModel: "Parakeet TDT 0.6b v3",
        downloadBytes: 896_000_000,
        languages: "25 languages",
        liveVariant: .parakeetEou320ms,
        runsSeparateBatchPass: true,
        tier: 1,
        measured: MeasuredTier(
            timeToFirstTextMs: 811, wordErrorPercent: 4.6, machine: "M1 Pro", fixtureSeconds: 54.5)
    )

    /// Most demanding first. `meetings fit` walks this in order from its starting index.
    ///
    /// Filtered on the engine families the app can actually drive, so an option added here for a
    /// variant ``FluidAudioStreamingTranscriber`` has no backend for cannot be offered, selected, or
    /// downloaded. The Parakeet Unified tiers are the live case: FluidAudio ships them, they look
    /// like candidates, and their manager exposes neither `injectSilence` nor a cumulative timing
    /// accumulator — so driving one would produce a transcript with no usable clock.
    public static let all: [LocalTranscriptionOption] = [accurateEnglish, balanced]
        .filter { $0.liveVariant.engineFamily != .parakeetUnified }
        .sorted { $0.tier < $1.tier }

    /// The one an install that has chosen nothing is on, and the one `fit` falls back to when it
    /// cannot measure. Deliberately the option that shipped first: an existing install must not
    /// change behaviour because this type appeared.
    public static let fallback = balanced

    /// Never nil: an id from a newer build, or a hand-edited settings row, resolves to the fallback
    /// rather than leaving the app with no transcriber at all.
    public static func named(_ id: String?) -> LocalTranscriptionOption {
        guard let id, let match = all.first(where: { $0.id == id }) else { return fallback }
        return match
    }

    /// "About 896 MB" — one place, so the wizard and Settings cannot disagree about the size.
    public var downloadSizeText: String {
        String(format: "%.0f MB", Double(downloadBytes) / 1_000_000)
    }
}

/// Where transcription runs. The engine choice, as opposed to *which* local model runs it.
///
/// Backed by the `transcribe.batchEngine` row that has always existed, whose two values were
/// `fluidaudio` and `remote`. Nothing about an existing store changes: this only gives the two
/// values a name and a single place to be read.
public enum TranscriptionEngineChoice: String, Sendable, CaseIterable {
    /// Models on this Mac. Which models is ``LocalTranscriptionOption``.
    case local = "fluidaudio"
    /// An OpenAI-compatible endpoint. Nothing is downloaded and audio leaves the machine.
    case cloud = "remote"

    public static func named(_ raw: String?) -> TranscriptionEngineChoice {
        guard let raw, let match = TranscriptionEngineChoice(rawValue: raw) else { return .local }
        return match
    }
}

extension MeetingStore {
    /// The engine this store is set to. One accessor, so the app, the CLI and the service cannot
    /// each decide differently what an unrecognised value means.
    public func transcriptionEngine() -> TranscriptionEngineChoice {
        TranscriptionEngineChoice.named((try? setting(.transcribeBatchEngine)) ?? nil)
    }

    /// The local model set this store is set to, whether or not the engine is currently local.
    /// Remembered across a switch to cloud and back, which is why it is read independently.
    public func localTranscriptionOption() -> LocalTranscriptionOption {
        LocalTranscriptionOption.named((try? setting(.transcribeLocalModel)) ?? nil)
    }
}
