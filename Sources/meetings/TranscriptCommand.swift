import ArgumentParser
import Foundation
import MeetingsCore

enum TranscriptFormat: String, CaseIterable, ExpressibleByArgument {
    case md, json, srt
}

struct TranscriptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Print a meeting's transcript.",
        discussion: """
            Lines are labelled by speaker. You is the microphone, whoever is at this Mac. Others is \
            everything that came out of the speakers. Channel separation is the only attribution \
            v1 has.

            --chunks <minutes> splits a long transcript into labelled time windows, so it can be \
            summarised window by window. --range narrows to one window: 5:00-12:30, -10:00, 45:00-.
            """
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>.")
    var ref: String

    @Option(name: .long, help: "Only one channel: mic or system.")
    var channel: Channel?

    @Option(name: .long, help: "md, json or srt.")
    var format: TranscriptFormat = .md

    @Option(name: .long, help: "Only this time window, as <start>-<end>.")
    var range: String?

    @Option(name: .long, help: "Split into windows of this many minutes.")
    var chunks: Int?

    @OptionGroup var global: GlobalOptions

    /// `--json` is the flag every command shares, so it wins over `--format` rather than fighting it.
    private var effectiveFormat: TranscriptFormat { global.json ? .json : format }

    func validate() throws {
        if let chunks, chunks <= 0 {
            throw ValidationError("--chunks takes a number of minutes greater than zero.")
        }
        if chunks != nil, effectiveFormat == .srt {
            throw ValidationError("--chunks cannot be used with --format srt: SRT has nowhere to put a chunk heading.")
        }
    }

    func run() async throws {
        try await emitting(json: effectiveFormat == .json) {
            let context = try CLIContext.open()
            let bounds = try range.map(Parse.range)

            var title = ""
            var segments: [TranscriptSegment] = []
            // A half transcript that reads as a whole one is the failure this carries. `show` and
            // `list` already say it; this is the command the bundled skill sends an agent to for
            // anything over forty minutes, so it is the one place it most has to be said.
            var issues: [TranscriptIssue] = []
            switch try await context.readTarget(ref) {
            case .event(let event):
                title = event.title
            case .meeting(let meeting):
                title = meeting.title
                segments = try context.store.segments(meetingID: meeting.id, channel: channel)
                issues = (try? context.store.transcriptIssues(meetingID: meeting.id)) ?? []
            }

            if let bounds {
                // A segment that straddles the boundary is in: the sentence you asked for is not
                // improved by being cut off at its first word.
                segments = segments.filter { $0.tEndMs > bounds.startMs && $0.tStartMs < bounds.endMs }
            }

            let windows = chunks.map { Chunker.split(segments, everyMinutes: $0, from: bounds?.startMs ?? 0) }

            switch effectiveFormat {
            case .json:
                try Out.json(TranscriptJSON(
                    ref: ref,
                    title: title,
                    channel: channel?.rawValue ?? "all",
                    speakerLabels: [Channel.mic.rawValue: Channel.mic.speakerLabel,
                                    Channel.system.rawValue: Channel.system.speakerLabel],
                    range: bounds.map { RangeJSON(startMs: $0.startMs, endMs: $0.endMs == .max ? nil : $0.endMs) },
                    segmentCount: segments.count,
                    // The same key, spelled the same way, that `show --json` and `list --json`
                    // already carry — and absent, not empty, on a whole transcript, so an agent
                    // branches on one rule everywhere.
                    transcriptIssues: issues.nilIfEmpty?.map(TranscriptIssueJSON.init),
                    segments: windows == nil ? segments.map(SegmentJSON.init) : nil,
                    chunks: windows?.map(ChunkJSON.init)
                ))
            case .md:
                // On stdout, and first. This output is markdown an agent reads and quotes from; a
                // warning left on stderr does not survive a `>` or a pipe, and the whole failure
                // being fixed is a write-up made from half a conversation. A blockquote, so it
                // reads as an annotation rather than as something somebody said.
                if !issues.isEmpty {
                    Out.line(issues.map { "> \($0.sentence)" }.joined(separator: "\n"))
                    Out.line()
                }
                guard !segments.isEmpty else {
                    Out.note("\(title) has no transcript\(range == nil ? "" : " in that range").")
                    return
                }
                if let windows {
                    Out.line(windows.enumerated().map { index, window in
                        """
                        ## chunk \(index + 1) of \(windows.count)  \
                        \(Format.offset(ms: window.startMs))-\(Format.offset(ms: window.endMs))
                        \(TranscriptRender.markdown(window.segments).joined(separator: "\n"))
                        """
                    }.joined(separator: "\n\n"))
                } else {
                    Out.line(TranscriptRender.markdown(segments).joined(separator: "\n"))
                }
            case .srt:
                // stderr, alone of the three. SubRip has exactly one kind of record in it — a
                // numbered cue with a time span — so the only way to put this fact on stdout is to
                // forge a cue, which would show up on screen over the video as if somebody had said
                // it, and would renumber every real cue after it. A subtitle file has nowhere for a
                // non-subtitle fact, so it goes where the file is not: stderr, where the person
                // running the command reads it and the redirected file stays a valid .srt.
                for issue in issues { Out.note(issue.sentence) }
                guard !segments.isEmpty else {
                    Out.note("\(title) has no transcript\(range == nil ? "" : " in that range").")
                    return
                }
                Out.line(TranscriptRender.srt(segments))
            }
        }
    }
}

