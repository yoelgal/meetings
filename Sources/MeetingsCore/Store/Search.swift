import Foundation
import GRDB

/// Where the match was found. The agent asking "what did we decide about Y" cares whether it found
/// the decision in the summary or in a raw transcript line.
///
/// `title` is the odd one out: the other four are documents in the FTS index, while a title is
/// matched against the `meetings` table directly — see ``MeetingStore/search(query:folderID:limit:)``
/// for why. It is listed first because that is also its rank.
public enum SearchKind: String, Codable, Sendable, CaseIterable {
    case title, segment, note, prenotes, summary
}

public struct SearchHit: Sendable, Identifiable {
    public let meeting: Meeting
    public let kind: SearchKind
    /// The matched text with the hit marked, ready to print.
    public let snippet: String
    /// The segment or note rowid, or the meeting id for title, prenotes and summary hits.
    public let sourceID: String

    public var id: String { "\(kind.rawValue):\(sourceID)" }
}

/// Where the keyboard is in a list of hits.
///
/// It lives beside `SearchHit` rather than in the window because `MeetingsApp` is an executable
/// target with no test target behind it, and "the down arrow at the last row must not run off the
/// end" is the one part of the ⌘K palette that is logic rather than layout.
public enum SearchSelection {
    /// Clamped, never wrapping. Wrapping from the last row back to the first means holding the down
    /// arrow quietly re-highlights the top hit, and Return then opens a meeting nobody was reading.
    /// An empty list has no row to be on, so it answers 0 whatever it is asked.
    public static func moved(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, index + delta), count - 1)
    }
}

extension MeetingStore {
    /// Search across meeting titles, transcript segments, live notes, pre-notes and summaries.
    ///
    /// `folderID` nil searches everything; pass a folder to scope it. A meeting can appear more than
    /// once — three transcript lines matching is three hits, which is more useful to an agent than
    /// one row that hides where the match was.
    ///
    /// **Titles are matched outside the FTS index, on purpose.** Every index row is keyed
    /// `rowid = source_id * 4 + kind` (see `Schema.swift`), four disjoint residue classes with
    /// exactly four slots. A fifth kind means a new multiplier, which means rewriting every row in
    /// every existing store in a migration — to index a few dozen words that already sit on the
    /// `meetings` table and can be scanned in one query. The migration buys nothing the scan does
    /// not already give, so it is not written.
    ///
    /// A meeting whose title matched contributes exactly one hit and its body hits are dropped. A
    /// title hit already names the meeting, so listing the same meeting again for a transcript line
    /// is the same answer twice — and it is the stronger signal, so it is the one that survives and
    /// it sorts above every body hit.
    public func search(query: String, folderID: String? = nil, limit: Int = 50) throws -> [SearchHit] {
        // Clamped: SQLite reads a negative LIMIT as "no limit", so `--limit -1` would quietly hand
        // an agent the entire store instead of nothing.
        let limit = max(0, limit)
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty, limit > 0 else { return [] }

        return try dbPool.read { db in
            let titleHits = try Self.titleHits(db, tokens: tokens, folderID: folderID, limit: limit)
            let remaining = limit - titleHits.count
            guard remaining > 0 else { return titleHits }
            return titleHits + (try Self.bodyHits(
                db,
                match: Self.ftsQuery(tokens),
                folderID: folderID,
                excluding: titleHits.map(\.meeting.id),
                limit: remaining
            ))
        }
    }

    /// Meetings whose own name contains every token, newest first.
    ///
    /// ponytail: a scan with `instr`, no index. Titles are one short line per meeting and there are
    /// as many of them as there are meetings; reach for an index when a store gets large enough for
    /// this to show up in the palette.
    private static func titleHits(
        _ db: Database, tokens: [String], folderID: String?, limit: Int
    ) throws -> [SearchHit] {
        // `instr` over a pre-lowered needle rather than LIKE, because LIKE would need `%` and `_`
        // in the user's query escaped and a forgotten escape turns a search for "50%" into a search
        // for everything.
        //
        // ponytail: SQLite's `lower()` folds ASCII only, so a title written "CAFÉ" is not found by
        // "café" — where the FTS index, which folds diacritics, would find it in a transcript. Wire
        // a custom collation if a real store ever trips on it.
        var sql = "SELECT * FROM meetings WHERE "
        sql += tokens.map { _ in "instr(lower(title), ?) > 0" }.joined(separator: " AND ")
        var arguments = StatementArguments(tokens.map { $0.lowercased() })
        if let folderID {
            sql += " AND folder_id = ?"
            arguments += [folderID]
        }
        sql += " ORDER BY coalesce(started_at, scheduled_start) DESC LIMIT ?"
        arguments += [limit]

        return try Meeting.fetchAll(db, sql: sql, arguments: arguments).map { meeting in
            SearchHit(
                meeting: meeting,
                kind: .title,
                snippet: markedTitle(meeting.title, tokens: tokens),
                sourceID: meeting.id
            )
        }
    }

