import AppKit
import MeetingsCore
import SwiftUI

/// The whole window, when the store will not open.
///
/// What it replaced was one `EmptyStateView` whose `message` was
/// `"\(path) could not be opened: \(error.localizedDescription)"` — and on a store with a single
/// orphaned row, `localizedDescription` on GRDB's error is
///
///     SQLite error 19: FOREIGN KEY constraint violation - from transcript_segments(meeting_id)
///     to meetings(id), in [id:1 meeting_id:"…" channel:"mic" t_start_ms:0 t_end_ms:1900
///     text:"Line 0 of a very long transcript about quarterly planning…" pass:"final" edited:0]
///
/// centred, in a 320-point column, as the entire contents of the window: a wall of SQL quoting the
/// user's own transcript back at them, with nothing to click. That store now repairs itself on open
/// (``MeetingsDatabase``), but the ones that cannot — a file that is not a database, a torn one, a
/// full volume, a store from a newer build — still land here, and this is what they get instead.
///
/// Three facts and two buttons: what is wrong, where the file is, what to put in its place, and a
/// way to reach both folders without opening a terminal. Every line is selectable, because the
/// first thing anybody does with a broken database is paste the message at somebody else.
struct StoreUnavailableView: View {
    let error: Error

    /// A `StoreOpenError` has already written the diagnosis and the restore recipe; anything else
    /// gets its own sentence and no recipe, because there is nothing honest to recommend.
    private var prose: String {
        (error as? LocalizedError)?.errorDescription ?? PlainText.sentence(for: error)
    }

    /// The shell lines out of the prose. ``StoreOpenError`` indents them by two spaces, which is
    /// also the only thing in any of these messages that is indented.
    private var paragraphs: (text: String, commands: [String]) {
        var text: [String] = []
        var commands: [String] = []
        for line in prose.components(separatedBy: "\n") {
            if line.hasPrefix("  "), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                commands.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                text.append(line)
            }
        }
        return (text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), commands)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Text(paragraphs.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !paragraphs.commands.isEmpty { recipe }
                buttons
            }
            .textSelection(.enabled)
            .frame(maxWidth: 560, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your meetings could not be opened")
                    .font(.title2.weight(.semibold))
                // The path, on its own line and in the font a path belongs in. The prose names it
                // too, in the middle of a sentence, which is not where anybody looks for it.
                Text(Paths.databaseURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    /// The restore commands, as commands. In the prose they are two indented lines inside a
    /// paragraph; a person about to retype them into a terminal needs to be able to see where each
    /// one starts and ends, and to select one without selecting the sentence around it.
    private var recipe: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(paragraphs.commands, id: \.self) { command in
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Show the store in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Paths.databaseURL])
            }
            .buttonStyle(.borderedProminent)
            if FileManager.default.fileExists(atPath: Paths.backupsRoot.path) {
                Button("Show the snapshots") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.backupsRoot.path)
                }
            }
            Button("Copy this message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prose, forType: .string)
            }
        }
    }
}

/// One sentence for an error the window is about to show a person.
///
/// The window's error banner interpolated `error.localizedDescription`, and on a GRDB error that is
/// the failing SQL statement — and, for a constraint failure, the offending row with its transcript
/// text in it. A banner across the top of the reading pane is the last place that belongs.
///
/// The CLI has the same three-line rule in `PlainError` and the two are deliberately separate: the
/// CLI target does not link this one and neither may add code to `MeetingsCore`, which is where a
/// shared copy would have to live. If a third caller ever needs it, that is the move.
enum PlainText {
    static func sentence(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        let nsError = error as NSError
        if nsError.domain == "GRDB.DatabaseError" {
            let message = nsError.localizedFailureReason ?? "SQLite error \(nsError.code)"
            // GRDB puts the offending row in the message itself, in brackets, for a constraint
            // failure. Everything from the first bracket on is database contents.
            let clause = message.prefix { $0 != "[" }.trimmingCharacters(in: .whitespaces)
            return clause.count > 160 ? clause.prefix(160) + "…" : clause
        }
        switch nsError.domain {
        case NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain:
            return nsError.localizedDescription
        default:
            return "\(error)"
        }
    }
}
