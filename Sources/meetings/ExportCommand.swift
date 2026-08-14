import ArgumentParser
import Foundation
import MeetingsCore

/// `meetings export`.
///
/// ```
/// meetings export <ref> [--format bundle|md] [--out <path>] [--with-audio]
/// meetings export --folder <name> [--all] [--format bundle|md] --out <path>
/// ```
///
/// The two formats are not interchangeable and the help text says so, because the failure this
/// guards against is somebody exporting markdown, calling it a backup, and
/// finding out two years later that timestamps, anchors and channel labels went with it.
struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export meetings as lossless bundles or as one-way markdown.",
        discussion: """
            --format bundle (the default) writes a .meetingbundle directory per meeting: the full \
            row, every transcript segment, live notes with their anchors, pre-notes, summary and \
            actions. It re-imports exactly, so `meetings export --all --format bundle` is the \
            backup you keep off this machine.

            --format md writes <out>/<folder>/<yyyy-mm-dd-slug>/ with meta.json, notes.md, \
            transcript.md and summary.md. It is for reading, and it is NOT re-importable: channel \
            labels, note anchors and exact timings are flattened away. Do not use it as a backup.

            Audio is never included unless you ask for it with --with-audio.
            """
    )

    @Argument(help: "A meeting id, or cal:<eventIdentifier>. Omit it and use --folder or --all.")
    var ref: String?

    @Option(name: .long, help: "Export every meeting in this folder.")
    var folder: String?

    @Flag(name: .long, help: "Export every meeting in the store, or in --folder if one is given.")
    var all = false

    @Option(name: .long, help: "bundle (lossless, re-importable) or md (readable, one-way).")
    var format: ExportFormat = .bundle

    @Option(name: .long, help: "Where to write. Defaults to the working directory for bundles, and to the markdown root for --format md.")
    var out: String?

    @Flag(name: .long, help: "Copy the meeting's audio into the bundle. Bundles only.")
    var withAudio = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let meetings = try select(context)
            guard !meetings.isEmpty else {
                throw CLIError.notFound("Nothing to export.")
            }
            if withAudio, format == .md {
                throw CLIError.usage("--with-audio applies to bundles. Markdown export never carries audio.")
            }

            let destination = try destination(context)
            var exported: [ExportedJSON] = []
            for meeting in meetings {
                let url: URL
                switch format {
                case .bundle:
                    url = try MeetingBundle.export(meeting, store: context.store, to: destination, withAudio: withAudio)
                case .md:
                    url = try MarkdownExport.export(meeting, store: context.store, to: destination)
                }
                exported.append(ExportedJSON(
                    ref: meeting.id,
                    title: meeting.title,
                    format: format.rawValue,
                    path: url.path,
                    withAudio: withAudio && format == .bundle
                ))
            }

            if global.json {
                try Out.json(ExportResultJSON(count: exported.count, exported: exported))
                return
            }
            for item in exported { Out.line(item.path) }
            if format == .md {
                // Was "this can be imported back" for a single meeting, which is the opposite of
                // what markdown is. The one sentence standing between someone and treating an
                // export directory as a backup does not get to be ambiguous, so it does not branch.
                Out.note("Markdown is one-way. None of this can be imported back. Use --format bundle for a backup.")
            }
        }
    }

    /// Which meetings, from the three legal shapes: one ref, a folder, or everything.
    private func select(_ context: CLIContext) throws -> [Meeting] {
        if let ref {
            guard folder == nil, !all else {
                throw CLIError.usage("Give me a ref or --folder/--all, not both.")
            }
            guard let meeting = try context.store.meeting(id: ref) else {
                // A cal: ref has no row and therefore nothing to export — it is a calendar entry,
                // not a meeting. Say that rather than materialising one behind the user's back.
                throw CLIError.notFound(
                    ref.hasPrefix("cal:")
                        ? "\(ref) is a calendar event with no meeting row yet, so there is nothing to export."
                        : "No meeting with id \(ref)"
                )
            }
            return [meeting]
        }
        if let folder {
            let id = try context.folderID(named: folder)
            return try context.store.meetings(folderID: id)
        }
        guard all else {
            throw CLIError.usage("Give me a ref, --folder <name>, or --all.")
        }
        return try context.store.allMeetings()
    }

    private func destination(_ context: CLIContext) throws -> URL {
        if let out { return try IOPath.directory(out) }
        switch format {
        case .bundle:
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        case .md:
            return try MarkdownExport.root(store: context.store)
        }
    }
}
