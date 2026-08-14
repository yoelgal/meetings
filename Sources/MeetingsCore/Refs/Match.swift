import Foundation

/// Which part of a meeting or event a `--match` query hit. Reported back so the agent can say
/// "matched on an attendee, not the title" when it asks the user which meeting they meant.
public enum MatchField: String, Codable, Sendable, CaseIterable {
    case title, attendee, email, calendar
}

/// The `--match` scorer.
///
/// It never picks a winner. Every candidate over ``threshold`` comes back with its score and the
/// fields that produced it, and disambiguation is the agent's job — a CLI that guesses will
/// eventually write your notes onto the wrong meeting.
public enum Match {
    public static let threshold = 0.45

    /// Exact token 1.0, prefix 0.8, substring 0.6, close-enough 0.5–0.7. The gaps between the tiers
    /// are wide on purpose: two candidates a tier apart must not look like a coin toss.
    static let exact = 1.0
    static let prefix = 0.8
    static let substring = 0.6
    /// Levenshtein similarity below this is not a typo, it is a different word.
    static let fuzzyFloor = 0.7

    /// Scores one query against one candidate's fields, keeping the best field and every field that
    /// tied with it. `fields` may repeat a case — one entry per attendee — and the duplicates
    /// collapse in `matchedOn`.
    public static func score(query: String, fields: [(MatchField, String)]) -> (score: Double, matchedOn: [MatchField]) {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return (0, []) }

        var best = 0.0
        var matched: Set<MatchField> = []
        for (field, value) in fields {
            let score = fieldScore(queryTokens: queryTokens, value: value)
            guard score > 0 else { continue }
            if score > best + 0.0001 {
                best = score
                matched = [field]
            } else if abs(score - best) <= 0.0001 {
                matched.insert(field)
            }
        }
        return (best, MatchField.allCases.filter(matched.contains))
    }

    /// The mean of each query token's best hit in the value.
    ///
    /// Mean rather than max, because "sofia nunes" matching only "Sofia" in *Sofia / Torch0 weekly*
    /// is genuinely a weaker answer than it matching both words of *Sofia Nunes 1:1*, and the whole
    /// job of this function is to put those two in the right order.
    static func fieldScore(queryTokens: [String], value: String) -> Double {
        let valueTokens = tokens(value)
        guard !valueTokens.isEmpty else { return 0 }
        if queryTokens == valueTokens { return exact }

        let total = queryTokens.reduce(0.0) { running, query in
            running + (valueTokens.map { tokenScore(query: query, value: $0) }.max() ?? 0)
        }
        return total / Double(queryTokens.count)
    }

    static func tokenScore(query: String, value: String) -> Double {
        if query == value { return exact }
        if value.hasPrefix(query) { return prefix }
        if value.contains(query) { return substring }
        let ratio = similarity(query, value)
        guard ratio >= fuzzyFloor else { return 0 }
        // 0.7 similarity lands on 0.5, a perfect-but-for-one-letter match approaches 0.7 — always
        // below a real substring hit, which is what it deserves.
        return 0.5 + (ratio - fuzzyFloor) / (1 - fuzzyFloor) * 0.2
    }

    /// Lowercased, diacritics folded, everything but letters, digits and apostrophes treated as a
    /// separator — so `Mater-AI`, `Mater AI` and `mater ai` all tokenise the same, and `1:1` keeps
    /// both its ones.
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "\u{2019}" })
            .map { $0.replacingOccurrences(of: "\u{2019}", with: "'") }
    }

    /// The local part of an email, which is where the name is. The domain is deliberately not
    /// scored: everybody at the company shares it, so it matches everyone or no one.
    public static func emailLocalPart(_ email: String) -> String {
        String(email.split(separator: "@").first ?? "")
    }

    /// 1 − (edit distance / longer length). Two rows of the DP table, because a full matrix for a
    /// pair of names is a lot of allocation for nothing.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        if a.isEmpty || b.isEmpty { return 0 }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
