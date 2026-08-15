import Foundation

/// The one-way markdown export: `~/Meetings/<folder>/<yyyy-mm-dd-slug>/` with
/// `meta.json`, `notes.md`, `transcript.md` and `summary.md`.
///
/// **This is not a backup and there is no importer for it.** Channel labels become prose, anchors
/// become timestamps, and the state machine is flattened into a field in `meta.json`. It exists so
/// the meeting is readable in Obsidian, and the difference matters: exporting to
/// markdown and calling it a backup is how people lose data. Machine-loss protection is
/// ``MeetingBundle``.
public enum MarkdownExport {
    /// Writes the meeting's directory under `root` and returns it.
    ///
    /// A section with nothing in it is not written: a meeting with notes and no audio is legal
    ///, and an empty `transcript.md` would claim it was recorded and came out silent.
    @discardableResult
    public static func export(_ meeting: Meeting, store: MeetingStore, to root: URL) throws -> URL {
        let folderName = try meeting.folderID.flatMap { try store.folder(id: $0)?.name }
        let directory = root
            .appendingPathComponent(folderName ?? "Unfiled", isDirectory: true)
            .appendingPathComponent(MeetingBundle.slugName(for: meeting), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let segments = try store.segments(meetingID: meeting.id)
        let notes = try store.notes(meetingID: meeting.id)

        try write(meta(meeting, folder: folderName), to: directory.appendingPathComponent("meta.json"))
        try write(notesMarkdown(meeting, notes: notes), to: directory.appendingPathComponent("notes.md"))
        try write(transcriptMarkdown(meeting, segments: segments), to: directory.appendingPathComponent("transcript.md"))
        try write(summaryMarkdown(meeting), to: directory.appendingPathComponent("summary.md"))
        return directory
    }

    /// The automatic run on reaching `complete`. Does nothing unless
    /// `export.markdownOnComplete` is on, so the default install writes nothing to `~/Meetings`.
    ///
    /// Call this from every path that moves a meeting to `complete`.
    @discardableResult
    public static func exportIfEnabled(meetingID: String, store: MeetingStore) throws -> URL? {
        guard try store.settingBool(.exportMarkdownOnComplete) == true,
              let meeting = try store.meeting(id: meetingID),
              meeting.state == .complete
        else { return nil }
        return try export(meeting, store: store, to: try root(store: store))
    }

    /// `export.markdownRoot` if the user set one, else `$MEETINGS_MD_ROOT`, else `~/Meetings`.
    public static func root(store: MeetingStore) throws -> URL {
        if let configured = try store.setting(.exportMarkdownRoot), !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return Paths.markdownRoot
    }

    // MARK: - The four files

    private struct Meta: Encodable {
        let id: String
        let title: String
        let state: String
        let folder: String?
        let scheduledStart: Date?
        let scheduledEnd: Date?
        let startedAt: Date?
        let endedAt: Date?
        let attendees: [Attendee]
        let actions: [Action]?
        let source: String
        let importedFrom: String?
        /// Said out loud in the export itself, so nobody finds this directory in two years and
        /// assumes it can be restored from.
        let exportFormat = "markdown (one-way; use a .meetingbundle to restore)"
    }

    private static func meta(_ meeting: Meeting, folder: String?) -> Meta {
        Meta(
            id: meeting.id,
            title: meeting.title,
            state: meeting.state.rawValue,
            folder: folder,
            scheduledStart: meeting.scheduledStart,
            scheduledEnd: meeting.scheduledEnd,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            attendees: meeting.attendees,
            // Out of the write-up, which is where actions live now — the column may still hold an
            // older list the migration copied out of it, and exporting that would contradict the
            // summary.md sitting beside this file.
            //
            // `owner` and `due` still come off the column, through the same rule the bundle uses:
            // the markdown cannot express either, so on a migrated store the column is their only
            // copy, and deriving the whole action from the write-up made this export the one that
            // destroyed them. That is worth naming here — this is the export a person reaches for
            // when they are taking their meetings off the machine.
            actions: MeetingBundle.withLegacyOwnerAndDue(
                MarkdownActions.parse(meeting.summary ?? ""), from: meeting.actions),
            source: meeting.source.rawValue,
            importedFrom: meeting.importedFrom
        )
    }

    /// Pre-notes and live notes in one file, because that is what "my notes" means to the person
    /// reading it later. The live ones keep their offset — flattened from an anchor, which is
    /// precisely the loss that makes this export one-way.
    private static func notesMarkdown(_ meeting: Meeting, notes: [Note]) -> String? {
        var parts: [String] = []
        if let preNotes = meeting.preNotes.trimmedOrNil {
            parts.append("## Before the meeting\n\n\(preNotes)")
        }
        if !notes.isEmpty {
            let lines = notes.map { "- **\(timestamp($0.tOffsetMs))** \($0.text)" }.joined(separator: "\n")
            parts.append("## During the meeting\n\n\(lines)")
        }
        guard !parts.isEmpty else { return nil }
        return "# \(meeting.title): notes\n\n" + parts.joined(separator: "\n\n") + "\n"
    }

    private static func transcriptMarkdown(_ meeting: Meeting, segments: [TranscriptSegment]) -> String? {
        guard !segments.isEmpty else { return nil }
        let lines = segments.map { segment in
            "**\(timestamp(segment.tStartMs))** \(label(segment.channel)): \(oneLine(segment.text))"
        }
        return "# \(meeting.title): transcript\n\n" + lines.joined(separator: "\n\n") + "\n"
    }

    /// The write-up, as written. The actions used to be appended here from the column; they are task
    /// list items inside the summary now, so appending them again would print every one of them
    /// twice on any meeting whose column the migration left populated.
    private static func summaryMarkdown(_ meeting: Meeting) -> String? {
        var parts: [String] = []
        if let summary = meeting.summary?.trimmedOrNil { parts.append(summary) }
        guard !parts.isEmpty else { return nil }
        // An agent's summary usually opens with its own heading, and two H1s in a row is how a
        // markdown file starts looking machine-made.
        let heading = (meeting.summary?.trimmedOrNil?.hasPrefix("#") ?? false) ? "" : "# \(meeting.title)\n\n"
        return heading + parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: -

    /// mic is whoever is at this Mac, system is everything else in the call. The markdown
    /// says who spoke, not which device heard them.
    private static func label(_ channel: Channel) -> String {
        switch channel {
        case .mic: "You"
        case .system: "Others"
        }
    }

    private static func timestamp(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A nil body deletes any file left from a previous export rather than leaving a stale one: the
    /// export directory has to describe the meeting as it is now, not as it was two exports ago.
    private static func write(_ body: String?, to url: URL) throws {
        guard let body else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try Data(body.utf8).write(to: url)
    }

    private static func write(_ meta: Meta, to url: URL) throws {
        var data = try MeetingBundle.encoder.encode(meta)
        data.append(0x0A)
        try data.write(to: url)
    }
}

extension String {
    var trimmedOrNil: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
