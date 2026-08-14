import ArgumentParser
import Foundation
import MeetingsCore

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search meeting titles, transcripts, notes, pre-notes and summaries.",
        discussion: """
            A meeting can appear more than once. Three matching transcript lines are three hits. \
            The matched words are wrapped in « » inside the snippet.

            A match on the meeting's own title outranks anything found inside it, and stands in for \
            that meeting's other hits rather than being listed alongside them.
            """
    )

    @Argument(help: "What to search for. Words are ANDed; punctuation is treated as text, not syntax.")
    var query: String

    @Option(name: .long, help: "Only meetings in this folder.")
    var folder: String?

    @Option(name: .long, help: "Most hits to return (default 20).")
    var limit: Int = 20

    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard limit > 0 else { throw ValidationError("--limit takes a number greater than zero.") }
    }

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let folderID = try folder.map { try context.folderID(named: $0) }
            let hits = try context.store.search(query: query, folderID: folderID, limit: limit)

            // Words are ANDed *within one* segment, note, pre-note or summary, so "pricing model"
            // misses a meeting that says "hybrid pricing" in one line and "the per-seat model" in
            // another. Zero hits then reads exactly like "no such meeting", and an agent that stops
            // there tells the user nothing is on record. Say what to try next, on stderr so the
            // JSON on stdout is still exactly one value.
            if hits.isEmpty, query.split(whereSeparator: \.isWhitespace).count > 1 {
                Out.note(
                    "Nothing matched all of \(query) inside one line. Words are ANDed within a "
                        + "single transcript line, note, pre-note or summary. Retry with the one "
                        + "strongest word."
                )
            }

            if global.json {
                try Out.json(SearchJSON(query: query, hits: hits.map(HitJSON.init)))
                return
            }

            guard !hits.isEmpty else {
                Out.note("Nothing matched \(query).")
                return
            }

            Out.line(Format.columns(hits.map { hit in
                [
                    hit.meeting.id,
                    Format.when(hit.meeting.sortDate),
                    Self.label(for: hit.kind),
                    "\(Format.oneLine(hit.meeting.title)): \(Format.oneLine(hit.snippet))",
                ]
            }).joined(separator: "\n"))
        }
    }

    /// `segment` is the schema's word for it; `transcript` is what the person searching called it.
    private static func label(for kind: SearchKind) -> String {
        switch kind {
        case .title: "title"
        case .segment: "transcript"
        case .note: "note"
        case .prenotes: "pre-notes"
        case .summary: "summary"
        }
    }
}

private struct HitJSON: Encodable {
    let ref: String
    let title: String
    let state: String
    let date: Date?
    let kind: String
    let sourceId: String
    let snippet: String

    init(_ hit: SearchHit) {
        self.ref = hit.meeting.id
        self.title = hit.meeting.title
        self.state = hit.meeting.state.rawValue
        self.date = hit.meeting.sortDate
        self.kind = hit.kind.rawValue
        self.sourceId = hit.sourceID
        self.snippet = hit.snippet
    }
}

private struct SearchJSON: Encodable {
    let query: String
    let hits: [HitJSON]
}
