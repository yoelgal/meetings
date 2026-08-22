import AppKit
import MeetingsCore
import SwiftUI

/// Right-click on a meeting row: the handful of things you want to do to a meeting without opening
/// it.
///
/// A `ViewModifier` rather than a view, so the list row it decorates is one line longer than it was.
/// It owns the rename sheet's state for the same reason `SidebarView` owns the folder one: the sheet
/// belongs to the row you right-clicked, not to the list.
///
/// **Nothing here is drawn as if it works when it does not.** An item that cannot do its job is
/// disabled, not hidden — a menu that changes shape from row to row is one nobody learns, and an
/// item that silently does nothing is worse than one that says why it is grey.
struct MeetingContextMenu: ViewModifier {
    let model: AppModel
    let meeting: Meeting

    @State private var renaming = false
    @State private var draftTitle = ""

    func body(content: Content) -> some View {
        content
            .contextMenu { items }
            .sheet(isPresented: $renaming) {
                MeetingTitleSheet(title: $draftTitle) { title in
                    model.rename(meetingID: meeting.id, to: title)
                    renaming = false
                } cancel: {
                    renaming = false
                }
            }
    }

    @ViewBuilder
    private var items: some View {
        Button("Rename…") {
            draftTitle = meeting.title
            renaming = true
        }

        Divider()

        Menu("Move to Folder") {
            Button("Unfiled") { model.move(meetingID: meeting.id, toFolder: nil) }
                .disabled(meeting.folderID == nil)
            ForEach(model.folders) { folder in
                Button(folder.name) { model.move(meetingID: meeting.id, toFolder: folder.id) }
                    // Already there. A destination that is where the meeting already is does
                    // nothing, and a menu item that does nothing is a bug report waiting to happen.
                    .disabled(meeting.folderID == folder.id)
            }
        }
        // With no folders in the store the only destination is Unfiled, and an unfiled meeting is
        // already there — so the whole submenu would be one grey row.
        .disabled(model.folders.isEmpty && meeting.folderID == nil)

        Divider()

        Button("Export Bundle…") { model.exportBundle(meeting) }
            .disabled(busy)
        Button("Export Markdown…") { model.exportMarkdown(meeting) }
            .disabled(busy)
        Button("Copy Agent Command") { model.copyAgentCommand(for: meeting) }
        Button("Reveal Audio in Finder") { model.revealAudio(for: meeting) }
            // Purged by the retention sweep, never recorded, or imported as notes only. All three
            // are ordinary states for a meeting to be in, and none of them has a Finder window.
            .disabled(model.audioDirectory(for: meeting) == nil)

        Divider()

        // The role carries the meaning, but macOS does not colour a destructive menu item the way
        // iOS does, so the one item here that cannot be undone looked exactly like Export. The red
        // is set on the label itself; the role stays because it is what the alert and the
        // accessibility layer read.
        Button(role: .destructive) {
            model.confirmDelete(meeting)
        } label: {
            Text("Delete…").foregroundStyle(busy ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.red))
        }
        .disabled(busy)
    }

    /// A meeting being recorded or transcribed is a moving target. Half its transcript is not
    /// written yet, so a bundle of it is a snapshot of something that is still changing; and the
    /// store refuses to delete a row a recorder is still writing WAVs into.
    ///
    /// Read through ``AppModel/displayState(for:)`` rather than off the row, because while this
    /// process is driving the recording the controller knows it is stopping before the row does.
    private var busy: Bool {
        let state = model.displayState(for: meeting)
        return state == .recording || state == .transcribing
    }
}

extension View {
    func meetingContextMenu(model: AppModel, meeting: Meeting) -> some View {
        modifier(MeetingContextMenu(model: model, meeting: meeting))
    }
}

