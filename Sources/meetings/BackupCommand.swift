import ArgumentParser
import Foundation
import MeetingsCore

/// `meetings backup [--out <path>]`.
///
/// `VACUUM INTO` a dated snapshot, seven kept, oldest pruned. This is **corruption protection**, and
/// it is explicitly not the same thing as `meetings export --all --format bundle`, which is
/// machine-loss protection. A snapshot lives on the same disk as the store it copies; keeping only
/// snapshots means one dead SSD takes the lot.
struct BackupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Snapshot the store with VACUUM INTO. Seven kept, oldest pruned.",
        discussion: """
            With no --out the snapshot goes to <MEETINGS_HOME>/backups/store-<date-time>.db and the \
            directory is pruned to the newest seven. The app takes one of these on every launch.

            A snapshot is a complete SQLite database. Open it with `meetings` by pointing \
            MEETINGS_DB at it. It protects against corruption and a bad write. It does not protect \
            against losing the machine. For that, export bundles and keep them elsewhere.
            """
    )

    @Option(name: .long, help: "Write the snapshot here instead of the backups directory.")
    var out: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let destination = out.map { IOPath.url($0) }
            let before = try StoreBackup.list(in: (destination?.deletingLastPathComponent() ?? Paths.backupsRoot)).count
            let url = try StoreBackup.run(store: context.store, to: destination)
            let kept = try StoreBackup.list(in: url.deletingLastPathComponent())
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes?[.size] as? Int) ?? 0

            if global.json {
                try Out.json(BackupResultJSON(
                    path: url.path,
                    bytes: bytes,
                    kept: kept.map(\.lastPathComponent),
                    pruned: max(0, before + 1 - kept.count)
                ))
                return
            }
            Out.line(url.path)
            Out.note(Format.columns([
                ["size", Format.bytes(bytes)],
                ["kept", "\(kept.count) of the last \(StoreBackup.keep)"],
                ["reopen", "MEETINGS_DB=\(url.path) meetings status"],
            ]).joined(separator: "\n"))
        }
    }
}
