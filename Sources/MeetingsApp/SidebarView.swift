import MeetingsCore
import SwiftUI

/// Sidebar. No painted background — the window's own material shows through, which is what makes
/// it read as a macOS 26 sidebar rather than a coloured panel.
struct SidebarView: View {
    @Bindable var model: AppModel

    /// Non-nil while the create/rename sheet is up. One piece of state for both, because they are
    /// the same dialog with a different verb.
    @State private var naming: FolderNaming?
    @State private var draftName = ""

    var body: some View {
        List(selection: selection) {
            // Pinned above everything, with its count, because in the default manual mode nothing
            // writes a summary on its own and this list is the only thing that remembers.
            row(.needsWriteUp, badge: model.needsWriteUpCount)

            Section {
                row(.all)
                row(.upcoming)
                row(.unfiled)
                    // Dropping onto Unfiled is how a meeting leaves a folder without needing a
                    // second gesture to mean "no folder".
                    .dropDestination(for: String.self) { ids, _ -> Bool in model.drop(ids, into: nil) }
            } header: {
                sectionHeader("Library")
            }

            Section {
                // Gated on the first read, like every other empty state: an unread store and a
                // store with no folders look identical and mean opposite things. Nothing is drawn
                // in its place — a spinner in a sidebar section is louder than the two seconds it
                // covers, and the meetings column beside it is already saying the store is loading.
                if model.loaded, model.folders.isEmpty {
                    Text("No folders yet")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
                ForEach(model.folders) { folder in
                    row(.folder(folder.id), title: folder.name, count: model.count(inFolder: folder.id))
                        .dropDestination(for: String.self) { ids, _ -> Bool in model.drop(ids, into: folder.id) }
                        .contextMenu {
                            Button("Rename folder…") { begin(.rename(folder)) }
                            // Red on the label, for the same reason the meeting's Delete… is red
                            // in `MeetingActions`: macOS does not colour a destructive *menu* item
                            // the way iOS does, so the role alone left this looking exactly like
                            // Rename. Two delete items in one window that do not look alike is the
                            // inconsistency; the role stays, because that is what the accessibility
                            // layer reads.
                            Button(role: .destructive) {
                                model.deleteFolder(id: folder.id)
                            } label: {
                                Text("Delete folder").foregroundStyle(.red)
                            }
                        }
                }
            } header: {
                HStack {
                    sectionHeader("Folders")
                    Spacer()
                    Button("New folder", systemImage: "plus") { begin(.create) }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .help("Create a folder")
                        // A section header gets less trailing inset than a row does, so a button
                        // pushed to the header's edge overhangs the counts in the rows above it by
                        // about this much and reads as falling off the sidebar. Measured against
                        // the badge column rather than picked — the two have to line up.
                        .padding(.trailing, 15)
                }
            }
        }
        .listStyle(.sidebar)
        // 160 rather than 180: the reading column is the one that has to survive a narrow window,
        // so the two navigation columns are the ones that give. A folder name still fits.
        .navigationSplitViewColumnWidth(min: 160, ideal: 216, max: 320)
        // Pinned under the list rather than added as a last row: it is not a scope, so selecting it
        // would have to mean something, and a row that scrolls away is a notice you can miss by
        // having enough folders.
        .safeAreaInset(edge: .bottom) {
            if let update = model.availableUpdate {
                UpdateNotice(update: update)
            }
        }
        .sheet(item: $naming) { naming in
            FolderNameSheet(naming: naming, name: $draftName) { name in
                switch naming {
                case .create:
                    if let folder = model.createFolder(named: name) { model.scope = .folder(folder.id) }
                case .rename(let folder):
                    model.renameFolder(id: folder.id, to: name)
                }
                self.naming = nil
            } cancel: {
                self.naming = nil
            }
        }
    }

    private func begin(_ naming: FolderNaming) {
        draftName = naming.initialName
        self.naming = naming
    }

    /// `List` selection is always optional; the sidebar's never is — clicking empty space below the
    /// rows must not leave the app with no scope at all.
    private var selection: Binding<Scope?> {
        Binding(
            get: { model.scope },
            set: { if let new = $0 { model.scope = new } }
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    @ViewBuilder
    private func row(
        _ scope: Scope,
        title: String? = nil,
        badge: Int? = nil,
        count: Int? = nil
    ) -> some View {
        SidebarRow(title: title ?? scope.title, symbol: scope.symbol, selected: model.scope == scope)
            // A badge is a call to action; a count is just how many. Needs write-up gets the first,
            // a folder the second, matching Notes' quiet trailing count.
            .badge(badge.flatMap { $0 > 0 ? Text("\($0)") : nil } ?? count.map { Text("\($0)") })
            .tag(scope)
    }
}

/// The foot of the sidebar when a newer release exists.
///
/// It says "View release" and not "Restart to update", which is what a notice like this usually
/// says, because nothing here downloads or installs anything: this build was compiled from source on
/// the machine it runs on, so there is no new binary for a restart to pick up. Copy that promises a
/// restart will do it would be a lie the first person to try it discovers.
private struct UpdateNotice: View {
    let update: AvailableUpdate

    var body: some View {
        // An explicit container, not two siblings in the builder. A `body` returning a bare tuple
        // hands `safeAreaInset` two views with no layout between them, which is a stack in some
        // contexts and an overlap in others.
        VStack(spacing: 0) {
            Divider()
            Button {
                NSWorkspace.shared.open(update.url)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update available")
                            .font(.callout)
                        Text("Version \(update.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                // Without this only the glyphs are clickable, and the dead space between them
                // reads as a row that sometimes ignores you.
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the release notes on GitHub")
            // Measured against the scope rows above rather than picked: a `List` row carries its own
            // selection-capsule inset on top of the section inset, and at 14 the arrow sat visibly
            // left of every icon in the column.
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        }
        // The list scrolls *under* a safe-area inset, so without a ground the rows pass through the
        // text on the way past.
        .background(.bar)
    }
}

/// One sidebar row, coloured deliberately rather than left to the default.
///
/// Measured against Notes on this machine (`w3-shots/shots/_ref-notes-inactive-side.png`), with the
/// window *not* key — which is how a sidebar spends most of its life, since you are usually in the
/// browser or on the call: Notes draws unselected rows at full label colour, and the selected row's
/// icon *and* label in the accent colour over a quiet grey fill. A plain `Label` in a SwiftUI
/// sidebar draws all of it dimmed, selected row included, which is what wave 2 shipped and what the
/// critic measured as achromatic (proved with a four-variant probe, `w3-shots/shots/_probe*.png`).
///
/// When the window *is* key, AppKit paints the selected row with a filled accent background and
/// white content of its own accord, so the override is scoped to the inactive state — overriding
/// both would put accent text on an accent fill.
private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Label {
            Text(title).foregroundStyle(style)
        } icon: {
            Image(systemName: symbol).foregroundStyle(style)
        }
        .font(.body)
    }

    /// It is the user's accent, so a graphite accent gives a graphite selected row — exactly as it
    /// does in Notes, and the reason nothing else in this app leans on `.tint` being colourful.
    /// `.tint` rather than `Color(nsColor: .controlAccentColor)`: they are the same setting, but
    /// the shape style renders #0070F5 in light against the AppKit colour's #007AFF, which is worth
    /// a measured 3.31:1 instead of 2.93:1 on the selected row's fill.
    ///
    /// Measured, window inactive: 3.31:1 light / 2.35:1 dark, where Notes in the identical state is
    /// 3.14:1. The residual gap in dark is not the hue, it is the fill — SwiftUI's unemphasized
    /// sidebar selection paints `unemphasizedSelectedContentBackgroundColor` (#464646 dark) while
    /// Notes draws a far quieter lift over the sidebar (#2F3436), and that fill is not something an
    /// app can supply without taking over selection rendering in both activation states.
    private var style: AnyShapeStyle {
        selected && controlActiveState == .inactive
            ? AnyShapeStyle(.tint)
            : AnyShapeStyle(.primary)
    }
}

enum FolderNaming: Identifiable {
    case create
    case rename(Folder)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let folder): folder.id
        }
    }

