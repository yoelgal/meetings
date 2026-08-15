import Foundation
import Testing

@testable import MeetingsCore

/// Two processes opening the same brand-new store at the same time.
///
/// This is not a contrived race. The app and the CLI are two processes over one file by design
///, and the first time either runs on a machine the store does not exist yet: the open
/// switches the journal to WAL and then runs the migration. Before the fix this failed 19–20 times
/// out of 20, with `SQLite error 5: database is locked - while executing PRAGMA journal_mode = WAL`
/// or `SQLite error 1: table folders already exists`. Neither is covered by the busy timeout — one
/// reports a lock instead of waiting for one, the other is SQLITE_ERROR.
///
/// It has to be real processes. Two `MeetingsDatabase.open` calls on threads of one process share
/// SQLite's own file-lock bookkeeping and do not reproduce it.
@Suite struct StoreOpenRaceTests {
    /// The CLI binary, built into the same directory as this target's resource bundle. `swift test`
    /// builds it as part of the package, so it is always there.
    static let cli: URL = Bundle.module.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent("meetings")

    @Test func twentyRacesOnAFreshStoreAllSucceed() throws {
        try #require(FileManager.default.fileExists(atPath: Self.cli.path),
                     "the meetings CLI is not built at \(Self.cli.path)")
        let root = try TestStore.makeDirectory()
        defer { TestStore.remove(root) }

        var failures: [String] = []
        for run in 0..<20 {
            let home = root.appendingPathComponent("run-\(run)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

            // `status` is the cheapest command that opens the store and reads from it.
            let processes = try (0..<2).map { _ in try launch(home: home) }
            // Drained before waiting: `readDataToEndOfFile` returns at exit anyway, and waiting
            // first would deadlock a process that outgrew the pipe buffer.
            let outputs = processes.map {
                String(decoding: $0.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            }
            for (index, (process, _)) in processes.enumerated() {
                process.waitUntilExit()
                guard process.terminationStatus != 0 else { continue }
                failures.append(
                    "run \(run): exit \(process.terminationStatus) \(outputs[index].prefix(200))")
            }
        }
        #expect(failures.isEmpty, "\(failures.count)/40 processes failed:\n\(failures.joined(separator: "\n"))")
    }

    /// **Waiting is the whole mechanism, and it used to stop waiting.**
    ///
    /// The wait broke after ``MeetingsDatabase/busyTimeout`` and then ran the open anyway, which
    /// puts back exactly the race above: GRDB reads the applied identifiers *once*, outside the
    /// per-migration transactions, so a process that gives up plans its migrations from a read the
    /// winner has since invalidated and dies on `UNIQUE constraint failed:
    /// grdb_migrations.identifier`. Five seconds was never the right length either — the critical
    /// section now contains a `VACUUM INTO` of the whole store.
    ///
    /// The lock is held from this process, which is fair: the kernel does not care who holds it, and
    /// what is being asserted is that the other side waits instead of proceeding.
    @Test func aSecondProcessWaitsForTheLockRatherThanGivingUpAndRacing() throws {
        try #require(FileManager.default.fileExists(atPath: Self.cli.path))
        let home = try TestStore.makeDirectory()
        defer { TestStore.remove(home) }

        let descriptor = Darwin.open(home.appendingPathComponent("store.db.lock").path,
                                     O_CREAT | O_RDWR, 0o644)
        try #require(descriptor >= 0)
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        let (process, pipe) = try launch(home: home)
        // Comfortably past the point the old wait gave up at.
        Thread.sleep(forTimeInterval: MeetingsDatabase.busyTimeout + 1.5)
        #expect(process.isRunning, "it gave up on the lock and opened the store alongside the holder")

        flock(descriptor, LOCK_UN)
        close(descriptor)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "and it opened cleanly once the lock was free:\n\(output)")
    }

    private func launch(home: URL) throws -> (Process, Pipe) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = Self.cli
        process.arguments = ["status"]
        process.environment = ["MEETINGS_HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return (process, pipe)
    }
}
