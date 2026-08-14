import Foundation

/// The `.meetingbundle` format — lossless, re-importable, and the thing that actually
/// protects against losing a machine. The markdown export is not a backup and cannot be imported;
/// conflating the two is how people lose data, so they share no code and no vocabulary.
///
/// A bundle is a directory:
///
/// ```
/// 2026-08-13-mater-ai-intro.meetingbundle/
///   manifest.json      schema version, export date, source machine
///   meeting.json       the full row: state, timings, attendees, provenance
///   transcript.json    every segment with its channel and offsets
///   notes.json         live notes with their anchors
///   prenotes.md
///   summary.md         only when there is a summary
///   actions.json       only when the actions column is not NULL
///   issues.json        only when a channel failed; what is missing from the transcript
///   audio/             only with --with-audio
/// ```
///
/// Three shapes are load-bearing for the round trip:
///
/// 1. **A note's anchor travels as an *index* into `transcript.json`, never as a segment id.**
///    Segment ids are AUTOINCREMENT and are reassigned on import, so an exported id points at
///    nothing on the far side — and, worse, could point at some other meeting's sentence. The index
///    survives re-id because import inserts the segments in file order and maps position → new id.
/// 2. **The folder travels as a name.** Folder ids are machine-local.
///    Import resolves the name to an existing folder or creates it.
/// 3. **`audio_path` is not in the bundle.** It is a path on the machine that wrote it. Import
///    re-derives it from `Paths.audioDirectory(meetingID:)` after copying the audio in.
/// 4. **`transcript_issues` travel with the transcript.** A meeting whose mic channel failed carries
///    a known half of a conversation, and the row saying so is the only thing that distinguishes it
///    from a whole one. Dropping it on export turned a known-half transcript into an apparently
///    whole one at the exact moment the data moved machines — undoing the fix at the worst possible
///    point, since the receiving machine has no other way to find out.
///
/// Optional-but-empty is preserved as absence: a NULL `actions` column writes no `actions.json`
/// and a NULL summary writes no `summary.md`, so a re-export of an imported bundle is byte-identical
/// rather than turning NULL into `[]` or `""`.
public enum MeetingBundle {
    /// Bumped only for a change the current reader cannot handle. A reader refuses a version it does
    /// not know rather than silently dropping the fields it has never heard of.
    public static let schemaVersion = 1
    public static let pathExtension = "meetingbundle"

    public enum File {
        public static let manifest = "manifest.json"
        public static let meeting = "meeting.json"
        public static let transcript = "transcript.json"
        public static let notes = "notes.json"
        public static let preNotes = "prenotes.md"
        public static let summary = "summary.md"
        public static let actions = "actions.json"
        public static let issues = "issues.json"
        public static let audio = "audio"
    }

    // MARK: - The on-disk shapes

    public struct Manifest: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var exportedAt: Date
        public var sourceMachine: String

