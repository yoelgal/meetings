import Foundation

/// **The only prompt in this product, and it lives alone in this file on purpose.**
///
/// The app "deliberately contains no prompts". The cloud mode, though, "runs a built-in prompt
/// automatically on `ready`". Both were settled, and
/// they cannot both be true of the same binary — so the tension is resolved by quarantine rather
/// than by picking a side: exactly one prompt exists, it is in one file named after what it is, it
/// is unreachable unless the user configures a cloud provider and switches to Mode C behind
/// "advanced", and no other mode ever reads it. Grepping for `CloudPrompt` finds every prompt in
/// the product. Reported as a spec tension rather than settled unilaterally.
public enum CloudPrompt {
    public static let system = """
        You write up meetings. You are given a transcript labelled by channel — "You" is the person \
        who recorded it, "Others" is everyone else on the call — together with the notes they wrote \
        before and during the meeting.

        Their notes are the steer, not decoration. Lead with what they flagged as important. If a \
        point in their pre-notes never came up in the meeting, say so explicitly under "Not \
        covered" rather than leaving them to notice the gap themselves.

        You may also be given an existing write-up. It is theirs, and they may have edited it by \
        hand. Revise and improve it rather than starting again: keep their wording and their \
        structure wherever it still holds, and change only what the transcript shows is wrong, \
        missing or out of date.

        Reply with GitHub-flavoured markdown and nothing else: no preamble, no closing offer to \
        help. Use "## Summary" for a short prose account of what was decided and why, then \
        "## Actions" as a markdown checklist, one line each, naming an owner where the transcript \
        names one. Omit a section rather than padding it.
        """

    /// The context the model is given: pre-notes, live notes with their offsets, and the transcript
    /// with channel labels and timestamps — the same four things an agent receives — plus
    /// the write-up already on the meeting, if there is one.
    ///
    /// That last one is read from the meeting's own field and nowhere else. The summary is now
    /// editable in the app, so re-running this on a meeting somebody hand-corrected used to hand the
    /// model no idea their edits existed, and it wrote a fresh summary straight over them.
    ///
    /// A summary that is absent and one that is only whitespace are the same state, and both are
    /// omitted. An empty section here would read to the model as "the user wrote nothing on
    /// purpose", which is a different and false instruction.
    public static func user(
        meeting: Meeting,
        notes: [Note],
        segments: [TranscriptSegment]
    ) -> String {
        var parts = ["# \(meeting.title)"]
        if !meeting.attendees.isEmpty {
            parts.append("Attendees: " + meeting.attendees
                .map { $0.name ?? $0.email ?? "unnamed" }
                .joined(separator: ", "))
        }
        let existing = (meeting.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            parts.append(
                "## The write-up already on this meeting\n"
                    + "This is the user's own, possibly hand-edited. Revise it rather than "
                    + "replacing it.\n\n\(existing)"
            )
        }
        if !meeting.preNotes.isEmpty {
            parts.append("## Pre-meeting notes\n\(meeting.preNotes)")
        }
        if !notes.isEmpty {
            parts.append("## Notes written during the meeting\n" + notes
                .map { "- [\(clock($0.tOffsetMs))] \($0.text)" }
                .joined(separator: "\n"))
        }
        if !segments.isEmpty {
            parts.append("## Transcript\n" + segments
                .map { "[\(clock($0.tStartMs))] \($0.channel == .mic ? "You" : "Others"): \($0.text)" }
                .joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func clock(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds) / 1000
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
