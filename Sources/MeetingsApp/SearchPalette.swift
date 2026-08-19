import MeetingsCore
import SwiftUI

/// The ⌘K search palette: one field, and the store's FTS5 answers underneath it as you type.
///
/// It is an **overlay inside the main window**, not a sheet and not a scene of its own, and that is
/// not a style choice. AppKit refuses to terminate an app that has a sheet attached, and it refuses
/// *before* the application delegate is consulted — so a sheet here would make ⌘Q and macOS's own
/// "Quit & Reopen" silently do nothing for as long as the palette was open, with nowhere in our code
/// to intervene. A separate `Window` scene brings its own traps (`NotesPanel` documents them:
/// launch behaviour, restoration, and a second entry in the Window menu). Ordinary window content
/// has none of that, and it has one more property this app needs: `screencapture -l` on the main
/// window includes it, where a sheet is a child window and drops out of the picture.
struct SearchPalette: View {
    @Bindable var model: AppModel

    @FocusState private var focused: Bool

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        ZStack(alignment: .top) {
            // Clicking away is the mouse's version of Escape. It also stops a click landing on the
            // window behind and changing the selection under an open palette.
            Color.black.opacity(0.16)
                .contentShape(.rect)
                .onTapGesture { model.closeSearchPalette() }
            palette
                .padding(.top, 72)
        }
        .ignoresSafeArea()
    }

    private var palette: some View {
        VStack(spacing: 0) {
            field
            if model.isSearching {
                Divider()
                results
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: Self.shape)
        .overlay(Self.shape.strokeBorder(.separator))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            // Every key the palette answers to is handled here rather than on the container: the
            // field is what has focus, and a handler on an ancestor only sees a key the focused
            // view did not already eat — which is exactly what a text field does with the arrows.
            TextField("Search meetings, notes, transcripts and write-ups", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit { model.openHighlightedResult() }
                .onKeyPress(.upArrow) { model.moveSearchHighlight(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.moveSearchHighlight(by: 1); return .handled }
                .onKeyPress(.escape) { model.closeSearchPalette(); return .handled }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Focus on appear, so the palette is typed into rather than clicked into. Nothing else in
        // the app moves focus on its own; this only ever runs because ⌘K was pressed.
        .task { focused = true }
    }

    @ViewBuilder
    private var results: some View {
        // Same gate every empty state that speaks for the store has. `MEETINGS_SEARCH` opens the
        // palette with a query already in it, and a search that answers "nothing contains X" before
        // the first read of the store is a statement about the user's data made without looking.
        if !model.loaded {
            PaletteMessage(title: "Reading your meetings…")
        } else if model.searchResults.isEmpty {
            PaletteMessage(
                title: "No matches",
                detail: "No meeting name, note, transcript or write-up "
                    + "contains “\(model.searchQuery)”."
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.searchResults.enumerated()), id: \.element.id) { index, hit in
                            SearchResultRow(
                                hit: hit,
                                highlighted: index == model.highlightedResult,
                                incomplete: model.meetingsWithTranscriptIssues.contains(hit.meeting.id)
                            )
                            .id(index)
                            .contentShape(.rect)
                            .onTapGesture {
                                model.highlight(index)
                                model.openHighlightedResult()
                            }
                        }
                    }
                    .padding(6)
                }
                // Arrowing past the fold has to bring the row with it, or the keyboard is driving a
                // highlight nobody can see.
                .onChange(of: model.highlightedResult) { _, index in
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .frame(maxHeight: 320)
        }
    }
}

/// What the palette says when it has no rows to show. Deliberately not `EmptyStateView`: that is a
/// full pane with a large glyph and 32 pt of padding, and dropping it into a 560 pt palette turns
/// two words into a third of the window.
private struct PaletteMessage: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.medium))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

/// A search hit: the meeting, when it was, and the line that actually matched. FTS5 marks the
/// matched words with `«»` (`Search.swift`); they become a bold run here rather than showing up as
/// literal guillemets.
private struct SearchResultRow: View {
    let hit: SearchHit
    var highlighted = false
    var incomplete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(hit.meeting.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if incomplete { TranscriptIssueMark() }
                Spacer(minLength: 8)
                Text(date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The second line is normally the matched text. For a title hit that text is the title
            // already on the line above, so the row says why it is here instead of printing the
            // meeting's name twice.
            Text(hit.kind == .title ? AttributedString("Meeting name") : Self.marked(hit.snippet))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            highlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    /// An imported meeting with no date at all is legal, and a blank slot where every
    /// other row has a date reads as a rendering bug rather than as missing data.
    private var date: String {
        guard let date = hit.meeting.sortDate else { return "Undated" }
        return Format.detailDate(date)
    }

    static func marked(_ snippet: String) -> AttributedString {
        // Flattened to one line first. A pre-notes or summary snippet keeps its newlines, and two
        // lines of a markdown heading is a row that never shows the word you searched for.
        let snippet = snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = AttributedString()
        var emphasised = false
        // The markers alternate by construction, so toggling on each boundary is exact rather than
        // a heuristic.
        for piece in snippet.split(
            omittingEmptySubsequences: false, whereSeparator: { $0 == "«" || $0 == "»" }
        ) {
            var run = AttributedString(piece)
            if emphasised {
                run.font = .caption.weight(.semibold)
                run.foregroundColor = .primary
            }
            out.append(run)
            emphasised.toggle()
        }
        return out
    }
}

/// What replaced the toolbar's search field: the same glyph in the same corner, so search is still
/// found by eye, with the shortcut written on it because typing ⌘K is the faster way in.
struct SearchToolbarButton: View {
    let model: AppModel

    var body: some View {
        Button {
            model.openSearchPalette()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                Text("⌘K")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("Search meetings, notes, transcripts and write-ups")
        .accessibilityLabel("Search")
    }
}
