import AVFoundation
import Foundation
import Testing

@testable import MeetingsCore

/// The crash-recovery sweep under conditions a healthy store never shows: a backlog of stranded
/// meetings, an audio directory nobody can read, and two sweeps running at the same instant.
@Suite final class RobustRecoveryTests {
    let directory: URL
    let audioRoot: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        store = try TestStore.open(directory)
    }

    deinit {
        // Anything chmod-ed shut has to be opened again or the temp tree cannot be removed.
        if let walker = FileManager.default.enumerator(atPath: audioRoot.path) {
            for case let path as String in walker {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: audioRoot.appendingPathComponent(path).path)
            }
        }
        TestStore.remove(directory)
    }

    @discardableResult
    private func stranded(_ id: String, seconds: Double = 1) throws -> URL {
        _ = try store.createMeeting(Meeting(
            id: id, title: id, state: .recording, startedAt: Date() - 300))
        let folder = audioRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if seconds > 0 {
            try AudioFixture.write(
                to: folder.appendingPathComponent("mic.wav"), seconds: seconds, frequency: 440,
                sampleRate: 16_000, channels: 1)
        }
        return folder
    }

    @Test("a backlog of forty stranded meetings is recovered in one sweep")
    func recoversABacklog() throws {
        for i in 0..<40 { try stranded("m\(i)") }
        let outcomes = try RecordingRecovery.sweep(store: store, audioRoot: audioRoot, now: .now + 60)
        #expect(outcomes.count == 40)
        #expect(outcomes.allSatisfy { $0.disposition == .recovered })
        #expect(try store.meetings(state: .recording).isEmpty)
        #expect(try store.meetings(state: .transcribing).count == 40)
    }

    @Test("one unreadable meeting does not stop the sweep recovering the rest")
    func unreadableDirectoryDoesNotStopTheSweep() throws {
        let locked = try stranded("locked")
        try stranded("healthy")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

        let outcomes = try RecordingRecovery.sweep(store: store, audioRoot: audioRoot, now: .now + 60)
        #expect(outcomes.count == 2)
        #expect(try store.meeting(id: "healthy")?.state == .transcribing)

        // The locked one must not be declared empty: the audio is sitting right there, nobody could
        // look at it, and `ready` with "there is nothing on it to transcribe" is a lie nothing ever
        // revisits. It goes to the batch queue with the real reason instead.
        let after = try #require(try store.meeting(id: "locked"))
        #expect(after.state == .transcribing, "an unreadable directory was declared 'nothing captured'")
        let issues = try store.transcriptIssues(meetingID: "locked")
        #expect(issues.count == 2)
        #expect(issues.allSatisfy { $0.reason.contains("could not be opened") })
        // Transcription, not capture: a pass that finally reads the folder clears its own kind, so
        // fixing the permissions takes the warning down with it.
        #expect(issues.allSatisfy { $0.kind == .transcription })
    }

    @Test("two sweeps at the same instant move each meeting exactly once")
    func concurrentSweeps() async throws {
        for i in 0..<20 { try stranded("m\(i)") }
        let store = self.store
        let audioRoot = self.audioRoot
        async let a = Task.detached {
            try RecordingRecovery.sweep(store: store, audioRoot: audioRoot, now: .now + 60)
        }.value
        async let b = Task.detached {
            try RecordingRecovery.sweep(store: store, audioRoot: audioRoot, now: .now + 60)
        }.value
        let recovered = try await (a + b).filter { $0.disposition == .recovered }
        #expect(recovered.count == 20, "each meeting recovered once, got \(recovered.count)")
        #expect(try store.meetings(state: .transcribing).count == 20)
    }
}
