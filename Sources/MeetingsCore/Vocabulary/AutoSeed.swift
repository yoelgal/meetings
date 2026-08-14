import Foundation

/// Turns a calendar event's attendees into custom-vocabulary terms.
///
/// The whole value of this is in what it *refuses*. Adding "Will" as a term makes every "will" in
/// the transcript a candidate for boosting, and a transcript mangled that way poisons every summary
/// downstream — silently, and confidently. So the guard is deliberately over-cautious: it would
/// rather lose a real surname than seed a word the speaker says forty times an hour.
public enum AutoSeed {
    /// Terms below this length are never emitted on their own. "Li" and "Ng" are real surnames and
    /// we lose them; that is the trade.
    static let minimumTokenLength = 4

    /// The terms an attendee list yields, in a stable order: each attendee's full name, then their
    /// surname. Deduplicated case-insensitively, because the same person turns up on both the
    /// calendar event and, later, a correction.
    public static func terms(for attendees: [Attendee], folderID: String? = nil) -> [VocabularyTerm] {
        var seen = Set<String>()
        var result: [VocabularyTerm] = []

        for attendee in attendees {
            for term in candidates(for: attendee) where seen.insert(term.lowercased()).inserted {
                result.append(VocabularyTerm(term: term, folderID: folderID, source: .attendee))
            }
        }
        return result
    }

    /// Writes the terms for these attendees into the store. Idempotent twice over: the terms
    /// themselves are deduplicated here, and ``MeetingStore/addVocabularyTerm(_:)`` returns the
    /// existing row rather than failing when a term is already in scope — so re-materialising a
    /// meeting, or two processes doing it at once, cannot produce duplicates or an error.
    @discardableResult
    public static func seed(
        attendees: [Attendee],
        folderID: String? = nil,
        into store: MeetingStore
    ) throws -> [VocabularyTerm] {
        try terms(for: attendees, folderID: folderID).map { try store.addVocabularyTerm($0) }
    }

    // MARK: -

    /// One attendee's terms, in emission order.
    ///
    /// The display name is the good source. An email is used only when there is no name at all, and
    /// then only for the surname: `sofia.nunes@` tells us the surname reliably but tells us nothing
    /// trustworthy about how the person writes their full name, and a guessed full name in the
    /// recogniser's vocabulary is worse than no entry.
    static func candidates(for attendee: Attendee) -> [String] {
        let display = attendee.name ?? ""
        guard !isResource(display) else { return [] }
        let tokens = nameTokens(reordered(display))
        if !tokens.isEmpty {
            // A single-token display name is a bare first name far more often than it is a
            // surname — EventKit is full of "Ravi" and "Sofia" — and one is never seeded.
            // The occasional mononym is lost, which is the direction this guard is meant to err in.
            guard tokens.count >= 2 else { return [] }

            var result: [String] = []
            // A full name is safe even when *some* of its parts are not — nothing in a transcript
            // says "Will Smith" by accident — but at least one part has to be distinctive on its
            // own. That single condition covers both ways this goes wrong: "Bo Li" is two syllables
            // of nothing, and "Meeting Room 4" is a room EventKit listed as a participant.
            if tokens.contains(where: isSeedable) {
                result.append(tokens.joined(separator: " "))
            }
            if let surname = tokens.last, isSeedable(surname) {
                result.append(surname)
            }
            return result
        }

        guard let local = attendee.email?.split(separator: "@").first,
              !isResource(String(local)) else { return [] }
        let parts = nameTokens(local.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " "))
        guard parts.count >= 2, let surname = parts.last, isSeedable(surname) else { return [] }
        return [surname.capitalized]
    }

    /// Puts `"Hastings, Will"` back into speaking order before anything else looks at it.
    ///
    /// This is what most corporate directories hand EventKit, and it broke the guard in the worst
    /// possible way: the tokens came out `["Hastings", "Will"]`, so the *last* token — the one the
    /// rules treat as the surname and seed on its own — was the first name. "Will" in the
    /// recogniser's vocabulary is precisely the failure the vocabulary exists to prevent, and it was
    /// arriving by the front door on every invitation from an Exchange server.
    ///
    /// Exactly one comma, both sides non-empty, is the only shape trusted. `"Hastings, Will, PhD"`
    /// and `"Room 4, Building 2"` are refused outright rather than guessed at: this guard would
    /// rather lose a surname than invent one.
    static func reordered(_ raw: String) -> String {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard raw.contains(",") else { return raw }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return "" }
        return "\(parts[1]) \(parts[0])"
    }

    /// Meeting rooms, phones and video bridges arrive in the attendee list looking exactly like
    /// people, and EventKit does not mark them as resources in any way we can rely on. "Zoom" and
    /// "Huddle" are four letters, are not English words a meeting says often enough to be in the
    /// common-words list, and would sail through every other rule here — then boost every "zoom" in
    /// every transcript in the folder.
    ///
    /// Matched against the whole display name rather than the surname: "Torch0 Board Room" is a room
    /// however its tokens are arranged, and one resource word anywhere in the name is enough.
    static func isResource(_ displayName: String) -> Bool {
        let tokens = displayName.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
        return tokens.contains { resourceWords.contains($0) }
    }

    /// Deliberately short. Every entry costs anyone actually surnamed that their vocabulary term, so
    /// this holds only words that are far more likely to be furniture than a person.
    static let resourceWords: Set<String> = [
        "room", "rooms", "conference", "boardroom", "board", "huddle", "zoom", "webex", "teams",
        "meet", "hangout", "bridge", "projector", "polycom", "telepresence", "screen", "display",
        "resource", "equipment", "booking", "desk", "phone", "speakerphone", "auditorium",
        "kitchenette", "breakout", "annexe", "floor", "wing", "unbookable", "notbookable",
    ]

    /// Splits a display name into name-shaped tokens. Punctuation that is part of a name survives —
    /// `Ma'agan`, `Nunes-Silva` — surrounding punctuation is trimmed, and a token still holding
    /// anything that is not a letter is dropped whole. That last rule is what keeps a name EventKit
    /// hands over as `Sofia Nunes (Torch0)` from seeding `Torch0`: it may well be a term worth
    /// having, but an attendee field is not evidence for it.
    static func nameTokens(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
            let trimmed = token.trimmingCharacters(in: nameEdgeNoise)
            guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy(isNameScalar) else { return nil }
            return trimmed
        }
    }

    private static let nameEdgeNoise = CharacterSet(charactersIn: "()[]{}<>,.;:!?\"'\u{2018}\u{2019}\u{201C}\u{201D}-")

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(scalar) || scalar == "'" || scalar == "\u{2019}" || scalar == "-"
    }

    /// A standalone token is only worth seeding if it is long enough to be distinctive and is not a
    /// word the speaker will use anyway.
    static func isSeedable(_ token: String) -> Bool {
        token.count >= minimumTokenLength && !commonWords.contains(token.lowercased())
    }

    /// The bundled list, loaded once. Lines beginning with `#` are the file's own provenance note.
    static let commonWords: Set<String> = {
        guard let url = Bundle.module.url(
            forResource: "common-words",
            withExtension: "txt",
            subdirectory: "Resources"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Loud, because the quiet failure is far worse: with no list, every attendee surname
            // that happens to be an English word gets seeded and the transcripts degrade in a way
            // nobody would trace back to a missing resource.
            preconditionFailure("common-words.txt is missing from MeetingsCore's bundle — the auto-seed guard cannot run without it")
        }
        return Set(
            text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
    }()
}