enum TranscriptRender {
    /// `[0:12] You: …` — the timestamp first so a grep for a line gives you the offset to seek to.
    static func markdown(_ segments: [TranscriptSegment]) -> [String] {
        segments.map { segment in
            "[\(Format.offset(ms: segment.tStartMs))] \(segment.channel.speakerLabel): \(Format.oneLine(segment.text))"
        }
    }

    /// SubRip: an index line, `hh:mm:ss,mmm --> hh:mm:ss,mmm`, the text, then a blank line. The
    /// decimal separator is a comma — a point makes the file invalid, quietly, in most players.
    static func srt(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(Format.srtTimestamp(ms: segment.tStartMs)) --> \(Format.srtTimestamp(ms: max(segment.tEndMs, segment.tStartMs + 1)))
            \(segment.channel.speakerLabel): \(Format.oneLine(segment.text))

            """
        }.joined(separator: "\n")
    }
}

/// The map-reduce path for a long meeting (the bundled skill's rule is that anything over
/// forty minutes is read in chunks).
enum Chunker {
    struct Window {
        let startMs: Int
        let endMs: Int
        let segments: [TranscriptSegment]
    }

    /// Windows of `everyMinutes`, anchored at `from` so a `--range` and a `--chunks` agree on where
    /// window one begins. A window with no speech in it is dropped rather than emitted empty: an
    /// agent summarising chunk by chunk should not be handed a heading with nothing under it.
    static func split(_ segments: [TranscriptSegment], everyMinutes minutes: Int, from startMs: Int) -> [Window] {
        guard let last = segments.map(\.tEndMs).max(), minutes > 0 else { return [] }
        let width = minutes * 60_000
        var windows: [Window] = []
        var lower = startMs
        while lower <= last {
            let upper = lower + width
            let inside = segments.filter { $0.tStartMs >= lower && $0.tStartMs < upper }
            if !inside.isEmpty {
                // Clamped to where the talking stops, so the last chunk of a 52-minute meeting is
                // labelled 45:00-52:00 and not 45:00-1:00:00. The label is also a `--range` you can
                // paste back, and one that runs eight minutes past the end is a small lie.
                windows.append(Window(startMs: lower, endMs: min(upper, last), segments: inside))
            }
            lower = upper
        }
        return windows
    }
}

private struct RangeJSON: Encodable {
    let startMs: Int
    let endMs: Int?
}

private struct ChunkJSON: Encodable {
    let startMs: Int
    let endMs: Int
    let label: String
    let segments: [SegmentJSON]

    init(_ window: Chunker.Window) {
        self.startMs = window.startMs
        self.endMs = window.endMs
        self.label = "\(Format.offset(ms: window.startMs))-\(Format.offset(ms: window.endMs))"
        self.segments = window.segments.map(SegmentJSON.init)
    }
}

private struct TranscriptJSON: Encodable {
    let ref: String
    let title: String
    let channel: String
    /// Spelled out in the payload so an agent reading only the JSON knows what You and Others mean.
    let speakerLabels: [String: String]
    let range: RangeJSON?
    let segmentCount: Int
    /// Absent when the transcript is whole, exactly as in `show --json` and `list --json`.
    let transcriptIssues: [TranscriptIssueJSON]?
    let segments: [SegmentJSON]?
    let chunks: [ChunkJSON]?
}
