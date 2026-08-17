import Foundation

/// Word error rate, and the words behind it.
///
/// It used to live in MeetingsCore, next to `meetings fit` — the command that measured which of
/// several models ran best on this Mac. With one model there is nothing to fit, the command is gone,
/// and nothing the app ships scores a transcript any more: the only caller left is the live
/// assembly test, which asks whether driving the model through the app scores what driving it
/// directly scores. So it lives with that test rather than in the library, where it would be public
/// API with no production caller.
///
/// Lifted whole from `StreamingVariantBenchmarkTests` (branch `spike/streaming-variant-benchmark`)
/// so the app's tests and that benchmark score the same transcript the same way. Two scorers would
/// drift, and the drift would show up as a test accepting what the benchmark had rejected.
enum TranscriptScore {
    /// Lowercased, punctuation stripped. Some models emit punctuation and capitals and some do not,
    /// so scoring raw would measure formatting rather than recognition.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Edits per reference word, as a percentage. 0 for an empty reference — there is nothing to be
    /// wrong about — and 100 for a reference that came back as nothing.
    static func wordErrorPercent(reference: String, heard: String) -> Double {
        let truth = words(reference)
        guard !truth.isEmpty else { return 0 }
        let edits = distance(truth, words(heard))
        return 100 * Double(edits) / Double(truth.count)
    }

    /// Two-row Levenshtein. What the caller needs is the count and not the backtrace — the benchmark
    /// keeps the full matrix because it renders the diff, and this is the same number by a cheaper
    /// route.
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