    var initialName: String {
        switch self {
        case .create: ""
        case .rename(let folder): folder.name
        }
    }

    var verb: String {
        switch self {
        case .create: "Create folder"
        case .rename: "Rename folder"
        }
    }
}

private struct FolderNameSheet: View {
    let naming: FolderNaming
    @Binding var name: String
    let confirm: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(naming.verb)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmed.isEmpty { confirm(name) } }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(naming.verb) { confirm(name) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension AppModel {
    /// Read from the counts `refresh()` last worked out, not from the store.
    ///
    /// This used to run its own `SELECT` per row, straight out of `body`. A query is not an
    /// observed property, so SwiftUI had nothing to invalidate on: filing two meetings from the CLI
    /// refreshed the middle column and left both sidebar rows reading `0`, and they stayed at `0`
    /// until something else happened to touch `folders`. Under 500 folders it was also 500 queries
    /// every time the sidebar drew.
    func count(inFolder id: String) -> Int { folderCounts[id] ?? 0 }

    /// The drop half of drag-a-meeting-into-a-folder. A `String` payload rather than a bespoke
    /// `Transferable`: the only thing that produces one is our own list row, and a stray text drop
    /// resolves to no meeting and is ignored — which is 30 lines less than a custom UTType for the
    /// same behaviour.
    func drop(_ ids: [String], into folderID: String?) -> Bool {
        let moved = ids.filter { id in
            ((try? store.meeting(id: id)) ?? nil) != nil && move(meetingID: id, toFolder: folderID)
        }
        return !moved.isEmpty
    }
}