    private static func bodyHits(
        _ db: Database, match: String?, folderID: String?, excluding: [String], limit: Int
    ) throws -> [SearchHit] {
        guard let match else { return [] }
        // The table is named in full rather than aliased: FTS5's MATCH and its auxiliary functions
        // want the table name itself, and an alias is a runtime "no such column" here.
        var sql = """
            SELECT m.*,
                   meetings_fts.kind AS hit_kind,
                   meetings_fts.source_id AS hit_source_id,
                   snippet(meetings_fts, 0, '«', '»', '…', 12) AS hit_snippet
            FROM meetings_fts
            JOIN meetings m ON m.id = meetings_fts.meeting_id
            WHERE meetings_fts MATCH ?
            """
        var arguments: StatementArguments = [match]
        if let folderID {
            sql += " AND m.folder_id = ?"
            arguments += [folderID]
        }
        if !excluding.isEmpty {
            sql += " AND m.id NOT IN (\(excluding.map { _ in "?" }.joined(separator: ", ")))"
            arguments += StatementArguments(excluding)
        }
        sql += " ORDER BY bm25(meetings_fts) ASC LIMIT ?"
        arguments += [limit]

        return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            guard let kind = SearchKind(rawValue: row["hit_kind"]) else { return nil }
            return SearchHit(
                meeting: try Meeting(row: row),
                kind: kind,
                snippet: row["hit_snippet"],
                sourceID: row["hit_source_id"]
            )
        }
    }

    /// The title with each matched token wrapped in the same `«»` FTS5's `snippet()` uses.
    ///
    /// Without this a title hit would arrive with no snippet at all, and the palette renders the
    /// snippet as the second line of every row — so the strongest kind of match would be the one
    /// row that looked broken.
    static func markedTitle(_ title: String, tokens: [String]) -> String {
        var ranges: [Range<String.Index>] = []
        for token in tokens where !token.isEmpty {
            var from = title.startIndex
            while let found = title.range(
                of: token, options: .caseInsensitive, range: from..<title.endIndex
            ) {
                ranges.append(found)
                from = found.upperBound
            }
        }
        // Overlaps are merged rather than emitted twice: searching "cryo cry" would otherwise open
        // a marker inside a marker and the palette's alternating parser would bold the wrong half.
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var marked = ""
        var cursor = title.startIndex
        for range in ranges where range.lowerBound >= cursor {
            marked += title[cursor..<range.lowerBound]
            marked += "«\(title[range])»"
            cursor = range.upperBound
        }
        marked += title[cursor...]
        return marked
    }

    /// Turns whatever the user typed into an FTS5 expression that cannot throw.
    ///
    /// FTS5's MATCH argument is a query language, so a search for `"` or `*` or `a OR` is a syntax
    /// error, not zero results — and a search box that throws on a stray quote is broken. Each
    /// whitespace-separated token becomes a quoted phrase (internal quotes doubled), which strips
    /// every operator of its meaning: `NEAR` searches for the word "near", `*` matches nothing, and
    /// the tokens are implicitly ANDed. Nil means the query had nothing in it to search for, since
    /// an empty MATCH is itself a syntax error.
    ///
    /// The cost is that nobody can type an FTS5 operator on purpose. That is the right trade for a
    /// tool whose search box is aimed at sentences.
    ///
    /// NUL is dropped rather than quoted: SQLite reads the MATCH argument as a C string, so a NUL
    /// anywhere in it ends the expression early and the query fails with `unterminated string` —
    /// the one input that made a function documented as "cannot throw" throw.
    static func ftsQuery(_ raw: String) -> String? { ftsQuery(tokens(raw)) }

    static func ftsQuery(_ tokens: [String]) -> String? {
        let phrases = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        return phrases.isEmpty ? nil : phrases.joined(separator: " ")
    }

    /// The words to search for, shared by the FTS expression and the title scan so the two halves of
    /// one search cannot disagree about where a word starts.
    static func tokens(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\0", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}
