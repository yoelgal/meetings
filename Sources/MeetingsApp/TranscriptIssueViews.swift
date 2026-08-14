import MeetingsCore
import SwiftUI

/// Saying, in the window, that a transcript is not the whole conversation.
///
/// The `transcript_issues` table exists because a half transcript is indistinguishable from a whole
/// one: one channel fails, the other produces a perfectly good half, and the meeting sits at `ready`
/// looking finished. `meetings show`, `meetings list` and `meetings transcript` have all said so
/// since wave 2. The app — the surface a person actually looks at — said nothing at all, which left
/// the failure the table was created to end fully alive in the place it does the most damage.
///
/// Three pieces, all reading the same rows: a banner over the meeting, a mark on the list row, and
/// the legend that says what the mark means.
///
/// **Nothing here switches over `TranscriptIssue.Kind`.** The set of kinds grows — `capture` and
/// `transcription` today, `vocabulary` landing alongside this — and a build that meets a kind it has
/// never heard of has to show it, not hide it or guess at it. So the wording of each line comes from
/// `TranscriptIssue.sentence`, which is MeetingsCore's own to keep current, and the only thing read
/// off `kind` here is membership of a named set, which an unknown kind simply is not in.
enum TranscriptIssueStyle {
    static let symbol = "exclamationmark.triangle.fill"

    /// System orange, so it tracks the user's appearance and accessibility settings in both
    /// schemes. Not red: nothing is broken and nothing is going to be lost — the meeting is intact,
    /// it is just missing a side.
    static let tint = Color.orange

    /// The kinds that mean a side of the conversation is gone. Used only to decide whether the
    /// banner may add the sentence about it — a kind this build does not know is not in the set, so
    /// it gets the honest silence instead of a claim that might not be true of it.
    static let losesAChannel: Set<TranscriptIssue.Kind> = [.capture, .transcription]

    static let legend = "One channel of that meeting is missing from its transcript."
}

/// The banner above a written-up meeting. One line per issue, in MeetingsCore's own words.
struct TranscriptIssueBanner: View {
    let issues: [TranscriptIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: TranscriptIssueStyle.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(TranscriptIssueStyle.tint)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    // `sentence` rather than anything assembled here: it is the same line `meetings
                    // show` prints, so the app and the CLI describe one failure one way.
                    Text(issue.sentence)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let consequence {
                    Text(consequence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            TranscriptIssueStyle.tint.opacity(0.12),
            in: .rect(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TranscriptIssueStyle.tint.opacity(0.35))
        )
        // One announcement rather than four, and it leads with the thing that matters.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(([title] + issues.map(\.sentence)).joined(separator: ". "))
    }

    private var title: String {
        issues.count == 1 ? "Transcript issue" : "Transcript issues"
    }

    /// Why a reader should care, said only where it is certainly true.
    private var consequence: String? {
        guard issues.contains(where: { TranscriptIssueStyle.losesAChannel.contains($0.kind) }) else {
            return nil
        }
        return "The summary and actions below are drawn from a conversation with a side missing."
    }
}

/// The list row's mark: the GUI's answer to the `*` that `meetings list` hangs off the state.
///
/// An asterisk needs a legend to mean anything, which is why the CLI prints one. A caution triangle
/// in the user's own accent-independent orange is legible on its own, carries a tooltip for the
/// pointer and a label for VoiceOver — and the list still prints the legend under it, because a
/// glyph with no key is the asterisk problem wearing a nicer hat.
struct TranscriptIssueMark: View {
    var body: some View {
        Image(systemName: TranscriptIssueStyle.symbol)
            .font(.caption)
            .foregroundStyle(TranscriptIssueStyle.tint)
            .help(TranscriptIssueStyle.legend)
            .accessibilityLabel("Transcript incomplete")
    }
}

/// The key to the mark, pinned under the list that uses it.
struct TranscriptIssueLegend: View {
    var body: some View {
        Label(TranscriptIssueStyle.legend, systemImage: TranscriptIssueStyle.symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
    }
}
