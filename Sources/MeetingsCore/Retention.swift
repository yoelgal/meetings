import Foundation
import GRDB

/// Audio retention: "audio deleted N days after the meeting. Default N = 30, configurable
/// in settings, `0` = keep forever. A purge sweep runs on app launch. `audio_purged_at` is set so
/// the UI can say 'audio deleted' rather than showing a broken play button."
///
/// The whole feature is a deletion, so every rule here is about not deleting the wrong thing:
///
/// - **Never a meeting that is still `recording` or `transcribing`.** One is having audio written
///   into it right now; the other is having it read. Both would lose the meeting outright.
/// - **Never a path outside the audio root.** `audio_path` is a string in a database two processes
///   and an importer can write to, and this code calls `removeItem`. A row saying `/Users/yoelgal`
///   must delete nothing at all.
/// - **Never a meeting with no date.** An imported row with neither `ended_at`, `started_at` nor
///   `scheduled_start` has no age, and a meeting of unknown age is not old.
///
/// Safe to run concurrently with anything, including a second copy of itself: the file removal is
/// idempotent, and the row update is one short transaction that re-checks the state it depends on.
public struct Retention: Sendable {
    /// One meeting's audio, gone.
    public struct Purged: Sendable, Hashable {
        public let meetingID: String
        public let directory: String
        /// Bytes reclaimed. Zero when the row pointed at a directory that was already gone, which
        /// is a legitimate outcome — the sweep still nulls the path so the UI stops offering to
        /// play it.
        public let bytes: Int
    }

    let store: MeetingStore
    /// Everything this type is allowed to delete lives under here. Injected for the same reason
    /// `TranscriptionService` injects it: `Paths` reads the process environment, and a test must not
    /// mutate that out from under the rest of the suite.
    let audioRoot: URL

    public init(store: MeetingStore, audioRoot: URL = Paths.audioRoot) {
        self.store = store
        self.audioRoot = audioRoot
    }

    /// Deletes the audio of every meeting older than the retention window.
    ///
    /// - Parameters:
    ///   - now: the clock. Injected so a test can stand thirty-one days away from a file it wrote a
    ///     millisecond ago, without waiting and without touching the system clock.
    ///   - retentionDays: overrides the stored setting. Nil reads `audio.retentionDays`, whose
    ///     documented default is 30. Zero or negative means keep forever, and returns immediately.
    @discardableResult
    public func sweep(now: Date = Date(), retentionDays: Int? = nil) throws -> [Purged] {
        let days = try retentionDays ?? store.settingInt(.audioRetentionDays) ?? 30
        guard days > 0 else { return [] }
        return try sweep(olderThan: now.addingTimeInterval(-Double(days) * 86_400), now: now)
    }

    /// The cutoff form. A meeting whose audio predates `cutoff` is purged.
    @discardableResult
    public func sweep(olderThan cutoff: Date, now: Date = Date()) throws -> [Purged] {
        var purged: [Purged] = []
        for meeting in try due(cutoff: cutoff) {
            if let record = try purge(meeting, now: now) { purged.append(record) }
        }
        return purged
    }

    /// Never throws and never returns anything, because the one caller is app launch and a store
    /// that will not open is a problem the window is about to report anyway. Old audio surviving one
    /// more day is not worth a launch failure ("a purge sweep runs on app launch").
    public static func sweepOnLaunch(store: MeetingStore, now: Date = Date()) {
        do {
            let purged = try Retention(store: store).sweep(now: now)
            if !purged.isEmpty {
                let bytes = purged.reduce(0) { $0 + $1.bytes }
                FileHandle.standardError.write(Data(
                    "Meetings: purged audio for \(purged.count) meeting(s), \(bytes) bytes\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("Meetings: audio retention sweep failed: \(error)\n".utf8))
        }
    }

    // MARK: -

    /// The candidates, chosen in SQL so a store with ten thousand meetings does not decode them all.
    ///
    /// `coalesce(ended_at, started_at, scheduled_start)` is the meeting's date — when it finished,
    /// else when it began, else when it was meant to. A row with none of the three is skipped by the
    /// `IS NOT NULL`, deliberately.
    func due(cutoff: Date) throws -> [Meeting] {
        try store.dbPool.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT * FROM meetings
                WHERE audio_path IS NOT NULL
                  AND audio_purged_at IS NULL
                  AND state NOT IN ('recording', 'transcribing')
                  AND coalesce(ended_at, started_at, scheduled_start) IS NOT NULL
                  AND coalesce(ended_at, started_at, scheduled_start) < ?
                ORDER BY coalesce(ended_at, started_at, scheduled_start) ASC
                """, arguments: [cutoff.timeIntervalSince1970])
        }
    }

    private func purge(_ meeting: Meeting, now: Date) throws -> Purged? {
        guard let path = meeting.audioPath, let directory = safeAudioDirectory(path) else { return nil }
        let bytes = Self.size(of: directory)

        // The row is claimed *before* the files go, and the claim is what decides whether this
        // sweep owns the deletion. The other order — delete, then update — loses a meeting in the
        // window where a second process starts recording into it again between the two steps: the
        // files would be gone and the claim would then correctly refuse, having already done the
        // damage. This way the worst case is a directory nobody points at any more, which wastes
        // disk and loses nothing.
        guard try claim(meeting.id, now: now) else { return nil }

        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            // Already gone — an earlier sweep that died mid-way, or a user with a Finder window.
            // The row is still worth clearing so the UI stops offering a play button.
        }
        return Purged(meetingID: meeting.id, directory: directory.path, bytes: bytes)
    }

    /// One atomic conditional update: nulls the path and stamps the purge, but only for a row that
    /// still has a path and is still in a state that may be purged. `changesCount` is therefore the
    /// answer to "did *this* sweep purge it", which is what makes two sweeps racing — the app
    /// launching while the CLI runs one — purge each meeting exactly once rather than twice.
    ///
    /// `Int(...)` because every date column in this schema is INTEGER seconds; writing the Double
    /// straight through would leave one REAL value in a column of integers.
    private func claim(_ meetingID: String, now: Date) throws -> Bool {
        let claimed = try store.dbPool.write { db -> Bool in
            try db.execute(sql: """
                UPDATE meetings SET audio_path = NULL, audio_purged_at = ?
                WHERE id = ? AND audio_path IS NOT NULL
                  AND state NOT IN ('recording', 'transcribing')
                """, arguments: [Int(now.timeIntervalSince1970), meetingID])
            return db.changesCount > 0
        }
        if claimed { StoreChange.post(storePath: store.dbPool.path, meetingID: meetingID) }
        return claimed
    }

    /// Nil unless the path is a directory strictly inside the audio root. The store is not a trust
    /// boundary this code gets to skip: `audio_path` is written by the recorder, by the batch pass
    /// and by whatever imported the meeting, and this function is the one that calls `removeItem`.
    func safeAudioDirectory(_ path: String) -> URL? {
        Self.safeAudioDirectory(path, audioRoot: audioRoot)
    }

    /// The same rule, reachable without a sweep. ``MeetingStore/deleteMeeting(id:audioRoot:)`` calls
    /// `removeItem` on an `audio_path` too, and a second copy of this check is a second place for the
    /// two to drift apart — which here means one of them one day deleting a directory outside the
    /// audio root.
    static func safeAudioDirectory(_ path: String, audioRoot: URL) -> URL? {
        let root = audioRoot.standardizedFileURL
        let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents,
              !candidateComponents.contains("..")
        else { return nil }
        return candidate
    }

    private static func size(of directory: URL) -> Int {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
