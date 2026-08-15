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

    /// The shape 0.1.2's own shipped `SKILL.md` produced, which no fixture had: its summary template
    /// handed the agent `## What we decided / ## Actions / ## Open questions / ## Not covered` *and*
    /// told it to call `meetings actions set`, so a real store from that build has prose bullets under
    /// an `## Actions` heading and the same commitments sitting in the column. Appending the block
    /// unconditionally gave every one of those write-ups a second heading called Actions,
    /// permanently, in a pass with no second chance at it.
    @Test func actionsLandUnderTheActionsHeadingTheWriteUpAlreadyHas() throws {
        let rows = try migrated { db in
            try insert(db, id: "a", state: .complete, summary: """
                ## What we decided

                Ship on Friday.

                ## Actions

                - Sofia sends the numbers

                ## Open questions

                Does the column stay?
                """, actions: [Action(text: "Send the numbers", owner: "Sofia")])
        }
        #expect(rows[0]["summary"] as String? == """
            ## What we decided

            Ship on Friday.

            ## Actions

            - Sofia sends the numbers
            - [ ] Send the numbers

            ## Open questions

            Does the column stay?
            """)
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

    // MARK: - v7, which is v6 again

    /// A store as a build from before the fix left it: the real ladder to `v5`, rows written the way
    /// *that* build's `v6` left them, and `v6` stamped applied.
    ///
    /// The stamp is the whole of the bug being repaired. GRDB records the identifier and nothing else,
    /// so a store carrying `v6` never runs a `v6` body again however wrong the one that ran was.
    private func stampedAtV6(_ seed: (Database) throws -> Void) throws -> DatabasePool {
        let pool = try DatabasePool(path: directory.appendingPathComponent("store.db").path)
        try Schema.migrator.migrate(pool, upTo: "v5")
        try pool.write { db in
            try seed(db)
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v6')")
        }
        return pool
    }

    private func summary(of pool: DatabasePool) throws -> String {
        try #require(try pool.read { try String.fetchOne($0, sql: "SELECT summary FROM meetings") })
    }

    /// `v6` shipped three different rules under one identifier, and the first stranded real actions:
    /// it skipped any document that already carried a task item anywhere in it. Nothing reads the
    /// column afterwards — not the app, not `actions list`, not either export — so on a store migrated
    /// by that build every action of that meeting is simply gone from every surface while still
    /// sitting in the row. `v7` is the same pass under a new identifier, so it runs.
    @Test func v7RecoversTheActionsAV6ThatSkippedAnyCheckboxStranded() throws {
        let pool = try stampedAtV6 { db in
            // What that build left: the write-up untouched, the column still holding both actions.
            try insert(db, id: "a", state: .complete, summary: "# Notes\n\n- [ ] hello", actions: [
                Action(text: "Increase the padding"),
                Action(text: "Benchmark the model"),
            ])
        }
        #expect(try MarkdownActions.parse(summary(of: pool)).map(\.text) == ["hello"], "stranded before v7")

        try Schema.migrator.migrate(pool)

        #expect(try MarkdownActions.parse(summary(of: pool)).map(\.text)
            == ["hello", "Increase the padding", "Benchmark the model"])
    }

    /// The second `v6`: set membership, which collapsed two commitments that happened to read the same
    /// into one line. `v7` counts them, so the missing one arrives — under the heading the first pass
    /// already wrote, not a second one.
    @Test func v7RestoresTheCommitmentAV6MatchingOnSetMembershipCollapsed() throws {
        let pool = try stampedAtV6 { db in
            try insert(
                db, id: "a", state: .complete,
                summary: "# Standup\n\n## Actions\n\n- [ ] follow up",
                actions: [
                    Action(text: "follow up", owner: "Sofia"),
                    Action(text: "follow up", owner: "Will", done: true),
                ]
            )
        }
        #expect(try MarkdownActions.parse(summary(of: pool)).count == 1, "one line for two commitments")

        try Schema.migrator.migrate(pool)

        #expect(try summary(of: pool) == "# Standup\n\n## Actions\n\n- [ ] follow up\n- [x] follow up")
    }

    /// And on a store the good `v6` handled, `v7` changes nothing — byte for byte, including the
    /// author's own whitespace. That is what makes re-running it safe rather than a second edit of
    /// somebody's prose: `appending` is idempotent per action, matched by count.
    @Test func v7IsAByteForByteNoOpWhereV6WentWell() throws {
        let written = """
            # Decisions

            Ship on Friday.\u{20}\u{20}
            No, Monday.

            ## Actions

            - [ ] Send the numbers
            - [x] Book the follow-up

            """
        let pool = try stampedAtV6 { db in
            try insert(db, id: "a", state: .complete, summary: written, actions: [
                Action(text: "Send the numbers", owner: "Sofia", due: "end of week"),
                Action(text: "Book the follow-up", done: true),
            ])
        }
        try Schema.migrator.migrate(pool)
        #expect(try summary(of: pool) == written)
    }

    /// The ladder's last rung is the actions pass, and it has to stay reachable by a *new* name: a
    /// fourth reading of what this pass should do cannot be shipped by editing `v7` again.
    @Test func theActionsPassIsRegisteredUnderItsOwnIdentifierAfterV6() {
        #expect(Schema.migrator.migrations.contains("v7"))
        #expect(Schema.migrator.migrations.last == "v7")
    }
}
