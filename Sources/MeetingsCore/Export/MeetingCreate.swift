import Foundation

/// `meetings create`: explicit, fully-specified creation. The second entry point into
/// the lifecycle — `created → transcribing → ready` — for everything that is not a `.meetingbundle`.
///
/// **Nothing here infers anything.** No filename date parsing, no mtime fallback, no title guessing,
/// no third-party adapters. The reason: an agent that reads the actual
/// files and asks when unsure does this better than any heuristic, and a heuristic that is wrong 5%
/// of the time across 200 meetings is worse than useless. Every field in ``Request`` is given by the
/// caller or is absent, and absent stays absent.
public enum MeetingCreate {
    public struct Request: Sendable {
        public var title: String
        /// When the meeting happened. Lands on `started_at`: this is a record of something that took
        /// place, not something on a calendar, so `scheduled_start` stays null.
        public var date: Date
        public var duration: TimeInterval?
        public var folderName: String?
        public var attendees: [Attendee]
        public var audio: URL?
        public var transcript: [TranscriptDraft]
        public var summary: String?
        public var preNotes: String?
        public var source: MeetingSource
        /// What this meeting was made from, for the `imported_from` column. The CLI fills it with
        /// the source filename.
        public var importedFrom: String?

        public init(
            title: String,
            date: Date,
            duration: TimeInterval? = nil,
            folderName: String? = nil,
            attendees: [Attendee] = [],
            audio: URL? = nil,
            transcript: [TranscriptDraft] = [],
            summary: String? = nil,
            preNotes: String? = nil,
            source: MeetingSource = .recorded,
            importedFrom: String? = nil
        ) {
            self.title = title
            self.date = date
            self.duration = duration
            self.folderName = folderName
            self.attendees = attendees
            self.audio = audio
            self.transcript = transcript
            self.summary = summary
            self.preNotes = preNotes
            self.source = source
            self.importedFrom = importedFrom
        }
    }

    public struct Result: Sendable {
        public let meeting: Meeting
        public let segmentCount: Int
        /// Where the converted audio landed, when there was any.
        public let audioFile: URL?
        /// The markdown directory, when `export.markdownOnComplete` is on and the meeting landed at
        /// `complete`.
        public let markdownDirectory: URL?
    }

    /// Creates the row and everything hanging off it.
    ///
    /// The state rule: **audio present → `transcribing`**, and the store is the batch
    /// queue, so the app picks it up on its next launch or `TranscriptionService.enqueue` does it
    /// now. **Audio absent → `complete` immediately**, which is why a meeting with notes and no
    /// transcript is legal and needs nothing else to happen to it.
    ///
    /// The CLI deliberately does not run the batch pass inline: migrating a backlog means calling
    /// this two hundred times, and a command that blocks for a 600 MB model download and then a
    /// minute of compute per meeting is not something an agent can drive.
    @discardableResult
    public static func create(
        _ request: Request,
        store: MeetingStore,
        audioRoot: URL? = nil
    ) throws -> Result {
        var folder: Folder?
        if let name = request.folderName?.trimmedOrNil {
            folder = try store.folderNamedOrCreated(name)
        }
        let hasAudio = request.audio != nil

        var meeting = Meeting(
            folderID: folder?.id,
            title: request.title,
            state: hasAudio ? .transcribing : .complete,
            startedAt: request.date,
            endedAt: request.duration.map { request.date.addingTimeInterval($0) },
            attendees: request.attendees,
            preNotes: request.preNotes ?? "",
            summary: request.summary,
            source: request.source,
            importedFrom: request.importedFrom
        )

        // Convert before the row exists, so a file AVFoundation cannot read fails the command
        // instead of leaving a meeting behind that will never transcribe.
        var audioFile: URL?
        if let source = request.audio {
            audioFile = try AudioIngest.install(source, forMeeting: meeting.id, audioRoot: audioRoot)
            meeting.audioPath = audioFile?.deletingLastPathComponent().path
        }

        do {
            try store.createMeeting(meeting)
        } catch {
            // Nothing else has run yet, so the only thing to undo is the converted audio.
            if let audioFile { try? FileManager.default.removeItem(at: audioFile.deletingLastPathComponent()) }
            throw error
        }

        if !request.transcript.isEmpty {
            try store.insertSegments(request.transcript.map { $0.segment(meetingID: meeting.id) })
        }
        // Attendee names are the first vocabulary source, and the batch pass that is
        // about to run on this meeting is exactly what they exist for. Best-effort on purpose: the
        // meeting row is already in, and losing a vocabulary term is not worth failing a migration
        // of two hundred meetings over.
        _ = try? AutoSeed.seed(attendees: request.attendees, folderID: folder?.id, into: store)

        let markdown = try MarkdownExport.exportIfEnabled(meetingID: meeting.id, store: store)
        return Result(
            meeting: try store.meeting(id: meeting.id) ?? meeting,
            segmentCount: request.transcript.count,
            audioFile: audioFile,
            markdownDirectory: markdown
        )
    }

