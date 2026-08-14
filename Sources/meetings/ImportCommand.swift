import ArgumentParser
import Foundation
import MeetingsCore

/// `meetings import <bundle> [--folder <name>] [--dry-run]`.
///
/// Machine-to-machine restore, and the one import path that needs no agent: the format is ours and
/// it is lossless. Everything else — legacy dumps, third-party exports, loose audio — goes through
/// `meetings create`, driven by an agent that has actually read the files.
///
/// **It never overwrites.** If the bundle's meeting id is already here, or this machine already
/// materialised the same calendar event, the import lands as a *new* meeting recording where it came
/// from in `imported_from`. Import the same bundle twice and you get two independent meetings, with
/// the first untouched — that is the documented behaviour, not an accident of it.
struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Restore a .meetingbundle. Lossless, and never overwrites.",
        discussion: """
            The bundle keeps its folder unless --folder names another one, creating it if this \
            store has never seen it.

            --dry-run reports what the import would do and writes nothing.
            """
    )

    @Argument(help: "Path to a .meetingbundle directory.")
    var bundle: String

    @Option(name: .long, help: "Put the meeting in this folder instead of the one in the bundle.")
    var folder: String?

    @Flag(name: .long, help: "Report what would happen and write nothing.")
    var dryRun = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let url = try IOPath.mustExist(bundle)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard isDirectory.boolValue else {
                throw CLIError.usage(
                    "\(bundle) is a file. A .meetingbundle is a directory. Unzip it first."
                )
            }

            let context = try CLIContext.open()
            let contents: MeetingBundle.Contents
            do {
                contents = try MeetingBundle.read(at: url)
            } catch let error as BundleError {
                // A malformed bundle is not an "unexpected failure" — it is a thing the agent
                // pointed us at that is not what it said it was. Exit 2, or 3 for a bundle from a
                // newer build, which is a state this binary cannot handle rather than a bad path.
                switch error {
                case .unsupportedSchema:
                    throw CLIError.invalidState(error.errorDescription ?? "\(error)")
                case .missingFile, .unreadableFile, .notABundle:
                    throw CLIError.notFound(error.errorDescription ?? "\(error)")
                }
            }
            let result = dryRun
                ? try context.store.planBundleImport(contents, bundleName: url.lastPathComponent, folderName: folder)
                : try MeetingBundle.restore(at: url, into: context.store, folderName: folder)

            // An imported meeting can arrive already complete, and the markdown export fires
            // on reaching complete — on this machine it has just done so for the first time.
            if !dryRun {
                _ = try? MarkdownExport.exportIfEnabled(meetingID: result.meeting.id, store: context.store)
            }

            // On a dry run the folder does not exist to look up, so the plan's own answer comes
            // first — otherwise the report would leave out the one thing --dry-run is asked about.
            var folderName = result.folderCreated
            if folderName == nil, let folderID = result.meeting.folderID {
                folderName = try context.store.folder(id: folderID)?.name
            }
            if global.json {
                try Out.json(ImportResultJSON(
                    ref: result.meeting.id,
                    title: result.meeting.title,
                    state: result.meeting.state.rawValue,
                    folder: folderName,
                    segments: result.segmentCount,
                    notes: result.noteCount,
                    audio: result.hasAudio,
                    idCollision: result.idCollision,
                    importedFrom: result.meeting.importedFrom,
                    folderCreated: result.folderCreated,
                    dryRun: dryRun
                ))
                return
            }

            Out.line(dryRun ? "Would import \(result.meeting.title)" : "Imported \(result.meeting.title)")
            var rows = [
                ["ref", result.meeting.id],
                ["state", result.meeting.state.rawValue],
                ["transcript", "\(result.segmentCount) segments"],
                ["notes", "\(result.noteCount)"],
            ]
            if let folderName { rows.append(["folder", folderName + (result.folderCreated == nil ? "" : " (new)")]) }
            if result.hasAudio { rows.append(["audio", dryRun ? "in the bundle" : "copied in"]) }
            if result.idCollision {
                rows.append(["new id", "the bundle's id is already in this store; the existing meeting is untouched"])
            }
            if let from = result.meeting.importedFrom { rows.append(["imported from", from]) }
            Out.line(Format.columns(rows).joined(separator: "\n"))
            if dryRun { Out.note("Nothing was written.") }
        }
    }
}
