import Foundation

/// One chunk of recognised speech, in milliseconds from the start of the file it came from. The
/// engine knows nothing about meetings or channels — the service tags those on afterwards.
public struct EngineSegment: Sendable, Hashable {
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

/// One protocol, two conformers: ``StreamingFileEngine`` on device and
/// ``OpenAICompatibleRemoteEngine`` for the optional remote pass.
///
/// `vocabulary` is part of the call because custom vocabulary is applied as a post-pass over the
/// *same samples* that produced the transcript, so it has to happen inside the engine.
///
/// `progress` is per file, 0…1. It exists for one reason: the first pass that has vocabulary terms
/// in effect downloads a second ~97.5 MB model, and a wait that long with a frozen bar reads as a
/// hang. An engine with nothing to report simply never calls it.
public protocol TranscriptionEngine: Sendable {
    var name: String { get }
    var model: String { get }
    func prepare(progress: @Sendable (Double) -> Void) async throws
    func transcribe(
        _ audio: URL,
        vocabulary: [VocabularyTerm],
        progress: @Sendable (Double) -> Void
    ) async throws -> [EngineSegment]
    func release() async
    /// What the last call did with the vocabulary in effect. Nil from an engine that does not bias.
    ///
    /// Deliberately *not* defaulted in an extension: the default would be a second overload
    /// differing only in `async`, and at an `await` call site on a concrete engine Swift picks the
    /// extension's — so the engine that does the work would silently report nothing. Four words of
    /// `{ nil }` per conformer beats a default that lies.
    func vocabularyReport() async -> VocabularyBiasingReport?
}

extension EngineSegment {
    /// Group per-word timings into readable segments.
    ///
    /// Three break rules, and all three are needed: sentence punctuation is the natural boundary but
    /// Parakeet v3's punctuation is patchy, a silence gap catches the turn-taking punctuation misses,
    /// and the word cap stops a monologue with neither from becoming one 20-minute paragraph that no
    /// note can usefully anchor into.
    ///
    /// Derived from quill's `ParakeetEngine.segments(from:)` (MIT) — see NOTICE.
    public static func grouped(
        words: [EngineSegment],
        silenceGapMs: Int = 1_000,
        maxWords: Int = 60
    ) -> [EngineSegment] {
        var out: [EngineSegment] = []
        var current: [EngineSegment] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(EngineSegment(
                startMs: first.startMs,
                endMs: last.endMs,
                text: current.map(\.text).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let last = current.last, word.startMs - last.endMs > silenceGapMs {
                flush()
            }
            current.append(EngineSegment(startMs: word.startMs, endMs: word.endMs, text: text))
            let endsSentence = text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!")
            if endsSentence || current.count >= maxWords {
                flush()
            }
        }
        flush()
        return out
    }
}