    // MARK: - Parsing the explicit inputs

    /// `--attendees "Will,Sofia Nunes,sofia@example.com"`. A token containing `@` is an email,
    /// anything else is a display name. Nothing is looked up and nothing is split further — an agent
    /// that knows both writes `Name <mail@example.com>`.
    public static func attendees(from raw: String) -> [Attendee] {
        raw.split(separator: ",").compactMap { token -> Attendee? in
            let value = token.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            if let open = value.firstIndex(of: "<"), value.hasSuffix(">") {
                let name = value[value.startIndex..<open].trimmingCharacters(in: .whitespaces)
                let email = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
                return Attendee(name: name.isEmpty ? nil : name, email: email)
            }
            return value.contains("@") ? Attendee(email: value) : Attendee(name: value)
        }
    }

    /// `45m`, `1h30m`, `90`, `1.5h`, `2700s`. A bare number is minutes, because that is the unit the
    /// documented example uses (`--duration 45m`) and the unit a person knows a meeting in.
    public static func duration(from raw: String) -> TimeInterval? {
        let raw = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty else { return nil }
        if let minutes = Double(raw) { return minutes >= 0 ? minutes * 60 : nil }

        var total: Double = 0
        var number = ""
        var sawUnit = false
        for character in raw {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = Double(number) else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            sawUnit = true
            number = ""
        }
        // A trailing number with no unit ("1h30") would have to be guessed at. It is not.
        guard sawUnit, number.isEmpty, total >= 0 else { return nil }
        return total
    }

