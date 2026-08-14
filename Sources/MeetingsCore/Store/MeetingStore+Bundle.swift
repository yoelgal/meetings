import Foundation
import GRDB

/// Bundle import, as one transaction. Extension rather than a change to `MeetingStore.swift` so the
/// single write surface keeps one owner.
extension MeetingStore {
    public struct BundleImportResult: Sendable {
        public var meeting: Meeting
        /// The id in the bundle was already taken here, so this row got a fresh one.
        public let idCollision: Bool
        /// Non-nil when the import had to create the folder the bundle named.
        public let folderCreated: String?
        public let segmentCount: Int
        public let noteCount: Int
        public let hasAudio: Bool
        /// True when nothing was written — the `--dry-run` path.
        public let planOnly: Bool
    }

    /// What an import *would* do, writing nothing. Backs `meetings import --dry-run`.
    ///
    /// Advisory only: the real decisions are taken again inside ``importBundle(_:bundleName:folderName:)``'s
    /// transaction, because a plan taken now and applied later is a race, and the store is shared by
    /// two processes.
    public func planBundleImport(
        _ contents: MeetingBundle.Contents,
        bundleName: String,
        folderName: String? = nil
    ) throws -> BundleImportResult {
        try dbPool.read { db in
            let plan = try Self.decide(db, contents: contents, bundleName: bundleName, folderName: folderName)
            return BundleImportResult(
                meeting: plan.meeting,
                idCollision: plan.idCollision,
                folderCreated: plan.folderToCreate?.name,
                segmentCount: contents.segments.count,
                noteCount: contents.notes.count,
                hasAudio: !contents.audio.isEmpty,
                planOnly: true
            )
        }
    }

    /// Lossless restore. One transaction: the meeting, its folder if the name is new, every segment,
    /// every note with its anchor remapped onto the ids the segments just got.
    ///
    /// Nothing existing is touched. The rule is explicit: a colliding id "generates a new id and
    /// records `imported_from` — never overwrites", and the partial unique index on
    /// `calendar_event_id` exempts imported rows for exactly this reason.
    @discardableResult
    public func importBundle(
        _ contents: MeetingBundle.Contents,
        bundleName: String,
        folderName: String? = nil
    ) throws -> BundleImportResult {
        let result = try dbPool.write { db -> BundleImportResult in
            let plan = try Self.decide(db, contents: contents, bundleName: bundleName, folderName: folderName)
            if let folder = plan.folderToCreate { try folder.insert(db) }

            let meeting = plan.meeting.sanitized()
            try meeting.insert(db)

            // Insert in file order and remember the id each position got: that mapping is the only
            // thing that keeps a note pointing at the sentence it was written against, because the
            // ids in the bundle mean nothing here.
            var idByIndex: [Int64] = []
            idByIndex.reserveCapacity(contents.segments.count)
            for segment in contents.segments {
                var row = TranscriptSegment(
                    meetingID: meeting.id,
                    channel: segment.channel,
                    tStartMs: segment.startMs,
                    tEndMs: segment.endMs,
                    text: segment.text,
                    pass: segment.pass,
                    edited: segment.edited
                ).sanitized()
                try row.insert(db)
                idByIndex.append(row.id ?? 0)
            }

            for note in contents.notes {
                var row = Note(
                    meetingID: meeting.id,
                    tOffsetMs: note.offsetMs,
                    anchorSegmentID: note.anchorSegmentIndex.flatMap { idByIndex.indices.contains($0) ? idByIndex[$0] : nil },
                    text: note.text
                ).sanitized()
                try row.insert(db)
            }

            // In the same transaction as the transcript they describe. A restore that landed the
            // segments and then failed before the issues would leave the receiving machine holding
            // a half transcript that claims to be whole — the exact failure the bundle now carries
            // these rows to prevent.
            for issue in contents.issues {
                try TranscriptIssue(
                    meetingID: meeting.id,
                    channel: issue.channel,
                    kind: issue.kind,
                    reason: issue.reason.withoutNULs,
                    at: issue.at
                ).insert(db)
            }

            return BundleImportResult(
                meeting: meeting,
                idCollision: plan.idCollision,
                folderCreated: plan.folderToCreate?.name,
                segmentCount: contents.segments.count,
                noteCount: contents.notes.count,
                hasAudio: !contents.audio.isEmpty,
                planOnly: false
            )
        }
        StoreChange.post(storePath: dbPool.path, meetingID: result.meeting.id)
        return result
    }

