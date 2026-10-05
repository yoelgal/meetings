// @preconcurrency: AVAudioFile and AVAudioPCMBuffer predate Sendable and are not annotated, but
// `AVAudioConverter.convert` calls its input block synchronously on this thread before returning,
// so the buffer this closure reuses never crosses one. Scoped to this file.
@preconcurrency import AVFoundation
import MeetingsCore
import SwiftUI
import UniformTypeIdentifiers

/// An audio file dropped on the window, waiting for the small dialog that names it. Everything
/// harder than this — a folder of voice memos, a Granola export, a legacy dump — is a CLI job
/// driven by an agent, and deliberately so.
struct PendingImport: Identifiable {
    let id = UUID()
    let url: URL
    var title: String
    var date: Date
    var folderID: String?

    init(url: URL) {
        self.url = url
        // The filename is a *default* the user is looking straight at and can correct, not an
        // inference the machine made behind their back — which is the thing this must never do.
        self.title = url.deletingPathExtension().lastPathComponent
        self.date = Date()
        self.folderID = nil
    }
}

/// Title, date, folder. Three fields, because that is the whole GUI import story.
struct ImportSheet: View {
    @State var pending: PendingImport
    let folders: [Folder]
    let transcription: TranscriptionService
    /// Needed alongside the service because what "the transcriber is missing" means depends on which
    /// engine is selected, and the engine is a setting.
    let store: MeetingStore
    let cancel: () -> Void
    let confirm: (PendingImport) -> Void

    @State private var working = false
    /// Whether the transcriber is on disk, asked once when the sheet opens. This dialog is the last
    /// moment before Import hands the meeting to the batch engine, which fetches about a gigabyte
    /// without asking and without a progress bar anywhere the user is looking — so the warning has
    /// to be here, where it can still be read, rather than after the download has started.
    @State private var prerequisites: [Prerequisite] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import a recording")
                    .font(.title2.weight(.semibold))
                Text(pending.url.lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Form {
                TextField("Title", text: $pending.title)
                DatePicker("Date", selection: $pending.date, displayedComponents: [.date, .hourAndMinute])
                Picker("Folder", selection: $pending.folderID) {
                    Text("Unfiled").tag(String?.none)
                    ForEach(folders) { folder in
                        Text(folder.name).tag(String?.some(folder.id))
                    }
                }
            }
            .formStyle(.grouped)

            Text(whereItIsTranscribed + " Single-track audio has no mic/system split.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A warning, not a gate: the audio is copied and the meeting is created either way.
            if !prerequisites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    PrerequisiteNotice(prerequisites: prerequisites) {
                        Task { prerequisites = await Prerequisites.forTranscription(transcription, store: store) }
                    }
                    Text("The meeting is created immediately and will transcribe once the download finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    working = true
                    confirm(pending)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(working || pending.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .task { prerequisites = await Prerequisites.forTranscription(transcription, store: store) }
    }

    /// The sentence the user reads immediately before pressing Import, and the last moment before
    /// the file leaves this Mac — so it says which of the two things actually happens. With the
    /// remote engine selected and fully configured nothing warns: `Prerequisites.forTranscription`
    /// is empty by design (there is nothing to download), and a claim of "transcribed on this Mac"
    /// beside an Import button that uploads is the one sentence in the app that must not be wrong.
    /// The wording is ``RemoteTranscriptionFields``', so setup and import say the same thing.
    ///
    /// ponytail: read on every body pass rather than cached in `@State` — one settings row, and a
    /// cached copy is how this goes stale the next time the setting moves.
    private var whereItIsTranscribed: String { Self.whereItIsTranscribed(store.transcriptionEngine()) }

    /// A function of the engine choice and nothing else, so `ImportSheetWordingTests` can ask it both
    /// questions. As a computed property reading `@State` it was reachable only by opening the sheet,
    /// which left the one sentence in the app that must not be wrong pinned by nothing.
    static func whereItIsTranscribed(_ engine: TranscriptionEngineChoice) -> String {
        switch engine {
        case .local:
            "The audio is copied into Meetings and transcribed on this Mac."
        case .cloud:
            "Audio is uploaded — the recording leaves it. Notes, search, and write-ups stay on this Mac."
        }
    }
}

extension AppModel {
    /// Audio types the drop target accepts. Anything else lands on the window and is ignored — a
    /// dropped PDF should do nothing, not open a dialog that then fails.
    static let importableAudioTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]

    func beginImport(of url: URL) {
        pendingImport = PendingImport(url: url)
    }

    /// Copies the file in as the meeting's audio, converted to the 16 kHz mono WAV the batch engine
    /// expects, and joins the transcription queue (audio present means `transcribing`).
    func completeImport(_ pending: PendingImport) async {
        pendingImport = nil
        let meeting = Meeting(
            folderID: pending.folderID,
            title: pending.title.trimmingCharacters(in: .whitespacesAndNewlines),
            state: .transcribing,
            scheduledStart: pending.date,
            startedAt: pending.date,
            source: .imported,
            importedFrom: pending.url.lastPathComponent
        )
        let directory = Paths.audioDirectory(meetingID: meeting.id)
        let source = pending.url
        do {
            // An imported file is one mixed track, so it lands on the mic channel: that is the only
            // track the batch pass reads when there is no second file, and inventing a third
            // channel value would be a schema change. The detail view knows an imported meeting has
            // no channel split and stops claiming one — see `WrittenDetailView`.
            //
            // Off the main actor: decoding a two-hour m4a is tens of seconds of work, and on the
            // main actor that is tens of seconds of a frozen window.
            try await Task.detached { try AudioIngest.install(source, forMeeting: meeting.id) }.value
            var stored = meeting
            stored.audioPath = directory.path
            try store.createMeeting(stored)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            errorMessage = "\(pending.url.lastPathComponent) could not be imported: "
                + PlainText.sentence(for: error)
            return
        }
        refresh()
        selection = meeting.id
        await transcription.enqueue(meetingID: meeting.id)
    }
}
