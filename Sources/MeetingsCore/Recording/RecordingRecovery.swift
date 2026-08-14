import Foundation
import GRDB

/// The promise: "A crash mid-meeting loses seconds and the meeting is recoverable from the WAVs via the
/// batch pass." ``WAVRepair`` gets the audio back; this is what gets the *meeting* back.
///
/// Without it a killed recorder strands its row at `recording` forever. Nothing moves it: the batch
/// queue looks for `transcribing`, the Stop button throws `notRecording` because the session that
/// owned it died with the process, and the app renders a phantom live recording — red dot, climbing
/// clock, level meters — minutes after there is anything to record. The audio is on disk the whole
/// time.
///
/// The sweep is safe to run while a recording is genuinely in progress, which matters because "the
/// app crashed" and "a second copy of the app is up" look identical in the database. Two things
/// separate them:
///
/// 1. **The caller says what it owns.** A process holding a live session passes those ids in.
/// 2. **A live recorder keeps touching its WAV.** Both writers append every few milliseconds, so a
///    file modified within the grace window belongs to a recorder that is still alive — in this
///    process or another one — and is left strictly alone.
///
/// Neither is a lock, and the second is a heuristic. It is the right kind of heuristic: erring
/// towards "leave it" costs one grace window before the meeting is recovered — the sweep comes back
/// for it, see ``sweepOnLaunch`` — and erring the other way would move a live meeting to
/// `transcribing` underneath the process recording it.
public enum RecordingRecovery {
    /// What the sweep did to one stranded meeting.
    public struct Outcome: Sendable, Equatable {
        public enum Disposition: String, Sendable {
            /// Audio was found; the meeting is at `transcribing` and the batch queue owns it now.
            case recovered
            /// The WAVs are empty or absent. The meeting is at `ready` with the reason recorded.
            case nothingCaptured
            /// Someone is still writing to this meeting's audio. Left exactly as it was.
            case stillLive
        }

        public let meetingID: String
        public let disposition: Disposition
        /// Length of the longest recovered channel. Zero for the other two dispositions.
        public let durationMs: Int
    }

    /// How recently a WAV must have been written for the sweep to treat its recorder as alive.
    ///
    /// A writer appends on every capture buffer, so a live track's mtime is never more than a few
    /// milliseconds stale — the window only has to clear filesystem timestamp granularity and a
    /// stalled render thread. Fifteen seconds is generous for both. The ceiling: a crash is not
    /// recovered until fifteen seconds after it happened — which is why ``sweepOnLaunch`` does not
    /// sweep only once.
    public static let liveGraceSeconds: TimeInterval = 15