    /// `--date`. A full ISO-8601 instant (`2025-11-04T14:00Z`), a local date-time
    /// (`2025-11-04T14:00`) or a bare day (`2025-11-04`, which means midnight local).
    ///
    /// Relative forms like `7d` are accepted by `--since` on the read commands and deliberately not
    /// here: "a week ago" is a search window, but as a meeting's date it is a guess written to disk.
    public static func date(from raw: String) -> Date? {
        let raw = raw.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(raw, strategy: .iso8601) { return date }
        // The zone-bearing forms come first, and `2025-11-04T14:00Z` is among them because it is the
        // form the documented example uses — ISO8601FormatStyle insists on the seconds it omits.
        // DateFormatter is strict about trailing characters, so a local-time format cannot swallow a
        // string that carries a zone and silently reinterpret it.
        for format in [
            "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

/// One segment as `--transcript-file` gives it: the bundle's transcript shape with everything but
/// the text and the start offset optional.
public struct TranscriptDraft: Decodable, Sendable, Equatable {
    public var channel: Channel
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var edited: Bool

    public init(channel: Channel = .mic, startMs: Int, endMs: Int? = nil, text: String, edited: Bool = false) {
        self.channel = channel
        self.startMs = startMs
        self.endMs = endMs ?? startMs
        self.text = text
        self.edited = edited
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startMs = try container.decodeIfPresent(Int.self, forKey: .startMs) ?? 0
        self.init(
            channel: try container.decodeIfPresent(Channel.self, forKey: .channel) ?? .mic,
            startMs: startMs,
            endMs: try container.decodeIfPresent(Int.self, forKey: .endMs) ?? startMs,
            text: try container.decode(String.self, forKey: .text),
            edited: try container.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey { case channel, startMs, endMs, text, edited }

    func segment(meetingID: String) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meetingID,
            channel: channel,
            tStartMs: startMs,
            tEndMs: max(endMs, startMs),
            text: text,
            // A transcript handed to `create` is the authoritative one for that meeting; there is no
            // live pass behind it to replace.
            pass: .final,
            edited: edited
        )
    }
}

extension TranscriptDraft {
    /// Reads a `--transcript-file`. Two shapes, and no third:
    ///
    /// - **JSON** — the bundle's `transcript.json` array (`channel`, `startMs`, `endMs`, `text`),
    ///   with everything but `text` optional. Timings survive, so notes anchor and `--range` works.
    /// - **Anything else** — plain text or markdown, which lands as **one** segment covering the
    ///   whole meeting.
    ///
    /// The second case is deliberately crude. Splitting prose into per-line segments would mean
    /// inventing a timestamp for every line, and that kind of guess is exactly what this must not do. One
    /// honest segment keeps the text searchable and readable without claiming anybody said a
    /// particular sentence at 12:30. The channel is `mic` for the same reason ``AudioIngest`` uses
    /// it: an imported transcript is everyone in the room, and `mic` is the channel that means
    /// "what this machine heard".
    ///
    /// **A file that is trying to be JSON and fails is an error, never prose.** The fallback used to
    /// swallow it: a transcript with a `segments` wrapper, or a typo'd key, or a truncated array,
    /// landed as one segment containing its own source code, attributed to "You", exit 0, state
    /// `complete`. Across a two-hundred-meeting migration that corrupts quietly and reads as
    /// success, and the migration is the one job where nobody re-reads the output. So the first
    /// non-space character decides which of the two shapes was meant, and a `{` or `[` that will not
    /// decode is a usage error carrying the parse failure — exit 64, nothing written.
    ///
    /// **The sniff reads normalised bytes, not the file's.** A byte-order mark is invisible in every
    /// editor that writes one, so a BOM'd `{` sniffs as prose and walks straight past the guard
    /// above — the malformed JSON lands as one segment of its own source code, exit 0, exactly the
    /// failure the guard exists to stop. Windows editors write BOMs constantly and a migration is
    /// where those files come from, so ``utf8Body`` strips the mark (and transcodes UTF-16, which
    /// those same editors write) before anything looks at the first character.
    public static func parse(_ data: Data, durationMs: Int?) throws -> [TranscriptDraft] {
        let data = utf8Body(data)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let opener = text.first, opener == "{" || opener == "[" {
            do {
                return try MeetingBundle.decoder.decode([TranscriptDraft].self, from: data)
            } catch {
                throw InputError.invalid(
                    "That transcript file starts with \(opener), so it is meant to be JSON, but it "
                    + "will not parse as one: \(describe(error)). The shape is an array of "
                    + "{\"channel\": \"mic\"|\"system\", \"startMs\": 0, \"endMs\": 4000, "
                    + "\"text\": \"…\"}. Only text is required. Fix the file, or delete the "
                    + "surrounding \(opener == "{" ? "braces" : "brackets") if you meant to "
                    + "import it as plain prose."
                )
            }
        }
        guard !text.isEmpty else { return [] }
        return [TranscriptDraft(channel: .mic, startMs: 0, endMs: durationMs ?? 0, text: text)]
    }

    /// The file's bytes as plain UTF-8 with no byte-order mark, so one sniff covers every encoding a
    /// text editor is likely to have saved a transcript in.
    ///
    /// UTF-16 is transcoded rather than rejected: `String(decoding:as: UTF8.self)` turns it into
    /// replacement characters, which sniff as prose and would store a segment of mojibake. UTF-32 is
    /// not handled — its little-endian mark starts with UTF-16LE's and nothing has ever handed this
    /// tool one; it decodes to the same mojibake it does today. Leading whitespace needs nothing: the
    /// sniff already trims it.
    static func utf8Body(_ data: Data) -> Data {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return Data(data.dropFirst(3)) }
        guard data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
              // `.utf16` reads the mark to pick the byte order and drops it.
              let text = String(data: data, encoding: .utf16)
        else { return data }
        return Data(text.utf8)
    }

    /// `DecodingError`'s own description is a `CodingPath` dump an agent cannot act on. This says
    /// which element and which key, which is the whole of what it needs to fix the file.
    private static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let steps = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }
            return steps.isEmpty ? "the top level" : "transcript" + steps.joined()
        }
        // `Array<Any>` and `Swift.String` are not words the agent's user typed; JSON's own are.
        func name(_ type: Any.Type) -> String {
            switch "\(type)" {
            case let name where name.hasPrefix("Array"): "array"
            case "String": "string"
            case "Int", "Double": "number"
            case "Bool": "true or false"
            case let other: other
            }
        }
        switch error as? DecodingError {
        case .keyNotFound(let key, let context):
            return "\(path(context)) has no \"\(key.stringValue)\""
        case .typeMismatch(let type, let context), .valueNotFound(let type, let context):
            return "\(path(context)) is not a\(name(type) == "array" ? "n" : "") \(name(type))"
        case .dataCorrupted(let context):
            return context.debugDescription
        default:
            return "\(error)"
        }
    }
}
