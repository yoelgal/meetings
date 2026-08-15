import MeetingsCore
import SwiftUI

/// What a command draws to say which one it is: an SF Symbol, or the two characters that name it.
///
/// One view for both surfaces, so the slash menu and the toolbar cannot end up disagreeing about
/// what Heading 2 looks like.
///
/// **`link` is drawn a notch smaller.** The marks are a mix of two families: `bold`, `italic` and
/// `strikethrough` are drawn at text cap height (44 × 44 px at 13 pt), while `link` is an object
/// symbol that fills its box (66 × 65 px at the same size). Rendered at one scale the chain came out
/// half again as large as the letters beside it and read as a blob rather than a link — which is
/// what "the link is not rendering properly" looks like. `.small` puts it back on the row.
struct CommandGlyph: View {
    let label: MarkdownEditing.Label

    var body: some View {
        switch label {
        case .symbol(let name):
            Image(systemName: name)
                .imageScale(name == "link" ? .small : .medium)
        case .text(let text):
            // Semibold and a touch under body: at body weight "H1" reads as prose in a row of
            // glyphs, and it has to survive being set in the 18 pt slot the symbols get.
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .fixedSize()
        }
    }
}

/// The menu `/` opens over the write-up: the discoverable path to the same constructs the shorthand
/// already types. Grouped, because nine flat rows is a list you read rather than a menu you aim at.
///
/// Every command it offers is a ``MarkdownEditing/Action`` posted on the engine's own
/// `MarkdownEditorBus` — the menu is a way of choosing, not a second definition of what Heading 2
/// means.
struct SlashMenu: View {
    let matches: [MarkdownEditing.SlashCommand]
    let highlighted: Int
    let choose: (MarkdownEditing.SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                // The group label appears above the first command of each group, so filtering down
                // to two headings does not leave "Lists" standing over nothing.
                if index == 0 || matches[index - 1].group != command.group {
                    Text(command.group.uppercased())
                        .font(.caption2.weight(.semibold))
                        .kerning(0.8)
                        // `.secondary`, not `.tertiary`: over `.regularMaterial` in dark mode a
                        // tertiary caption2 is close to unreadable, and these labels are the only
                        // thing telling you the menu is grouped at all.
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.top, index == 0 ? 6 : 8)
                        .padding(.bottom, 3)
                }
                row(command, selected: index == highlighted)
            }
        }
        .padding(4)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    /// A heading row is set at the weight and size it inserts; everything else stays at body size.
    ///
    /// Deliberately capped well below the real heading scale — this is a menu row, not a preview
    /// pane, and a 26pt "Heading 1" would set the row height for the whole list.
    private func previewFont(for command: MarkdownEditing.SlashCommand) -> Font {
        switch command.id {
        case "h1": .system(size: 16, weight: .bold)
        case "h2": .system(size: 14.5, weight: .semibold)
        case "h3": .system(size: 13.5, weight: .semibold)
        default: .body
        }
    }

    private func row(_ command: MarkdownEditing.SlashCommand, selected: Bool) -> some View {
        // A Button rather than a tap gesture, so it is one thing to VoiceOver and to the pointer.
        Button {
            choose(command)
        } label: {
            HStack(spacing: 9) {
                CommandGlyph(label: command.label)
                    .frame(width: 18)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                // The heading rows are *also* set at the size they produce — the glyph now says
                // which level it is, and the row still shows what the level looks like.
                Text(command.title)
                    .font(previewFont(for: command))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer(minLength: 12)
                Text(command.shorthand)
                    .font(.caption.monospaced())
                    // Was `.tertiary`, which left the one thing worth learning — the shorthand that
                    // means you never need this menu again — as the least legible text in it.
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .background(
                selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .font(.callout)
    }
}

/// The bar that appears over a selection: the four inline marks, then the constructs a line can be
/// turned into.
///
/// It is a second way to reach what ⌘B and the slash menu already do, for the hand that is on the
/// mouse — so it posts exactly the same bus actions and defines nothing of its own.
///
/// **Bold and italic read pressed straight from the engine.** `NativeTextView` posts
/// `selectionBoldDidChange` / `selectionItalicDidChange` after every selection change, which is the
/// same answer ⌘B uses to decide which way it is going, so the button cannot say "on" while the
/// shortcut turns it on. The engine publishes no such signal for strikethrough, inline code or a
/// link, and those buttons are therefore unpressed — re-deriving them here would be a second
/// markdown parser disagreeing with the one holding the document.
struct SelectionToolbar: View {
    let isBold: Bool
    let isItalic: Bool
    let run: (MarkdownEditing.Action) -> Void

    private static let marks: [(MarkdownEditing.Action, MarkdownEditing.Label, String)] = [
        (.bold, .symbol("bold"), "Bold"),
        (.italic, .symbol("italic"), "Italic"),
        (.strikethrough, .symbol("strikethrough"), "Strikethrough"),
        (.inlineCode, .symbol("chevron.left.forwardslash.chevron.right"), "Code"),
        (.link, .symbol("link"), "Link"),
    ]

    private func pressed(_ action: MarkdownEditing.Action) -> Bool {
        switch action {
        case .bold: isBold
        case .italic: isItalic
        default: false
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.marks, id: \.0) { action, label, name in
                button(label, name, on: pressed(action)) { run(action) }
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            ForEach(MarkdownEditing.blockCommands) { command in
                button(command.label, command.title, on: false) { run(command.action) }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: .rect(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private func button(
        _ label: MarkdownEditing.Label, _ name: String, on: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            CommandGlyph(label: label)
                .frame(width: 24, height: 22)
                .background(
                    on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 5, style: .continuous)
                )
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }
}

/// ⌘B and its four siblings, published by whichever markdown editor holds focus and picked up by
/// the Format menu.
///
/// A key equivalent has to be a **menu item** to beat a focused `NSTextView` to the keystroke: the
/// main menu is consulted before the responder chain, and a `.onKeyPress` on a view whose text
/// engine already handles ⌘B never sees it. It also means the shortcuts are visible in the menu bar
/// instead of being folklore.
struct MarkdownFormatting: Equatable {
    /// Identity only, so SwiftUI can tell one editor's publication from another's. The closure is
    /// not equatable and does not need to be — it is always the current one.
    let id: Int
    let run: (MarkdownEditing.Action) -> Void

    static func == (lhs: MarkdownFormatting, rhs: MarkdownFormatting) -> Bool { lhs.id == rhs.id }
}

extension FocusedValues {
    @Entry var markdownFormatting: MarkdownFormatting?
}

/// The Format menu. Present always, enabled only while a markdown editor has focus — a greyed-out
/// item says the shortcut exists and where it applies, which a missing menu does not.
struct MarkdownFormattingCommands: Commands {
    @FocusedValue(\.markdownFormatting) private var formatting

    var body: some Commands {
        CommandMenu("Format") {
            item("Bold", .bold, "b", [.command])
            item("Italic", .italic, "i", [.command])
            // Notion's binding. ⌘⇧S reads as Save As in document apps; this one has no such
            // command, and nothing else in the app claims it.
            item("Strikethrough", .strikethrough, "s", [.command, .shift])
            item("Code", .inlineCode, "e", [.command])
            // Not ⌘K: that is Search, and it opens from anywhere including the floating notes
            // panel, so the editor does not get to take it away.
            item("Link", .link, "k", [.command, .shift])
        }
    }

    private func item(
        _ title: String, _ action: MarkdownEditing.Action,
        _ key: KeyEquivalent, _ modifiers: EventModifiers
    ) -> some View {
        Button(title) { formatting?.run(action) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(formatting == nil)
    }
}