    /// The folder with that name, creating it if this store has never seen it. One transaction, so
    /// two `meetings create --folder Torch0` calls racing each other end up with one folder rather
    /// than a failed insert.
    public func folderNamedOrCreated(_ name: String) throws -> Folder {
        let folder = try dbPool.write { db -> Folder in
            if let existing = try Folder.fetchOne(
                db, sql: "SELECT * FROM folders WHERE name = ? COLLATE NOCASE", arguments: [name]) {
                return existing
            }
            let folder = Folder(name: name, sortOrder: try Int.fetchOne(db, sql: "SELECT count(*) FROM folders") ?? 0)
            try folder.insert(db)
            return folder
        }
        StoreChange.post(storePath: dbPool.path)
        return folder
    }

    // MARK: -

    private struct ImportPlan {
        let meeting: Meeting
        let idCollision: Bool
        let folderToCreate: Folder?
    }

    /// Every decision an import makes, in one place, so `--dry-run` reports exactly what the real
    /// run does rather than a second guess at it.
    private static func decide(
        _ db: Database,
        contents: MeetingBundle.Contents,
        bundleName: String,
        folderName: String?
    ) throws -> ImportPlan {
        let row = contents.meeting

        let idCollision = try Meeting.fetchOne(db, key: row.id) != nil
        // The meeting id becomes a directory name — `Paths.audioDirectory(meetingID:)` — so an id
        // out of a bundle is untrusted input to a file write, and it was taken at face value. A
        // bundle carrying `"id": "../../../../pwned"` in meeting.json put its audio outside the
        // audio root entirely, anywhere the user could write. A bundle is a file somebody sent you.
        //
        // Re-id rather than refuse: an unusable id is the same problem as an id already taken, the
        // store already has one answer for that, and the import still reports it.
        let unusableID = !Self.isUsableAsAFilename(row.id)
        // The other way this bundle can clash: a row this machine materialised from the same
        // calendar event. That index is unique for non-imported rows, so importing on top of it
        // would fail the insert outright — marking the incoming row as imported is what keeps the
        // restore working *and* keeps the local row authoritative for `cal:` writes.
        let eventTaken: Bool
        if let eventID = row.calendarEventId {
            eventTaken = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                  SELECT 1 FROM meetings WHERE calendar_event_id = ? AND imported_from IS NULL AND id IS NOT ?
                )
                """, arguments: [eventID, row.id]) ?? false
        } else {
            eventTaken = false
        }

        // A clean restore keeps the row exactly as it was — same id, same `source`, no
        // `imported_from` — because that is what "round-trips exactly" means for the machine-loss
        // case this format exists for. Provenance is recorded only when this store already holds
        // the thing being imported, which is the case this legislates for.
        let displaced = idCollision || eventTaken || unusableID
        let name = folderName ?? row.folder
        var folderToCreate: Folder?
        var folderID: String?
        if let name, !name.isEmpty {
            if let existing = try Folder.fetchOne(db, sql: "SELECT * FROM folders WHERE name = ? COLLATE NOCASE", arguments: [name]) {
                folderID = existing.id
            } else {
                let folder = Folder(name: name, sortOrder: try Int.fetchOne(db, sql: "SELECT count(*) FROM folders") ?? 0)
                folderToCreate = folder
                folderID = folder.id
            }
        }

        let meeting = Meeting(
            id: displaced ? UUID().uuidString : row.id,
            folderID: folderID,
            title: row.title,
            state: row.state,
            calendarEventID: row.calendarEventId,
            scheduledStart: row.scheduledStart,
            scheduledEnd: row.scheduledEnd,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            attendees: row.attendees,
            preNotes: contents.preNotes,
            summary: contents.summary,
            actions: contents.actions,
            audioPath: nil,
            audioPurgedAt: row.audioPurgedAt,
            source: displaced ? .imported : row.source,
            importedFrom: displaced ? bundleName : row.importedFrom
        )
        return ImportPlan(
            meeting: meeting,
            idCollision: idCollision || unusableID,
            folderToCreate: folderToCreate
        )
    }

    /// One path component, and one this store would have generated: a non-empty run of letters,
    /// digits, `-` and `_`. Every id the app makes is a UUID, so nothing legitimate is refused, and
    /// `.`, `/`, `\` and `:` — everything that can leave a directory or name a resource fork — are
    /// gone by construction rather than by blocklist.
    static func isUsableAsAFilename(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