        public init(schemaVersion: Int = MeetingBundle.schemaVersion, exportedAt: Date, sourceMachine: String) {
            self.schemaVersion = schemaVersion
            self.exportedAt = exportedAt
            self.sourceMachine = sourceMachine
        }
    }

    /// The meeting row, minus the two fields that mean nothing on another machine: `folder_id`
    /// (carried as `folder`, a name) and `audio_path` (re-derived on import).
    public struct MeetingRow: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var state: MeetingState
        public var folder: String?
        public var calendarEventId: String?
        public var scheduledStart: Date?
        public var scheduledEnd: Date?
        public var startedAt: Date?
        public var endedAt: Date?
        public var attendees: [Attendee]
        public var source: MeetingSource
        public var importedFrom: String?
        public var audioPurgedAt: Date?
    }

    public struct Segment: Codable, Sendable, Equatable {
        public var channel: Channel
        public var startMs: Int
        public var endMs: Int
        public var text: String
        public var pass: Pass
        public var edited: Bool
    }

    /// `anchorSegmentIndex` is a position in `transcript.json`, not a segment id. See the type note.
    public struct NoteRow: Codable, Sendable, Equatable {
        public var offsetMs: Int
        public var anchorSegmentIndex: Int?
        public var text: String
    }

    /// What is missing from this transcript and why. `meetingID` is not carried — it is re-derived
    /// on import, which may hand the meeting a new id anyway.
    public struct IssueRow: Codable, Sendable, Equatable {
        public var channel: Channel
        public var kind: TranscriptIssue.Kind
        public var reason: String
        public var at: Date
    }

    /// Everything read off disk, before any of it touches the store.
    public struct Contents: Sendable {
        public var manifest: Manifest
        public var meeting: MeetingRow
        public var segments: [Segment]
        public var notes: [NoteRow]
        public var preNotes: String
        public var summary: String?
        public var actions: [Action]?
        /// Empty for a meeting whose transcript is whole, which is nearly all of them.
        public var issues: [IssueRow]
        /// Files found under `audio/`, empty when the bundle was written without `--with-audio`.
        public var audio: [URL]
    }

    // MARK: - Naming

    /// `2026-08-13-mater-ai-intro`. The date is the meeting's own, in the local calendar, because
    /// this name is read by a human looking for the meeting they remember having on Thursday.
    ///
    /// A meeting with no date at all is legal, and gets `undated-` rather than today's
    /// date — writing today's date would be inventing a fact, which is the one thing import and
    /// export are not allowed to do.
    public static func slugName(for meeting: Meeting) -> String {
        let slug = slug(meeting.title)
        guard let date = meeting.sortDate else { return "undated-\(slug)" }
        return "\(dayFormatter.string(from: date))-\(slug)"
    }

    public static func directoryName(for meeting: Meeting) -> String {
        "\(slugName(for: meeting)).\(pathExtension)"
    }

    /// Lowercased, ASCII-ish, hyphen-separated, never empty and never long enough to trip a
    /// filesystem's name limit.
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var out = ""
        var pendingSeparator = false
        for character in folded {
            // An apostrophe is inside a word, not between two: Ma'agan is one word, and
            // `ma-agan` reads as two places.
            if character == "'" || character == "\u{2019}" { continue }
            if character.isLetter || character.isNumber {
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
        }
        if out.count > 60 {
            out = String(out.prefix(60))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? "meeting" : out
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Coding

    /// Sorted keys and a fixed date strategy are not cosmetic: "export → import → export is
    /// byte-identical" is a stated acceptance criterion, and a dictionary's iteration order would
    /// break it at random.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Export

    /// Writes the bundle for `meeting` into `parent` and returns its directory.
    ///
    /// `exportedAt` is a parameter so a test can pin it; nothing else passes it.
    @discardableResult
    public static func export(
        _ meeting: Meeting,
        store: MeetingStore,
        to parent: URL,
        withAudio: Bool = false,
        exportedAt: Date = Date(),
        audioRoot: URL? = nil
    ) throws -> URL {
        let directory = parent.appendingPathComponent(directoryName(for: meeting), isDirectory: true)
        // A re-export replaces the bundle rather than merging into it: leaving an `audio/` behind
        // from a previous `--with-audio` run would ship audio the caller did not ask for this time.
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let segments = try store.segments(meetingID: meeting.id)
        let notes = try store.notes(meetingID: meeting.id)
        let folderName = try meeting.folderID.flatMap { try store.folder(id: $0)?.name }

        var indexByID: [Int64: Int] = [:]
        for (index, segment) in segments.enumerated() {
            if let id = segment.id { indexByID[id] = index }
        }

        let manifest = Manifest(exportedAt: exportedAt, sourceMachine: ProcessInfo.processInfo.hostName)
        let row = MeetingRow(
            id: meeting.id,
            title: meeting.title,
            state: meeting.state,
            folder: folderName,
            calendarEventId: meeting.calendarEventID,
            scheduledStart: meeting.scheduledStart,
            scheduledEnd: meeting.scheduledEnd,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            attendees: meeting.attendees,
            source: meeting.source,
            importedFrom: meeting.importedFrom,
            audioPurgedAt: meeting.audioPurgedAt
        )

        try write(manifest, to: directory.appendingPathComponent(File.manifest))
        try write(row, to: directory.appendingPathComponent(File.meeting))
        try write(segments.map(Segment.init), to: directory.appendingPathComponent(File.transcript))
        try write(
            notes.map { note in
                NoteRow(
                    offsetMs: note.tOffsetMs,
                    anchorSegmentIndex: note.anchorSegmentID.flatMap { indexByID[$0] },
                    text: note.text
                )
            },
            to: directory.appendingPathComponent(File.notes)
        )
        try Data(meeting.preNotes.utf8).write(to: directory.appendingPathComponent(File.preNotes))
        if let summary = meeting.summary {
            try Data(summary.utf8).write(to: directory.appendingPathComponent(File.summary))
        }
        if let actions = meeting.actions {
            try write(actions, to: directory.appendingPathComponent(File.actions))
        }
        // Written only when there is something to say, so the overwhelming majority of bundles are
        // byte-identical to the ones the previous build produced.
        let issues = try store.transcriptIssues(meetingID: meeting.id)
        if !issues.isEmpty {
            try write(issues.map(IssueRow.init), to: directory.appendingPathComponent(File.issues))
        }

        if withAudio {
            try copyAudio(for: meeting, audioRoot: audioRoot, into: directory)
        }
        return directory
    }

    private static func copyAudio(for meeting: Meeting, audioRoot: URL?, into directory: URL) throws {
        let source = audioRoot.map { $0.appendingPathComponent(meeting.id, isDirectory: true) }
            ?? Paths.audioDirectory(meetingID: meeting.id)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            // A bundle is the machine-loss copy, and `--with-audio` written without any audio in it
            // is the one failure you find out about after the machine is gone. The row still
            // pointing at a directory that is not there is the honest half of the story.
            if meeting.audioPath != nil {
                FileHandle.standardError.write(Data("""
                    Meetings: \(meeting.title) still points at \(source.path), but there is no audio \
                    there. The bundle was written without it.\n
                    """.utf8))
            }
            return
        }
        let target = directory.appendingPathComponent(File.audio, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for file in files {
            try FileManager.default.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
        }
    }

    private static func write(_ value: some Encodable, to url: URL) throws {
        var data = try encoder.encode(value)
        data.append(0x0A)  // A text file ends in a newline; `diff` complains otherwise, and it is right.
        try data.write(to: url)
    }

    // MARK: - Read

    public static func read(at url: URL) throws -> Contents {
        let manifest: Manifest = try decode(url.appendingPathComponent(File.manifest))
        guard manifest.schemaVersion <= schemaVersion else {
            throw BundleError.unsupportedSchema(manifest.schemaVersion)
        }
        let audioDirectory = url.appendingPathComponent(File.audio, isDirectory: true)
        let audio = ((try? FileManager.default.contentsOfDirectory(
            at: audioDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return Contents(
            manifest: manifest,
            meeting: try decode(url.appendingPathComponent(File.meeting)),
            segments: try decode(url.appendingPathComponent(File.transcript)),
            notes: try decode(url.appendingPathComponent(File.notes)),
            preNotes: try text(url.appendingPathComponent(File.preNotes)) ?? "",
            summary: try text(url.appendingPathComponent(File.summary)),
            actions: try decodeIfPresent(url.appendingPathComponent(File.actions)),
            issues: try decodeIfPresent(url.appendingPathComponent(File.issues)) ?? [],
            audio: audio
        )
    }

    private static func decode<T: Decodable>(_ url: URL) throws -> T {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw BundleError.missingFile(url.lastPathComponent)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // `"\(error)"` on a DecodingError prints its whole `Context` — `dataCorrupted(Swift
            // .DecodingError.Context(codingPath: [], debugDescription: …))` — at somebody whose
            // bundle got truncated. The debug description alone is the sentence: "Unexpected end
            // of file".
            let nsError = error as NSError
            throw BundleError.unreadableFile(
                url.lastPathComponent,
                (nsError.userInfo[NSDebugDescriptionErrorKey] as? String) ?? nsError.localizedDescription
            )
        }
    }

    private static func decodeIfPresent<T: Decodable>(_ url: URL) throws -> T? {
        FileManager.default.fileExists(atPath: url.path) ? try decode(url) : nil
    }

    private static func text(_ url: URL) throws -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Restore

    /// Read a bundle and put it in the store: the whole import path, audio included.
    ///
    /// Never overwrites. A colliding id — or a calendar event this machine has already
    /// materialised — produces a **new** meeting recording where it came from, and the existing row
    /// is not read, not updated and not deleted.
    @discardableResult
    public static func restore(
        at url: URL,
        into store: MeetingStore,
        folderName: String? = nil,
        audioRoot: URL? = nil
    ) throws -> MeetingStore.BundleImportResult {
        let contents = try read(at: url)
        let bundleName = url.lastPathComponent
        var result = try store.importBundle(contents, bundleName: bundleName, folderName: folderName)

        if !contents.audio.isEmpty {
            let directory = audioRoot.map { $0.appendingPathComponent(result.meeting.id, isDirectory: true) }
                ?? Paths.audioDirectory(meetingID: result.meeting.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in contents.audio {
                let destination = directory.appendingPathComponent(file.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: file, to: destination)
            }
            // `audio_path` is set here rather than carried in the bundle: it is this machine's path.
            result.meeting = try store.updateMeeting(id: result.meeting.id) { meeting in
                meeting.audioPath = directory.path
            }
        }
        return result
    }
}

extension MeetingBundle.IssueRow {
    init(_ issue: TranscriptIssue) {
        self.init(channel: issue.channel, kind: issue.kind, reason: issue.reason, at: issue.at)
    }
}

extension MeetingBundle.Segment {
    init(_ segment: TranscriptSegment) {
        self.init(
            channel: segment.channel,
            startMs: segment.tStartMs,
            endMs: segment.tEndMs,
            text: segment.text,
            pass: segment.pass,
            edited: segment.edited
        )
    }
}

public enum BundleError: Error, Equatable, LocalizedError {
    case missingFile(String)
    case unreadableFile(String, String)
    case unsupportedSchema(Int)
    case notABundle(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let name): "The bundle has no \(name)"
        case .unreadableFile(let name, let why): "Cannot read \(name) in the bundle: \(why)"
        case .unsupportedSchema(let version):
            "This bundle is schema version \(version); this build understands up to \(MeetingBundle.schemaVersion)"
        case .notABundle(let path): "\(path) is not a .meetingbundle directory"
        }
    }
}
