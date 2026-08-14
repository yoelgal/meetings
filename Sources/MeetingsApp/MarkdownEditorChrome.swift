import MeetingsCore
import SwiftUI

/// The menu `/` opens over the write-up: the discoverable path to the same constructs the shorthand
/// already types. Grouped, because nine flat rows is a list you read rather than a menu you aim at.
///
/// Every command it offers goes through ``MarkdownEditing/applyBlock(_:in:over:)``, the same
/// transform any other formatting surface would use — the menu is a way of choosing, not a second
/// definition of what Heading 2 means.
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
                        .foregroundStyle(.tertiary)
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

    private func row(_ command: MarkdownEditing.SlashCommand, selected: Bool) -> some View {
        // A Button rather than a tap gesture, so it is one thing to VoiceOver and to the pointer.
        Button {
            choose(command)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: command.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(command.title)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer(minLength: 12)
                Text(command.shorthand)
                    .font(.caption.monospaced())
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
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

/// The bar that appears over a selection: the five inline marks, then the constructs a line can be
/// turned into.
///
/// It is a second way to reach what ⌘B and the slash menu already do, for the hand that is on the
/// mouse — so it calls exactly the same ``MarkdownEditing`` functions and defines nothing of its
/// own. A button reads pressed straight from `isActive`, which is the same question `toggle` asks
/// to decide which way it is going, so the button cannot say "on" while the shortcut turns it on.
struct SelectionToolbar: View {
    let text: String
    let selection: Range<Int>
    let toggle: (MarkdownEditing.InlineMark) -> Void
    let turnInto: (MarkdownEditing.SlashCommand) -> Void

    private static let marks: [(MarkdownEditing.InlineMark, String, String)] = [
        (.bold, "bold", "Bold"),
        (.italic, "italic", "Italic"),
        (.strikethrough, "strikethrough", "Strikethrough"),
        (.code, "chevron.left.forwardslash.chevron.right", "Code"),
        (.link, "link", "Link"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.marks, id: \.0) { mark, symbol, name in
                let on = MarkdownEditing.isActive(mark, in: text, selection: selection)
                button(symbol, name, on: on) { toggle(mark) }
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            ForEach(MarkdownEditing.blockCommands) { command in
                button(command.symbol, command.title, on: false) { turnInto(command) }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: .rect(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private func button(
        _ symbol: String, _ name: String, on: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
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
    let toggle: (MarkdownEditing.InlineMark) -> Void

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
            item("Code", .code, "e", [.command])
            // Not ⌘K: that is Search, and it opens from anywhere including the floating notes
            // panel, so the editor does not get to take it away.
            item("Link", .link, "k", [.command, .shift])
        }
    }

    private func item(
        _ title: String, _ mark: MarkdownEditing.InlineMark,
        _ key: KeyEquivalent, _ modifiers: EventModifiers
    ) -> some View {
        Button(title) { formatting?.toggle(mark) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(formatting == nil)
    }
}
