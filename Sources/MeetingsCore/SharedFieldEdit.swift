import Foundation

/// Two writers, one field.
///
/// Pre-notes and the summary are both columns the CLI writes and the app edits at the same time, and
/// The rule, settled once: **untouched field reloads silently, touched field is never
/// clobbered** and the user picks keep mine / take theirs / keep both.
///
/// The rule lives here rather than in the editor that renders it for the same reason
/// ``SearchSelection`` does: `MeetingsApp` is an executable target with no test target behind it, and
/// "the agent's write must not eat what the user was typing" is the part of that editor which is
/// logic rather than layout. Both fields drive the same functions, so the two editors cannot answer
/// the question differently.
public enum SharedFieldEdit {
    /// What to do with a value that arrived from the store while the editor was open.
    public enum Outcome: Sendable, Equatable {
        /// Our own write coming back around. The store echoes every commit to every process,
        /// including the one that made it.
        case echo
        /// Nothing of the user's is at risk, so nothing interrupts them.
        case reload
        /// Somebody else wrote while the user was typing. Neither side may be thrown away.
        case conflict
    }

    /// - Parameters:
    ///   - incoming: the value the store now holds.
    ///   - baseline: the last value the editor and the store agreed on.
    ///   - text: what is in the editor right now.
    ///   - touched: whether the user has typed since the last save landed.
    public static func receive(
        incoming: String, baseline: String, text: String, touched: Bool
    ) -> Outcome {
        if incoming == baseline { return .echo }
        // Blank and absent are the same state, so a field the user emptied and a field the store
        // wrote back as nothing are not two different values. Without this, clearing the summary
        // reads its own save back as somebody else's edit and puts a conflict banner over it.
        if isBlank(incoming), isBlank(baseline) { return .echo }
        // `text == baseline` as well as `!touched`, because a save that has been scheduled but not
        // yet committed leaves the flag down while the field already differs — reloading over that
        // is exactly the clobber this is here to prevent.
        return !touched && text == baseline ? .reload : .conflict
    }

    /// Keep both, in the order they were written: mine first, then whatever of theirs is not
    /// already in mine. Line-wise rather than character-wise because these are notes, and a
    /// three-way character merge of two people's prose is a worse answer than an honest append.
    public static func merge(mine: String, theirs: String) -> String {
        let existing = Set(mine.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        let additions = theirs
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !existing.contains($0) }
        guard !additions.isEmpty else { return mine }
        let separator = mine.isEmpty || mine.hasSuffix("\n") ? "" : "\n"
        return mine + separator + additions.joined(separator: "\n")
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
