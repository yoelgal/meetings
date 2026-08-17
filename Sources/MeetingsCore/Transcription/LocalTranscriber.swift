import FluidAudio
import Foundation

/// The one local model this Mac runs.
///
/// There is no user-facing choice here, and the absence is the design. A picker of two models asks
/// the reader to answer a question they have no way to answer — the trade is accuracy against
/// latency against languages, in milliseconds and word error rates — and then makes the app's
/// behaviour depend on the answer. The machine can decide it: the only input that actually matters
/// is whether this Mac's owner speaks English, and the system already knows that. So the catalogue
/// is two constants, the choice is ``resolved(preferredLanguages:)``, and nothing is persisted.
///
/// Nothing persisted is the other half. The model used to live in a settings row
/// (`transcribe.localModel`), which meant an install could be pinned to a model this build no
/// longer ships, a hand-edited row could name a model that was never downloaded, and every surface
/// that showed the choice had to agree about what an unrecognised value meant. A value derived from
/// the locale on every read cannot drift.
///
/// **One model, one pass.** Both variants here are *streaming* checkpoints: the model that writes
/// the live pane is the same model that transcribes a file, so a meeting is never re-transcribed by
/// a second, larger download, and the live text you watched is the text you read afterwards. See
/// ``StreamingFileEngine`` for the file half of that.
public struct LocalTranscriber: Sendable, Hashable {
    /// The streaming checkpoint. Both the live pane (``FluidAudioStreamingTranscriber``) and the
    /// file pass (``StreamingFileEngine``) load exactly this, which is why one readiness check
    /// answers for both.
    public let variant: StreamingModelVariant
    /// Roughly what comes down the wire on first run, in bytes.
    public let downloadBytes: Int64
    /// "English" / "25 languages". Used in exactly one friendly onboarding line, so it is a phrase
    /// rather than a language list a reader would have to scan.
    public let languages: String

    /// "About 640 MB" — one place, so the wizard, Settings and `meetings status` cannot disagree
    /// about the size of the same download.
    ///
    /// Rounded to the nearest 10 MB deliberately. The exact byte count is knowable but not useful:
    /// what the reader is deciding is whether to start a download now, and "About 643 MB" spends
    /// precision on a number that will not match what their network reports anyway.
    public var downloadSizeText: String {
        let megabytes = Double(downloadBytes) / 1_000_000
        return "About \(Int((megabytes / 10).rounded()) * 10) MB"
    }

    /// Nemotron 0.6B at the 560 ms tier — English only, and the live text *is* the final text.
    ///
    /// 643 MB is the figure this repo has shipped for this bundle since the tier was added; the
    /// completed download measures 597 MiB (611,828 KiB) on disk here, so the number is on the
    /// generous side of the truth rather than the flattering side.
    public static let english = LocalTranscriber(
        variant: .nemotron560ms,
        downloadBytes: 643_000_000,
        languages: "English"
    )

    /// Parakeet EOU 120M at the 320 ms tier — the non-English answer, same one-pass shape.
    ///
    /// The byte count is not an estimate and not a guess at a family average: FluidAudio declares no
    /// sizes anywhere in its sources, so this is the sum of the HuggingFace blob sizes of exactly the
    /// entries its downloader fetches for this repo — `ModelHub.download` builds its file patterns
    /// from `ModelNames.ParakeetEOU.requiredModels`, which is `streaming_encoder.mlmodelc`,
    /// `decoder.mlmodelc`, `joint_decision.mlmodelc` and `vocab.json`. The `.mlpackage` sources and
    /// conversion scripts sitting beside them in the repo (another ~224 MB) are never downloaded, so
    /// counting the whole directory listing would have overstated this by a factor of two.
    public static let multilingual = LocalTranscriber(
        variant: .parakeetEou320ms,
        downloadBytes: 224_238_270,
        languages: "25 languages"
    )

    /// ``english`` when the primary preferred language is English, ``multilingual`` otherwise.
    ///
    /// The *primary* language, not "is English anywhere in the list": macOS puts English second on a
    /// great many non-English installs, and a French speaker whose second language is English wants
    /// their French meetings transcribed rather than heard as English-shaped nonsense.
    ///
    /// Parsed off the front of the tag rather than through `Locale` on purpose. Every value this
    /// receives is a BCP-47 tag — `en`, `en-GB`, `zh-Hans-CN` — whose language subtag is the text
    /// before the first separator, and reading it directly means an unexpected or malformed tag
    /// resolves to the multilingual model, which is the safe answer: it transcribes English too.
    ///
    /// An *empty* list takes that same path, and the missing primary is spelled `?? ""` rather than
    /// `?? "en"` to make sure of it. With `?? "en"` a Mac that reported no preferred languages at all
    /// resolved to English-only: it downloaded the 643 MB English checkpoint instead of the 224 MB
    /// multilingual one and heard non-English speech as English-shaped nonsense — the one outcome
    /// this fallback exists to avoid. No information about the speaker means the model that handles
    /// every language, not a guess dressed up as one.
    public static func resolved(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> LocalTranscriber {
        let primary = preferredLanguages.first ?? ""
        let language = primary.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? ""
        return language.lowercased() == "en" ? .english : .multilingual
    }

    /// ``resolved()`` for this Mac, computed once.
    ///
    /// A `static let` rather than a computed property because it is read on every readiness check,
    /// every settings pane draw and every batch pass, and because a value that changed halfway
    /// through a process — the user switching their system language mid-meeting — would mean the
    /// live pane and the file pass disagreeing about which model to load.
    public static let current = resolved()
}

/// Where transcription runs. The engine choice, as opposed to *which* local model runs it — which is
/// no longer a choice at all; see ``LocalTranscriber``.
///
/// Backed by the `transcribe.batchEngine` row that has always existed, whose two values were
/// `fluidaudio` and `remote`. Nothing about an existing store changes: this only gives the two
/// values a name and a single place to be read.
public enum TranscriptionEngineChoice: String, Sendable, CaseIterable {
    /// The model on this Mac. Which model is ``LocalTranscriber/current``.
    case local = "fluidaudio"
    /// An OpenAI-compatible endpoint. Nothing is downloaded and audio leaves the machine.
    case cloud = "remote"

    /// Never nil, and never `cloud` by accident: an unrecognised value — a newer build's, or a
    /// hand-edited row — reads as local, because the failure mode of guessing wrong in the other
    /// direction is uploading every meeting's audio to an endpoint nobody chose.
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
}
