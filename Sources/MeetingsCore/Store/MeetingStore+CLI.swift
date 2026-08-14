import Foundation
import GRDB

/// The reads the CLI's write path needs and the store did not already have. Extensions only — the
/// write surface itself stays in `MeetingStore.swift`.
extension MeetingStore {
    /// One segment by id, without knowing which meeting it belongs to.
    ///
    /// `meetings transcript edit` needs this before it writes: the segment id comes from the command
    /// line, and nothing else proves it belongs to the meeting the `<ref>` resolved to. Editing
    /// another meeting's segment through a ref that happens to be valid is the kind of write nobody
    /// would ever notice.
    public func transcriptSegment(id: Int64) throws -> TranscriptSegment? {
        try dbPool.read { try TranscriptSegment.fetchOne($0, key: id) }
    }

    /// Every scope a term exists in, global first.
    ///
    /// `meetings vocab disable <term>` takes a bare term, and the same word can legitimately be a
    /// global auto-seeded name *and* a folder-scoped correction. Returning all of them is what lets
    /// the command refuse to guess (exit 4) instead of disabling whichever one SQLite handed back.
    public func vocabularyTerms(term: String) throws -> [VocabularyTerm] {
        try dbPool.read { db in
            try VocabularyTerm.fetchAll(db, sql: """
                SELECT * FROM vocabulary
                WHERE term = ? COLLATE NOCASE
                ORDER BY (folder_id IS NULL) DESC, folder_id ASC
                """, arguments: [term])
        }
    }
}

extension SettingKey {
    /// Every key `meetings config` will write, in the order it prints them.
    ///
    /// `SettingKey` stays open — any string is representable — but the CLI is not: an unrecognised
    /// key is a typo far more often than it is a new feature, and a silent write leaves the setting
    /// you thought you changed at its default with nothing to show you why.
    public static let known: [SettingKey] = [
        .audioRetentionDays,
        .aiMode,
        .aiManualPasteCommand,
        .aiLocalAgentRunCommand,
        .aiCloudBaseURL,
        .aiCloudModel,
        .aiCloudKeyRef,
        .transcribeBatchEngine,
        .transcribeLocalModel,
        .transcribeRemoteBaseURL,
        .transcribeRemoteModel,
        .transcribeRemoteKeyRef,
        .calendarLookAheadDays,
        .exportMarkdownOnComplete,
        .exportMarkdownRoot,
        .onboardingCompleted,
        .updateCheckEnabled,
    ]

    /// A key whose value is a Keychain account name rather than a value in its own right. The secret
    /// never enters the settings table.
    public var isKeyReference: Bool { rawValue.hasSuffix(".keyRef") }
}
