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

            Text("The audio is copied into Meetings and transcribed on this Mac. There is one "
                + "track, so the transcript has no microphone / system split.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // A warning, not a gate: the audio is copied and the meeting is created either way.
            if !prerequisites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    PrerequisiteNotice(prerequisites: prerequisites) {
                        Task { prerequisites = await Prerequisites.forTranscription(transcription) }
                    }
                    Text("Importing now still works. The meeting is created either way and stays at "
                        + "Transcribing while the download runs.")
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
        .task { prerequisites = await Prerequisites.forTranscription(transcription) }
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
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // An imported file is one mixed track, so it lands on the mic channel: that is the only
            // track the batch pass reads when there is no second file, and inventing a third
            // channel value would be a schema change. The detail view knows an imported meeting has
            // no channel split and stops claiming one — see `WrittenDetailView`.
            try Self.convertToWAV16k(
                source: pending.url,
                destination: directory.appendingPathComponent("mic.wav")
            )
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

    /// Decodes anything Core Audio can open — m4a, mp3, aiff, wav — into the exact format Parakeet
    /// wants. Resampling here rather than in the engine means the stored audio is the same shape a
    /// recorded meeting's is, so nothing downstream has to know where it came from.
    nonisolated static func convertToWAV16k(source: URL, destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: input.processingFormat, to: outputFormat) else {
            throw ImportError.unsupported(source.lastPathComponent)
        }
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])

        let frames: AVAudioFrameCount = 16_384
        // The converter calls its input block synchronously, on this thread, before `convert`
        // returns — so one reusable buffer is correct here despite the block being `@Sendable`.
        nonisolated(unsafe) let scratch = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat, frameCapacity: frames
        )
        guard let scratch else { throw ImportError.unsupported(source.lastPathComponent) }

        while true {
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames)
            else { throw ImportError.unsupported(source.lastPathComponent) }
            var failure: NSError?
            let status = converter.convert(to: converted, error: &failure) { _, inputStatus in
                do {
                    try input.read(into: scratch)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard scratch.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return scratch
            }
            if let failure { throw failure }
            if converted.frameLength > 0 { try output.write(from: converted) }
            if status == .endOfStream || status == .error { break }
        }
    }
}

enum ImportError: Error, LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): "\(name) is not an audio file this Mac can decode"
        }
    }
}
