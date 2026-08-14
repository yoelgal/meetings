import MeetingsCore
import SwiftUI

/// The two channel hues, in one place because channel colour *is* the speaker attribution in v1
/// and the transcript's whole premise is that it carries continuously down the page.
///
/// Wave 1 drew the system channel with `.tertiary`, which measured **1.67:1** against the pane in
/// light mode — invisible, so half the attribution simply was not there. Both channels now get a
/// real hue at equal weight.
///
/// Why two fixed system colours rather than `.tint` for the mic: the accent colour is a user
/// setting and can be yellow or graphite, at which point the mic rule either vanishes or stops
/// differing from the system one. Attribution is not a thing to leave to a preference. These are
/// still system semantic colours — they adapt to light and dark, and to increased contrast — not
/// hex.
///
/// Measured on this machine against `textBackgroundColor`, the pane these rules are drawn on:
///
/// | rule | light | dark |
/// |---|---|---|
/// | mic — `systemBlue` | 3.52:1 | 5.16:1 |
/// | system — `systemPink` | 3.65:1 | 4.73:1 |
/// | *what wave 1 drew for system — `.tertiary`* | *1.66:1* | *2.77:1* |
///
/// Both clear 3:1, the non-text contrast floor, in both schemes. The channel is also *named* at
/// each turn, so nobody has to rely on the colour alone.
enum ChannelStyle {
    static func color(_ channel: Channel) -> Color {
        switch channel {
        case .mic: Color(nsColor: .systemBlue)
        case .system: Color(nsColor: .systemPink)
        }
    }

    /// The rule down the left of a turn, and the level meter's fill.
    static func rule(_ channel: Channel) -> AnyShapeStyle { AnyShapeStyle(color(channel)) }

    static func symbol(_ channel: Channel) -> String {
        switch channel {
        case .mic: "mic.fill"
        case .system: "speaker.wave.2.fill"
        }
    }
}

/// The transcript's key, shown once. Wave 2 encoded the channel three times over — a coloured rule,
/// a coloured icon and a written label, on *every* segment, because two people alternating means
/// "label only on change" fires on every line. One encoding carries it (the rule), and this says
/// once what the two colours mean.
struct ChannelLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            ForEach([Channel.mic, Channel.system], id: \.self) { channel in
                HStack(spacing: 6) {
                    Capsule()
                        .fill(ChannelStyle.color(channel))
                        .frame(width: 3, height: 11)
                    Text(channel.label)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
