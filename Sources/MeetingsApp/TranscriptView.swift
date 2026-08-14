import MeetingsCore
import SwiftUI

/// The transcript. Channel attribution *is* the speaker attribution in v1, so the two
/// channels have to be told apart at a glance — and exactly once. A coloured rule down the left of
/// every line carries it continuously; `ChannelLegend`, shown once above the transcript, says what
/// the two colours mean. Wave 2 also drew a coloured icon and a written label at every turn, which
/// on an alternating two-party conversation meant a label on nearly every segment.
///
/// Both hues come from `ChannelStyle`, which is where the contrast is argued. Wave 1 drew the
/// system channel with `.tertiary` at 1.67:1 in light mode, which meant half the attribution was
/// simply not on screen.
struct TranscriptView: View {
    let segments: [TranscriptSegment]
    /// An imported file is one mixed track, so claiming a microphone / system split would
    /// be a lie. The rule stays — it is the reading gutter — but it goes neutral and unnamed.
    var singleChannel = false
    /// The segment a note was just clicked through to, drawn with a brief highlight so the eye
    /// lands on it rather than somewhere near it.
    var highlighted: Int64?

    private let gutterWidth: CGFloat = 46
    private let gutterGap: CGFloat = 10
    private let ruleGap: CGFloat = 10

    var body: some View {
        // Lazy, because a long meeting is a long transcript. A `VStack` builds and lays out every
        // row up front: a 10 000-segment meeting froze the window for over twenty seconds before
        // the first pixel of it appeared. `LazyVStack` builds the rows the scroll view can see, and
        // `ScrollViewProxy.scrollTo` still reaches a row that has not been built yet, which is what
        // clicking a note to jump to its anchor depends on.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                // A turn still reads as a turn — but through space, which costs no ink, rather
                // than through a third copy of the channel name.
                let isTurn = index > 0 && segments[index - 1].channel != segment.channel
                row(segment)
                    .padding(.top, isTurn && !singleChannel ? 10 : 0)
                    // Notes anchor to segment ids, and clicking one scrolls here.
                    .id(segment.id)
            }
        }
    }

    private func row(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: gutterGap) {
            // Monospaced digits so the gutter is a straight edge rather than a ragged one.
            Text(Format.clock(milliseconds: segment.tStartMs))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth, alignment: .trailing)
            Text(segment.text)
                .font(.callout)
                // Both channels read at full contrast. Dimming one of them was the other half of
                // wave 1's attribution problem: the quieter channel was also the harder one to read.
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.leading, ruleGap)
                .frame(maxWidth: .infinity, alignment: .leading)
                // An overlay takes the text's own height. A capsule in the stack would ask for
                // infinite height and drag the following rows up over each other.
                // 3 pt rather than 2: this rule is the *only* thing carrying speaker attribution
                // now that the per-turn labels are gone, so it gets enough width to be seen without
                // being looked for. Measured on the shipped build at 3 pt, against the pane:
                // microphone 3.52:1 light / 5.16:1 dark, system audio 3.65:1 / 4.73:1 — all four
                // over the 3:1 non-text floor.
                .overlay(alignment: .leading) {
                    Capsule().fill(rule(for: segment.channel)).frame(width: 3)
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            highlighted == segment.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 6, style: .continuous)
        )
        .animation(.default, value: highlighted)
    }

    private func rule(for channel: Channel) -> AnyShapeStyle {
        singleChannel ? AnyShapeStyle(.quaternary) : ChannelStyle.rule(channel)
    }
}