    /// Move every stranded `recording` row somewhere true.
    ///
    /// - Parameters:
    ///   - owning: meetings this process is genuinely recording right now. At launch, none.
    ///   - audioRoot: injected for the same reason ``Retention`` injects it — `Paths` reads process
    ///     environment a test must not mutate.
    ///   - now: the clock, for the liveness window.
    ///   - grace: the liveness window itself. A seam: the default is the only value the app uses,
    ///     and a test cannot spend fifteen real seconds proving the re-sweep.
    @discardableResult
    public static func sweep(
        store: MeetingStore,
        owning owned: Set<String> = [],
        audioRoot: URL = Paths.audioRoot,
        now: Date = Date(),
        grace: TimeInterval = liveGraceSeconds
    ) throws -> [Outcome] {
        var outcomes: [Outcome] = []
        for meeting in try store.meetings(state: .recording) where !owned.contains(meeting.id) {
            let directory = audioDirectory(for: meeting, audioRoot: audioRoot)
            if isBeingWrittenTo(directory, now: now, grace: grace) {
                outcomes.append(Outcome(meetingID: meeting.id, disposition: .stillLive, durationMs: 0))
                continue
            }
            if let outcome = try recover(meeting, directory: directory, store: store) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// The launch entry point. Never throws: a store that will not open is a problem the window is
    /// about to report anyway, and a failed sweep must not be what stops the app starting.
    ///
    /// Call it **after** ``WAVRepair/repairTree(at:)`` and **before**
    /// `TranscriptionService.resumePendingOnLaunch()` — it is what puts the recovered meetings into
    /// the state that queue looks for.
    ///
    /// **It sweeps more than once, and that is the point.** Reopening the app straight after it
    /// crashed is the ordinary case, not the exotic one, and inside ``liveGraceSeconds`` the dead
    /// recorder's WAV is still young enough to look alive. A single sweep at launch therefore
    /// classifies the crash as `stillLive` and never revisits it: the phantom `recording` row — red
    /// dot, climbing clock — survives the entire session, which is the exact symptom this whole file
    /// exists to remove. So whenever something looked live, the sweep runs again a grace window
    /// later, and keeps doing that until nothing does.
    ///
    /// **Why a re-read and not a lock.** A real liveness signal would answer "is that process still
    /// there" with no window at all — an `flock` the recorder holds for the length of the meeting,
    /// released by the kernel on `kill -9`, or a pid file the sweep can `kill(pid, 0)`. Both are
    /// strictly more precise, and both need the *recorder* to publish a second artefact on disk and
    /// keep it in step with the WAVs for every meeting, to be consulted only in the seconds after a
    /// crash. The recorder already publishes a liveness signal for free — a file that grows every
    /// few milliseconds — and the only thing wrong with it was that it was read once. Reading it
    /// again on the window's own cadence costs one directory listing per fifteen seconds, keeps the
    /// audio as the single source of truth, and cannot go stale the way a pid file can when the pid
    /// is reused. The trade: recovery lands one grace window after the crash rather than instantly.
    @discardableResult
    public static func sweepOnLaunch(
        store: MeetingStore,
        audioRoot: URL = Paths.audioRoot,
        now: Date = Date(),
        grace: TimeInterval = liveGraceSeconds
    ) -> [Outcome] {
        let outcomes = sweepReportingFailure(store: store, audioRoot: audioRoot, now: now, grace: grace)
        if outcomes.contains(where: { $0.disposition == .stillLive }) {
            Task.detached { await resweepWhileAnythingLooksLive(
                store: store, audioRoot: audioRoot, grace: grace) }
        }
        return outcomes
    }

    /// The re-sweep loop, ending as soon as one pass finds nothing live — either because the grace
    /// window expired on a dead recorder and it was recovered, or because whoever was recording
    /// finished and moved the row out of `recording` themselves.
    ///
    /// A genuinely live recording in another process keeps this polling for the length of that
    /// meeting, at one `contentsOfDirectory` per window. That is the correct cost: it is also the
    /// only way to notice the moment that process dies. Nothing here can steal a live meeting — each
    /// pass applies the same mtime rule as launch, and the claim is still the conditional UPDATE.
    /// That covers a recording *this* process starts while the loop is running too: it owns nothing
    /// by name (the launch sweep's `owning` is empty by construction), but the new meeting's writers
    /// are appending every few milliseconds, which is the same evidence any other live recorder
    /// leaves.
    ///
    /// Internal rather than private so a test can await the loop instead of racing it.
    static func resweepWhileAnythingLooksLive(
        store: MeetingStore,
        audioRoot: URL,
        grace: TimeInterval
    ) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(grace))
            if Task.isCancelled { return }
            // The store can go away underneath a loop that sleeps: a throwaway store is deleted the
            // moment its test ends, and a real one can be moved or restored from a backup while the
            // app runs. Either way there is nothing left to recover, and hammering a deleted file
            // just logs a disk I/O error once a grace window forever.
            guard FileManager.default.fileExists(atPath: store.dbPool.path) else { return }
            let outcomes = sweepReportingFailure(
                store: store, audioRoot: audioRoot, now: Date(), grace: grace)
            guard outcomes.contains(where: { $0.disposition == .stillLive }) else { return }
        }
    }

    private static func sweepReportingFailure(
        store: MeetingStore,
        audioRoot: URL,
        now: Date,
        grace: TimeInterval
    ) -> [Outcome] {
        do {
            let outcomes = try sweep(store: store, audioRoot: audioRoot, now: now, grace: grace)
            let acted = outcomes.filter { $0.disposition != .stillLive }
            if !acted.isEmpty {
                FileHandle.standardError.write(Data(
                    "Meetings: recovered \(acted.count) interrupted recording(s)\n".utf8))
            }
            return outcomes
        } catch {
            FileHandle.standardError.write(Data("Meetings: recording recovery failed: \(error)\n".utf8))
            return []
        }
    }

    // MARK: -

    /// Repair first, then read, then decide — in that order, because an unfinalised WAV reads as
    /// zero frames and deciding on that would send a fully recoverable meeting down the
    /// nothing-captured path.
    private static func recover(
        _ meeting: Meeting,
        directory: URL,
        store: MeetingStore
    ) throws -> Outcome? {
        var audits: [(channel: Channel, audit: ChannelAudit)] = []
        for channel in Channel.allCases {
            let url = directory.appendingPathComponent("\(channel.rawValue).wav")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? WAVRepair.repair(at: url)
            if let audit = ChannelAudit.read(url) { audits.append((channel, audit)) }
        }

        // A directory nobody can read is not an empty one. A folder that exists but will not list —
        // wrong ownership after a restore, a damaged disk — reads exactly like a meeting that
        // captured nothing, and closing it at `ready` with "there is nothing on it to transcribe"
        // would be a lie about audio that is sitting right there, told once and never revisited.
        // So it goes to the batch queue instead: the reason is recorded either way, and a meeting
        // whose permissions are put back transcribes on the next launch with nothing to redo.
        let unreadable = FileManager.default.fileExists(atPath: directory.path)
            && (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == nil

        // The end of the meeting comes from the audio, never from the clock. The clock says the app
        // relaunched — which may be Monday morning after a Friday crash — and stamping that on
        // `ended_at` would put a three-day meeting in the list and hand the retention sweep the
        // wrong age.
        let durationMs = audits.map(\.audit.durationMs).max() ?? 0
        let captured = unreadable || audits.contains { !$0.audit.isEmpty }

        let state: MeetingState = captured ? .transcribing : .ready
        let endedAt = meeting.startedAt.map { $0.addingTimeInterval(Double(durationMs) / 1000) }
        guard try claim(meeting.id, state: state, endedAt: endedAt, directory: directory, store: store)
        else { return nil }

        // Recorded after the claim, so a meeting this sweep did not win does not get another
        // process's verdict written onto it.
        for channel in Channel.allCases {
            // A folder nobody could open is filed as a *transcription* failure, not a capture one,
            // and the distinction is load-bearing in both directions: nothing here knows whether
            // the audio was captured, and a batch pass that finally reads the folder clears its own
            // kind — so putting the permissions back makes the warning go away by itself.
            if unreadable {
                try store.recordTranscriptIssue(TranscriptIssue(
                    meetingID: meeting.id, channel: channel, kind: .transcription,
                    reason: unreadableReason(directory: directory)))
                continue
            }
            guard let reason = captureFailure(channel: channel, in: audits, captured: captured)
            else { continue }
            try store.recordTranscriptIssue(TranscriptIssue(
                meetingID: meeting.id, channel: channel, kind: .capture, reason: reason))
        }

        return Outcome(
            meetingID: meeting.id,
            disposition: captured ? .recovered : .nothingCaptured,
            durationMs: captured ? durationMs : 0
        )
    }

    /// What to say when the meeting's own folder could not be read.
    private static func unreadableReason(directory: URL) -> String {
        "the folder holding this meeting's audio could not be opened, so nothing could be read "
            + "from it. The recording may still be at \(directory.path). Put the folder's "
            + "permissions back and Meetings transcribes it on the next launch."
    }

    /// What to say about one channel, or nil when there is nothing wrong with it.
    ///
    /// A meeting that captured nothing at all is reported per expected channel — that is the whole
    /// content of `ready` for a row with no transcript, and it must not arrive there silently. A
    /// meeting that did capture something only gets a note about a channel that came back as a dead
    /// device; an absent `system.wav` on a meeting recorded with no screen-recording permission is
    /// already reported by the recorder and is not this sweep's news to break.
    ///
    /// **Digital silence is a fault on the mic and nothing at all on the system track** — the same
    /// rule, and for the same reason, as the clean-stop path in
    /// ``RecordingController/auditCapturedAudio(meetingID:in:)``: an in-person meeting with nothing
    /// playing legitimately records a system track of bit-exact zeros, and a warning that fires on
    /// every one of those is a warning nobody reads by the time it is true. It is written twice
    /// because the two paths read the file at different moments, but a recording must not be
    /// described one way when it was stopped and another way when the app died holding it.
    private static func captureFailure(
        channel: Channel,
        in audits: [(channel: Channel, audit: ChannelAudit)],
        captured: Bool
    ) -> String? {
        guard let audit = audits.first(where: { $0.channel == channel })?.audit else {
            return captured ? nil : ChannelAudit.emptyReason(channel)
        }
        // The empty file stays on both channels: a WAV with no frames at all means the recording
        // ended before that track opened, which is news whichever track it is.
        if audit.isEmpty { return ChannelAudit.emptyReason(channel) }
        guard channel == .mic, audit.deliveredNoSignal else { return nil }
        return ChannelAudit.noSignalReason(channel)
    }

    /// One conditional update, exactly like ``Retention``'s claim and for the same reason: two
    /// sweeps racing — this app launching while another one recovers the same store — must move each
    /// meeting once. `changesCount` is the answer to "did *this* sweep own it", and the
    /// `state = 'recording'` predicate means a meeting that started recording again in the meantime
    /// is left alone.
    private static func claim(
        _ meetingID: String,
        state: MeetingState,
        endedAt: Date?,
        directory: URL,
        store: MeetingStore
    ) throws -> Bool {
        let claimed = try store.dbPool.write { db -> Bool in
            try db.execute(sql: """
                UPDATE meetings
                   SET state = ?,
                       ended_at = coalesce(?, ended_at),
                       audio_path = CASE WHEN audio_purged_at IS NULL
                                         THEN coalesce(audio_path, ?) ELSE audio_path END
                 WHERE id = ? AND state = ?
                """, arguments: [
                    state.rawValue,
                    // Every date column in this schema is INTEGER seconds, so this lands on the
                    // nearest second rather than truncating a 16.7 s meeting to 16.
                    endedAt.map { Int($0.timeIntervalSince1970.rounded()) },
                    directory.path,
                    meetingID,
                    MeetingState.recording.rawValue,
                ])
            return db.changesCount > 0
        }
        if claimed { StoreChange.post(storePath: store.dbPool.path, meetingID: meetingID) }
        return claimed
    }

    /// The recorder's own directory, unless the row points somewhere else inside the audio root.
    /// The path check is `Retention`'s, and it is here for a weaker reason — nothing is deleted —
    /// but a row saying `/etc` should still resolve to the meeting's own folder rather than be read.
    private static func audioDirectory(for meeting: Meeting, audioRoot: URL) -> URL {
        let fallback = audioRoot.appendingPathComponent(meeting.id, isDirectory: true)
        guard let path = meeting.audioPath else { return fallback }
        let root = audioRoot.standardizedFileURL.pathComponents
        let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard candidate.pathComponents.count > root.count,
              Array(candidate.pathComponents.prefix(root.count)) == root
        else { return fallback }
        return candidate
    }

    /// True when a WAV in the directory was written within the grace window — someone is still
    /// recording into this meeting.
    private static func isBeingWrittenTo(_ directory: URL, now: Date, grace: TimeInterval) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return files.contains { url in
            guard url.pathExtension.lowercased() == "wav",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate
            else { return false }
            return now.timeIntervalSince(modified) < grace
        }
    }
}