/// The rename dialog. Mirrors `FolderNameSheet` in `SidebarView.swift` — same shape, same verb on
/// the button, same keyboard — rather than sharing it: that one is private to the sidebar and typed
/// to `FolderNaming`, and generalising it would mean rewriting a file for a twenty-line dialog.
private struct MeetingTitleSheet: View {
    @Binding var title: String
    let confirm: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Meeting")
                .font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { if !trimmed.isEmpty { confirm(title) } }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { confirm(title) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - What the menu items actually do

extension AppModel {
    /// The meeting's audio directory, but only when there is one on disk to show.
    ///
    /// Three separate ordinary states have no directory: audio the retention sweep purged,
    /// a meeting that was never recorded, and one imported as notes with no file. The row alone
    /// cannot tell them apart from a meeting whose WAVs are sitting right there, so this asks the
    /// filesystem — the menu item is "Reveal in Finder", and a Finder window that opens on nothing
    /// is the failure it exists to avoid.
    func audioDirectory(for meeting: Meeting) -> URL? {
        guard meeting.audioPurgedAt == nil else { return nil }
        let directory = meeting.audioPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Paths.audioDirectory(meetingID: meeting.id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return directory
    }

    func revealAudio(for meeting: Meeting) {
        guard let directory = audioDirectory(for: meeting) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    /// The same string the detail pane's Copy button puts there, from the same template.
    func copyAgentCommand(for meeting: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(agentCommand(for: meeting), forType: .string)
    }

    func exportBundle(_ meeting: Meeting) {
        export(
            meeting,
            suggestedName: MeetingBundle.directoryName(for: meeting),
            message: "Lossless bundle with audio, transcript segments, and notes. Can be re-imported."
        ) { scratch in
            try MeetingBundle.export(meeting, store: self.store, to: scratch)
        }
    }

    func exportMarkdown(_ meeting: Meeting) {
        export(
            meeting,
            suggestedName: MeetingBundle.slugName(for: meeting),
            message: "Markdown format for reading and notes apps. Cannot be re-imported."
        ) { scratch in
            try MarkdownExport.export(meeting, store: self.store, to: scratch)
        }
    }

    /// One save panel, two writers, and no second export implementation: both of these are
    /// `MeetingsCore`'s, exactly as the CLI calls them.
    ///
    /// Neither writer takes the path it should write to — each takes a *parent* and chooses the
    /// directory name itself, and `MarkdownExport` nests that under the meeting's folder name as
    /// well. So handing either one the panel's parent directory would quietly ignore the name the
    /// user typed into the panel, and for markdown would leave an empty folder directory beside the
    /// result. They write into a scratch directory instead, and the one directory they produce is
    /// moved to exactly where the panel put it.
    private func export(
        _ meeting: Meeting,
        suggestedName: String,
        message: String,
        write: (URL) throws -> URL
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.message = message
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetings-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let produced = try write(scratch)
            // The panel has already asked about replacing, and `moveItem` will not write over the
            // top of anything — so an item still standing here is one the user agreed to lose.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: produced, to: destination)
        } catch {
            errorMessage = "\(meeting.title) could not be exported: \(PlainText.sentence(for: error))"
        }
    }

    /// Deleting a meeting is the only thing this window does that cannot be undone, and the menu
    /// item sits three rows under Export — so it asks first.
    ///
    /// The dialog says what goes rather than asking whether you are sure: "are you sure" is the
    /// wording people learn to click through. Return is deliberately bound to nothing, so the reflex
    /// of hitting it on a dialog that appeared unexpectedly cannot destroy a recording; Escape still
    /// cancels, which AppKit gives the Cancel button on its own.
    func confirmDelete(_ meeting: Meeting) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(meeting.title)”?"
        alert.informativeText = "Permanently deletes the recording, transcript, notes, and write-up from this Mac. This cannot be undone."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            // Cleared before the row goes, not after. `loadSelection()` treats a selected meeting
            // that has vanished as the other process having deleted it and says so in the error
            // banner — true when the CLI did it, and a confusing thing to be told about a deletion
            // you just confirmed yourself.
            if selection == meeting.id { selection = nil }
            guard try store.deleteMeeting(id: meeting.id) else { return }
            refresh()
        } catch {
            errorMessage = "\(meeting.title) could not be deleted: \(PlainText.sentence(for: error))"
        }
    }
}
