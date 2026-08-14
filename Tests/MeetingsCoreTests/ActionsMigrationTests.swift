import Foundation
import GRDB
import Testing

@testable import MeetingsCore

/// The v6 migration, which moves actions out of the `actions` column and into the write-up.
///
/// It runs once over somebody's real store and there is no second chance at it, so the two things
/// that matter are tested directly: **nothing is lost** — the old column is left exactly as it was
/// found, so a bad merge is recoverable — and **nothing is duplicated**, however many times the
/// migration is replayed.
@Suite final class ActionsMigrationTests {
    let directory: URL

    init() throws { directory = try TestStore.makeDirectory() }
    deinit { TestStore.remove(directory) }

    /// The pool is opened here rather than through ``MeetingsDatabase`` so the migration ladder can
    /// be stopped one rung short, rows written the way an older build wrote them, and the last rung
    /// then run over them — which is the only honest way to test a backfill.
    private func migrated(_ seed: (Database) throws -> Void) throws -> [Row] {
        let pool = try DatabasePool(path: directory.appendingPathComponent("store.db").path)
        // The real ladder, stopped one rung short of the one under test.
        try Schema.migrator.migrate(pool, upTo: "v5")
        try pool.write(seed)
        try pool.write { try Schema.actionsIntoTheWriteUp($0) }
        return try pool.read {
            try Row.fetchAll($0, sql: "SELECT id, state, summary, actions FROM meetings ORDER BY id")
        }
    }

    private func insert(
        _ db: Database, id: String, state: MeetingState, summary: String?, actions: [Action]?
    ) throws {
        let encoded = try actions.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.execute(
            sql: """
                INSERT INTO meetings (id, title, state, attendees, pre_notes, summary, actions, source)
                VALUES (?, ?, ?, '[]', '', ?, ?, 'recorded')
                """,
            arguments: [id, "Torch0 weekly", state.rawValue, summary, encoded]
        )
    }

    @Test func theColumnsActionsAreAppendedToTheWriteUp() throws {
        let rows = try migrated { db in
            try insert(db, id: "a", state: .complete, summary: "# Decisions\n\nShip on Friday.", actions: [
                Action(text: "Send the numbers", owner: "Sofia", due: "end of week"),
                Action(text: "Book the follow-up", done: true),
            ])
        }
        let row = try #require(rows.first)
        #expect(row["summary"] as String? == """
            # Decisions

            Ship on Friday.

            ## Actions

            - [ ] Send the numbers
            - [x] Book the follow-up
            """)
        #expect(row["state"] as String? == "complete", "a meeting that had a write-up keeps its state")
    }

    /// The safety net, and the reason the migration is allowed to drop `owner` and `due` on the way
    /// into the markdown: the row still holds exactly what the agent wrote.
    @Test func theOldColumnIsLeftExactlyAsItWasFound() throws {
        let rows = try migrated { db in
            try insert(db, id: "a", state: .complete, summary: "Ship on Friday.", actions: [
                Action(text: "Send the numbers", owner: "Sofia", due: "end of week"),
            ])
        }
        let raw = try #require(rows.first?["actions"] as String?)
        let recovered = try JSONDecoder().decode([Action].self, from: Data(raw.utf8))
        #expect(recovered == [Action(text: "Send the numbers", owner: "Sofia", due: "end of week")])
        #expect(recovered.first?.owner == "Sofia", "owner survives in the column it was written to")
    }

    /// The orphan repair reopens a store part-way up the ladder and `RobustStoreTests` re-runs the
    /// last migration, so replaying this one is not hypothetical.
    @Test func runningItTwiceDoesNotDuplicateTheList() throws {
        let pool = try DatabasePool(path: directory.appendingPathComponent("store.db").path)
        try Schema.migrator.migrate(pool, upTo: "v5")
        try pool.write { try insert($0, id: "a", state: .complete, summary: "Ship.", actions: [Action(text: "one")]) }
        try pool.write { try Schema.actionsIntoTheWriteUp($0) }
        let once = try pool.read { try String.fetchOne($0, sql: "SELECT summary FROM meetings") }
        try pool.write { try Schema.actionsIntoTheWriteUp($0) }
        let twice = try pool.read { try String.fetchOne($0, sql: "SELECT summary FROM meetings") }
        #expect(once == twice)
        #expect(MarkdownActions.parse(twice ?? "").count == 1)
    }

    /// A meeting whose actions land on an empty write-up gains one, and with it the state having a
    /// write-up implies — the rule ``Meeting/setSummary(_:)`` keeps everywhere else.
    @Test func aMeetingWithActionsAndNoWriteUpGetsBoth() throws {
        let rows = try migrated { db in
            try insert(db, id: "a", state: .ready, summary: nil, actions: [Action(text: "Send the numbers")])
        }
        let row = try #require(rows.first)
        #expect(row["summary"] as String? == "## Actions\n\n- [ ] Send the numbers")
        #expect(row["state"] as String? == "complete")
    }

    /// Nothing to move, nothing touched — where "nothing to move" means every action in the column
    /// is already in the write-up, matched on its text. A meeting is *not* skipped merely because
    /// its write-up happens to contain some other checkbox: that read of idempotency stranded real
    /// actions in a column nothing reads any more.
    @Test func meetingsWithNothingToMoveAreLeftAlone() throws {
        let rows = try migrated { db in
            try insert(db, id: "a", state: .ready, summary: nil, actions: nil)
            try insert(db, id: "b", state: .complete, summary: "Ship.", actions: [])
            try insert(db, id: "c", state: .complete, summary: "- [ ] one", actions: [Action(text: "one")])
        }
        #expect(rows[0]["summary"] as String? == nil)
        #expect(rows[0]["state"] as String? == "ready")
        #expect(rows[1]["summary"] as String? == "Ship.")
        #expect(rows[2]["summary"] as String? == "- [ ] one")
    }

    /// The regression that prompted the rule: a write-up carrying an unrelated checkbox still gets
    /// its column's actions, because they are not in the document under any name.
    @Test func anUnrelatedCheckboxDoesNotStrandTheColumnsActions() throws {
        let rows = try migrated { db in
            try insert(
                db, id: "a", state: .complete,
                summary: "# Notes\n\n- [ ] hello",
                actions: [Action(text: "Increase the padding"), Action(text: "Benchmark the model")]
            )
        }
        let summary = try #require(rows[0]["summary"] as String?)
        #expect(summary.contains("- [ ] hello"))
        #expect(summary.contains("- [ ] Increase the padding"))
        #expect(summary.contains("- [ ] Benchmark the model"))
    }
}
