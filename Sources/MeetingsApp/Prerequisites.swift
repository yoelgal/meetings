import AppKit
import MeetingsCore
import SwiftUI

/// Something an action needs that is not there yet, and the one control that fixes it.
///
/// The setup wizard is skippable on purpose, so any of these can be missing at the moment they are
/// needed. Before this existed each of them failed in its own way and none of them said what to do:
/// recording started and produced no transcript, dropping a file on the window began a silent 1 GB
/// download, and the agent command was handed over as a line to paste whether or not the CLI it
/// names was on the machine.
struct Prerequisite: Identifiable {
    enum Fix {
        /// Ask for it. Only ever from a press.
        case grant(Permission)
        /// Settings owns the download — it has the progress bar and the cancel — so send them there
        /// rather than growing a second copy of it everywhere a model turns out to be missing.
        case downloadModels
        /// The remote engine's fields live in the same pane as the download, and there is nothing
        /// this app can press on the user's behalf to fix a missing API key.
        case openTranscriptionSettings
        case installCLI
    }

    var id: String
    var title: String
    /// One sentence: what this action cannot do without it. Never the raw error.
    var detail: String
    var fix: Fix
}

enum Prerequisites {
    /// What recording needs. Order is worst-first, and the mic is worst: without it there is no
    /// recording at all, where the other two each cost part of one.
    static func forRecording(_ transcription: TranscriptionService, store: MeetingStore) async -> [Prerequisite] {
        var missing: [Prerequisite] = []
        if Permission.microphone.status != .granted {
            missing.append(Prerequisite(
                id: "mic",
                title: "Microphone access",
                detail: "Without it your own side of the conversation is not recorded at all.",
                fix: .grant(.microphone)
            ))
        }
        if Permission.systemAudio.status != .granted {
            missing.append(Prerequisite(
                id: "system-audio",
                title: "System audio",
                detail: "Recording still works, but only your voice is captured. Everyone else "
                    + "on the call is missing from the transcript.",
                fix: .grant(.systemAudio)
            ))
        }
        missing.append(contentsOf: await forTranscription(transcription, store: store))
        return missing
    }

    /// What turning audio into text needs — which depends on where transcription is set to run.
    ///
    /// Engine-aware because it has to be: this notice gates the record button, and asking a user who
    /// deliberately chose a remote endpoint to download a gigabyte of models they will never use
    /// would be a permanent, unfixable warning on the one path where nothing is missing.
    static func forTranscription(_ transcription: TranscriptionService, store: MeetingStore) async -> [Prerequisite] {
        guard await !transcription.modelsReady() else { return [] }
        guard store.transcriptionEngine() == .local else {
            return [Prerequisite(
                id: "remote-endpoint",
                title: "The transcription endpoint is not set up",
                detail: "Transcription is set to a remote endpoint, and its address, model or API "
                    + "key is missing. Recording works; nothing will be transcribed.",
                fix: .openTranscriptionSettings
            )]
        }
        let option = store.localTranscriptionOption()
        return [Prerequisite(
            id: "models",
            title: "The transcriber is not downloaded",
            detail: "\(option.title): about \(option.downloadSizeText), once. Until it is here "
                + "there is no live transcript"
                + (option.runsSeparateBatchPass
                    ? ", and the accurate pass has to fetch it before it can run." : "."),
            fix: .downloadModels
        )]
    }

    /// What a command written for your agent needs to actually run when you paste it.
    static func forAgentCommand() -> [Prerequisite] {
        switch CLIInstall.status() {
        case .installed, .unavailable:
            return []
        case .missing, .foreign:
            return [Prerequisite(
                id: "cli",
                title: "The meetings command is not installed",
                detail: "This command will not be found until the CLI is linked into your PATH.",
                fix: .installCLI
            )]
        }
    }
}

/// The standard way a missing prerequisite is shown: what is missing, why it matters here, and the
/// button that fixes it. Deliberately not an alert — nothing here interrupts, and every one of them
/// is survivable.
struct PrerequisiteNotice: View {
    let prerequisites: [Prerequisite]
    /// Called after a fix is applied, so the caller can re-check and drop the notice.
    var recheck: () -> Void = {}

    @State private var cliProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(prerequisites) { prerequisite in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prerequisite.title)
                            .font(.callout.weight(.medium))
                        Text(prerequisite.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    control(for: prerequisite.fix)
                        .controlSize(.small)
                }
            }
            if let cliProblem {
                Text(cliProblem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10, style: .continuous))
        // The user leaves to grant something and comes back; that is the moment the notice is most
        // likely to be out of date.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in recheck() }
    }

    @ViewBuilder
    private func control(for fix: Prerequisite.Fix) -> some View {
        switch fix {
        case .grant(let permission):
            if permission.status == .denied {
                // TCC never asks twice, so a denial can only be undone in System Settings.
                Button("Open System Settings") {
                    if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
                }
            } else {
                Button("Allow…") {
                    Task {
                        await permission.request()
                        recheck()
                    }
                }
            }
        case .downloadModels:
            SettingsLink { Text("Download…") }
        case .openTranscriptionSettings:
            SettingsLink { Text("Set up…") }
        case .installCLI:
            Button("Install") {
                Task {
                    cliProblem = await CLIInstall.install()
                    recheck()
                }
            }
        }
    }
}
