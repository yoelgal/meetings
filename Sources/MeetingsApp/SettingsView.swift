import MeetingsCore
import Observation
import SwiftUI

/// Settings: providers, the agent command template, audio retention, vocabulary, CLI
/// install, and permissions status.
///
/// Every value here is a row in the `settings` table, so the CLI's `meetings config get/set` and
/// this window are the same setting rather than two copies of it. API keys are the exception and go
/// to the Keychain; the row holds the account name only.
struct SettingsView: View {
    let model: AppModel
    /// A screenshot seam only — see `Appearance.panel`. Nil in every real launch.
    var initialTab: String?

    @State private var tab = Tab.general

    enum Tab: String, CaseIterable, Identifiable {
        case general, ai, transcription, vocabulary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .ai: "AI"
            case .transcription: "Transcription"
            case .vocabulary: "Vocabulary"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .ai: "sparkles"
            case .transcription: "waveform"
            case .vocabulary: "textformat.abc"
            }
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { tab in
                Group {
                    switch tab {
                    case .general: GeneralSettings(model: model)
                    case .ai: AISettings(model: model)
                    case .transcription: TranscriptionSettings(model: model)
                    case .vocabulary: VocabularySettings(model: model)
                    }
                }
                .tabItem { Label(tab.title, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
        .frame(width: 620, height: 520)
        .onAppear { if let initialTab, let parsed = Tab(rawValue: initialTab) { tab = parsed } }
    }
}

/// A settings row, read once and written straight through. Not an observable model object: the
/// store is the state, and a second copy of it in memory is how the CLI's writes and the window's
/// disagree.
@MainActor
struct SettingBinding {
    let store: MeetingStore
    let key: SettingKey

    func binding(_ cache: Binding<String>) -> Binding<String> {
        Binding(
            get: { cache.wrappedValue },
            set: { new in
                cache.wrappedValue = new
                // The window must not take what `meetings config set` refuses. The two egress rows
                // decide where this Mac's audio and transcripts are uploaded, and a cleartext
                // endpoint typed here used to be stored on the keystroke — the same hole the CLI
                // closed, with a text field in front of it. Clearing the row stays allowed: no
                // endpoint is not an insecure endpoint.
                guard new.isEmpty || SettingKey.egressRefusal(new, for: key) == nil else { return }
                try? store.setSetting(key, new.isEmpty ? nil : new)
            }
        )
    }
}

/// Says under an egress field when what is in it will not be stored — and, on open, when what is
/// **already** stored is a cleartext endpoint.
///
/// The second case is the one that matters: a row written before the refusal existed keeps
/// uploading in the clear, and nothing anywhere said so. It is a warning rather than a refusal on
/// purpose — the app going silent about a value it has been using for months, mid-meeting, would be
/// worse than the value.
struct EgressWarning: View {
    let key: SettingKey
    let value: String

    var body: some View {
        if !value.isEmpty, let refusal = SettingKey.egressRefusal(value, for: key) {
            Label(refusal, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color(nsColor: .systemOrange))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
func loadSetting(_ store: MeetingStore, _ key: SettingKey) -> String {
    ((try? store.setting(key)) ?? nil) ?? key.defaultValue ?? ""
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var model: AppModel

    @State private var retention = ""
    @State private var lookAhead = ""
    @State private var cliStatus = CLIInstall.status()
    @State private var cliProblem: String?
    @State private var statuses: [Permission: PermissionStatus] = [:]
    @State private var checking = false
    @State private var checkResult: UpdateCheck.Outcome?

    var body: some View {
        Form {
            Section("Upcoming") {
                LabeledContent("Look ahead") {
                    HStack(spacing: 6) {
                        TextField(
                            "Days",
                            text: SettingBinding(store: model.store, key: .calendarLookAheadDays)
                                .binding($lookAhead)
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        Text("days")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("""
                    Meetings with a link in that window get a row, so you can write notes \
                    before they start.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio retention") {
                // The unit sits in the row, not only in the caption underneath: a bare number field
                // reading "30" says nothing about what 30 is.
                LabeledContent("Delete audio after") {
                    HStack(spacing: 6) {
                        TextField(
                            "Days",
                            text: SettingBinding(store: model.store, key: .audioRetentionDays)
                                .binding($retention)
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                        Text("days")
                            .foregroundStyle(.secondary)
                    }
                }
                // One string literal, not two joined with `+`: `Text("…" + "…")` is an expression,
                // so SwiftUI never sees a `LocalizedStringKey` and the backticks below would draw
                // as backticks. `MarkdownLiteralTests` fails the build if this idiom comes back.
                Text("""
                    `0` keeps recordings forever. Only the audio is deleted — never your \
                    transcripts or notes.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Floating notes panel") {
                Toggle("Hide the notes panel from screen sharing", isOn: $model.notesPanelHiddenFromCapture)
                Text("""
                    Zoom, Meet, Teams and anything else recording your screen cannot see it. \
                    Neither can your own screenshots.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Keep the notes panel above other apps", isOn: $model.notesPanelFloats)
                Text("The panel stays on top of other windows, even full-screen ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Updates") {
                LabeledContent("This copy") {
                    HStack(spacing: 8) {
                        Text("Version \(AppInfo.version)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(checking ? "Checking…" : "Check now") {
                            checking = true
                            checkResult = nil
                            Task {
                                checkResult = await model.checkForUpdates()
                                checking = false
                            }
                        }
                        .disabled(checking)
                    }
                }
                if let checkResult {
                    // Every outcome says something. A button whose only visible effect is sometimes
                    // a new row elsewhere in the window is a button you press twice.
                    switch checkResult {
                    case .update(let update):
                        Text("Version \(update.version) is available. See the foot of the sidebar.")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    case .upToDate:
                        Text("You are up to date.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .failed(let why):
                        Text(why).font(.caption).foregroundStyle(Color(nsColor: .systemOrange))
                    case .skipped:
                        // Unreachable from a press, which never skips. Written out so a future
                        // trigger cannot fall through this switch silently.
                        EmptyView()
                    }
                }

                Toggle("Check automatically", isOn: $model.updateCheckEnabled)
                Text("""
                    Meetings asks GitHub daily whether a newer version exists. It sends nothing \
                    about you or your meetings.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Command line") {
                LabeledContent("meetings") {
                    HStack(spacing: 8) {
                        Text(cliStatus.label)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Install") {
                            Task {
                                cliProblem = await CLIInstall.install()
                                cliStatus = CLIInstall.status()
                            }
                        }
                    }
                }
                if let cliProblem {
                    Text(cliProblem)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("""
                    Puts the `meetings` command in /usr/local/bin, so your agent can run it \
                    from anywhere.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        status: statuses[permission] ?? permission.status
                    ) { new in
                        statuses[permission] = new
                    }
                }
                // Under the rows, not above them: it is the answer to "why am I being asked again",
                // which is a question you have while looking at this list.
                if CodeSignature.isAdHoc { AdHocSigningNotice() }
            }

            Section {
                Button("Show the setup guide again") { model.showingOnboarding = true }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            retention = loadSetting(model.store, .audioRetentionDays)
            lookAhead = loadSetting(model.store, .calendarLookAheadDays)
            // Reading a status never prompts, so this is safe to do every time the pane appears —
            // the user may have changed something in System Settings since.
            statuses = Permission.snapshot()
        }
        .refreshingPermissions(into: $statuses)
    }
}

/// Reports, and only asks when the button is pressed. A settings pane that prompts on appearance is
/// how an app gets denied three permissions in one second.
struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    let changed: (PermissionStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: permission.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(permission.title)
                Spacer()
                Label(status.label, systemImage: status.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(tint)
                switch status {
                case .notDetermined:
                    Button("Allow…") {
                        Task { changed(await permission.request()) }
                    }
                case .denied:
                    Button("Open System Settings") {
                        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
                    }
                case .granted:
                    EmptyView()
                }
            }
            Text(permission.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch status {
        case .granted: Color(nsColor: .systemGreen)
        case .denied: Color(nsColor: .systemRed)
        case .notDetermined: .secondary
        }
    }
}

// MARK: - AI

private struct AISettings: View {
    let model: AppModel

    @State private var mode = AIMode.manual

    var body: some View {
        Form {
            Section("How meetings get written up") {
                // All three modes, always. Two of them used to sit behind an "Advanced modes…"
                // button, so the two ways of getting a write-up without doing it by hand were
                // invisible to anybody who did not press a disclosure — in the one pane whose
                // entire purpose is choosing between the three.
                Picker("Mode", selection: modeBinding) {
                    Text("Manual — you ask your own agent").tag(AIMode.manual)
                    Text("Local agent — Meetings runs a command").tag(AIMode.localAgent)
                    Text("Cloud — a provider writes it").tag(AIMode.cloud)
                }
                .pickerStyle(.inline)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Exactly one section, belonging to the mode in effect. All three could draw at once,
            // and the manual one drew unconditionally — so Local agent showed a "Command to copy"
            // directly above a "Command to run": two fields, near-identical labels, one of them
            // irrelevant to the chosen mode and both of them plausible places to type. There is no
            // state to lose by hiding a section, because every field writes its settings row as it
            // changes rather than on a Save.
            switch mode {
            case .manual:
                Section("The command you copy") {
                    ManualPasteCommandFields(store: model.store)
                }
            case .localAgent:
                Section("The command Meetings runs") {
                    LocalAgentCommandFields(store: model.store)
                }
            case .cloud:
                Section("Your provider") {
                    CloudProviderFields(store: model.store)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { mode = AIMode(stored: loadSetting(model.store, .aiMode)) }
    }

    private var modeBinding: Binding<AIMode> {
        Binding(
            get: { mode },
            set: { new in
                mode = new
                try? model.store.setSetting(.aiMode, new.rawValue)
            }
        )
    }

    private var explanation: String {
        switch mode {
        case .manual:
            "Nothing runs on its own. Finished meetings wait under Needs write-up until you ask "
                + "your agent."
        case .localAgent:
            "Meetings runs the command below as soon as a meeting is ready. Whether the transcript "
                + "leaves this Mac depends on the command you set."
        case .cloud:
            "Your transcript and notes are sent to the provider below, and the summary it returns "
                + "is saved."
        }
    }
}

// MARK: - The fields a mode needs, wherever it is being chosen

/// Mode A's one setting: the line the Needs-write-up card offers to copy.
///
/// Nothing here is executed, so there is nothing to check — the value is a slash command for a
/// session that is already open, and a verify button beside it could only resolve it as a binary
/// and wrongly call it missing.
struct ManualPasteCommandFields: View {
    let store: MeetingStore

    @State private var command = ""

    var body: some View {
        TextField(
            "Command to copy",
            text: SettingBinding(store: store, key: .aiManualPasteCommand).binding($command)
        )
        .font(.callout.monospaced())
        .onAppear { command = loadSetting(store, .aiManualPasteCommand) }

        Text("""
            The Copy button on a finished meeting copies this, with `{meeting_id}` filled in. \
            Meetings never runs it.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Mode B's command, the agent it came from, and the check that resolves it.
///
/// The wizard's fourth page and Settings ▸ AI both draw *this* view, so there is one field bound to
/// one settings row. Two sets of fields over the same row is how the wizard and Settings come to
/// disagree about what is configured.
///
/// **The chooser is a way of filling the field, not a second source of truth.** The stored template
/// is the setting; the picker is seeded by asking ``AgentPreset`` which preset that template came
/// from, and lands on "Something else" whenever the answer is none. A picker holding its own idea of
/// the chosen agent would relabel a hand-written command as some preset it does not match, and then
/// overwrite it from that preset on the next redraw — losing a command the user typed, in a field
/// they were not looking at, for a mode that runs unattended.
struct LocalAgentCommandFields: View {
    let store: MeetingStore

    /// Nil is "Something else": a command matching no preset, which is a legitimate answer and the
    /// one a hand-written command has to be able to keep.
    @State private var preset: AgentPreset?
    @State private var template = ""
    @State private var result: AIVerification?
    /// The check is no longer instant: `EnhancementRunner.searchPath(in:)` resolves the login
    /// shell's PATH by spawning `$SHELL -ilc` the first time anything in the process asks, bounded
    /// at two seconds. So the press reports that it is working, exactly as the cloud check's does.
    @State private var checking = false

    var body: some View {
        Picker("Agent", selection: presetBinding) {
            ForEach(AgentPreset.all) { agent in
                Text(agent.name).tag(AgentPreset?.some(agent))
            }
            Text("Something else").tag(AgentPreset?.none)
        }
        .onAppear {
            template = loadSetting(store, .aiLocalAgentRunCommand)
            preset = AgentPreset.matching(runCommand: template)
        }

        TextField("Command to run", text: commandBinding)
            .font(.callout.monospaced())

        // Named for what it does rather than "Verify": the check resolves a binary and stops, and a
        // button promising verification would be promising more than the sentence underneath it can
        // deliver.
        HStack(spacing: 10) {
            Button("Check the command", action: check)
                .disabled(checking)
            if checking {
                ProgressView().controlSize(.small)
            }
        }

        if let result { VerifyResultLabel(result: result) }

        Text("""
            `{meeting_id}` becomes the meeting's id. It runs directly, so pipes and `&&` do \
            nothing.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Picking an agent fills in **both** command forms from it.
    ///
    /// The pasteable line and the executed line are two different settings on purpose — `claude -p`
    /// execs and starts a fresh headless run, `/meetings` pastes into a session already open — but
    /// they are two halves of one answer to "which agent do you use". Filling only the one in front
    /// of the user leaves the other holding a different agent's command, which surfaces much later
    /// as a Copy button offering a line for a tool this user does not run.
    private var presetBinding: Binding<AgentPreset?> {
        Binding(
            get: { preset },
            set: { chosen in
                preset = chosen
                // "Something else" writes nothing. It is the user saying they will type it
                // themselves, and clearing the field they are about to type into would be a strange
                // reading of that.
                guard let chosen else { return }
                template = chosen.runCommand
                try? store.setSetting(.aiLocalAgentRunCommand, chosen.runCommand)
                try? store.setSetting(.aiManualPasteCommand, chosen.pasteCommand)
                // The old result described the old command. A green tick left sitting under a
                // command that has just been replaced is the one way this pane can lie.
                result = nil
            }
        )
    }

    /// The stored row, plus the one thing typing has to do besides store itself: move the chooser to
    /// whatever the text now names, which for anything hand-written is "Something else".
    ///
    /// The text drives the chooser rather than the other way round, so the field stays editable and
    /// a typed command is never relabelled as a preset it does not match.
    private var commandBinding: Binding<String> {
        let row = SettingBinding(store: store, key: .aiLocalAgentRunCommand).binding($template)
        return Binding(
            get: { row.wrappedValue },
            set: { typed in
                row.wrappedValue = typed
                preset = AgentPreset.matching(runCommand: typed)
                // The verdict was about the command that was there before this keystroke. Left on
                // screen it reads as a verdict on the one now in the field, which is the one way
                // this pane can lie about whether a write-up will happen.
                result = nil
            }
        )
    }

    /// Runs the check off the main actor, and only draws its answer if it still applies.
    ///
    /// Off the main actor because the PATH resolution behind it spawns a login shell on its first
    /// call in the process — up to two seconds on a pathological rc file, which on the main actor is
    /// a beachball on the one control whose entire job is to reassure the user that something works.
    private func check() {
        result = nil
        checking = true
        let command = template
        Task {
            let outcome = await Task.detached { AIVerify.localAgent(template: command) }.value
            checking = false
            // The command moved on while the check ran — typed over, or replaced by picking an
            // agent. The sentence describes an argv that is no longer in the field, and drawn under
            // the new one it would read as a verdict on it.
            guard command == template else { return }
            result = outcome
        }
    }
}

/// Mode C's provider, and a real request to it when the button is pressed.
struct CloudProviderFields: View {
    let store: MeetingStore

    @State private var baseURL = ""
    @State private var model = ""
    @State private var keyRef = ""
    @State private var key = ""
    @State private var checking = false
    @State private var result: AIVerification?

    var body: some View {
        TextField("Base URL", text: SettingBinding(store: store, key: .aiCloudBaseURL).binding($baseURL))
            .onAppear {
                baseURL = loadSetting(store, .aiCloudBaseURL)
                model = loadSetting(store, .aiCloudModel)
                keyRef = loadSetting(store, .aiCloudKeyRef)
            }
        EgressWarning(key: .aiCloudBaseURL, value: baseURL)
        TextField("Model", text: SettingBinding(store: store, key: .aiCloudModel).binding($model))
        // Behind a disclosure, because it is a label the app can pick and almost nobody needs to.
        // It is the account attribute of the Keychain item, so there is no correct value to type
        // and no way for the user to know that from a text field sitting between two that do have
        // correct values. `saveKey` fills it in when it is blank; this is here for the one person
        // keeping several keys apart.
        DisclosureGroup("Keychain account") {
            TextField("Keychain account", text: SettingBinding(store: store, key: .aiCloudKeyRef).binding($keyRef))
                .labelsHidden()
            Text("The name your Keychain files this key under. Any name works.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SecureField("API key", text: $key)
            .onSubmit(saveKey)

        HStack(spacing: 10) {
            Button("Test the connection", action: check)
                .disabled(checking)
            if checking {
                ProgressView().controlSize(.small)
            }
        }

        if let result { VerifyResultLabel(result: result) }

        Text("""
            Your key is stored in the login Keychain, never in the database. Your transcript and \
            notes are sent to the provider above.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func check() {
        // A key typed and not submitted is not in the Keychain yet, and a test reporting "no API
        // key" with one plainly sitting in the field above it would be read as the test being
        // broken.
        saveKey()
        result = nil
        checking = true
        Task {
            let outcome = await AIVerify.cloud(store: store)
            checking = false
            result = outcome
        }
    }

    private func saveKey() {
        guard !key.isEmpty else { return }
        if keyRef.isEmpty {
            // A key with nothing to file it under is dropped on the floor, which reads as "I pasted
            // my key and Cloud still does not work". The account name is a label, so one can be
            // picked here; the user can rename it in the field above.
            keyRef = "cloud"
            try? store.setSetting(.aiCloudKeyRef, keyRef)
        }
        MeetingsKeychain.setSecret(key, account: keyRef)
        key = ""
    }
}

/// The outcome of a check, wherever it was pressed. The sentence is MeetingsCore's — this decides
/// only the colour and the glyph, so the wizard and Settings cannot word the same check two
/// different ways.
struct VerifyResultLabel: View {
    let result: AIVerification

    var body: some View {
        Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(result.ok
                ? AnyShapeStyle(Color(nsColor: .systemGreen))
                : AnyShapeStyle(Color(nsColor: .systemOrange)))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - Transcription

/// The same choice the setup wizard makes, changeable afterwards — including the two directions that
/// used to be dead ends: cloud back to local has to be able to run the download it skipped, and
/// local to cloud must not look like it silently threw the models away.
///
/// **There is no model picker, and nothing to measure.** ``LocalTranscriber`` resolves the one model
/// this Mac runs from the system's primary language, so the only question left here is where
/// transcription happens. What this pane used to ask instead was a choice between model sets, by
/// name and download size, which is a decision nobody outside this repo has the information to
/// make — and the fit check that existed to make it for them spent minutes of measurement answering
/// a question that no longer exists.
private struct TranscriptionSettings: View {
    let model: AppModel

    @State private var engine = TranscriptionEngineChoice.local
    @State private var modelsReady: Bool?
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var downloadProblem: String?

    var body: some View {
        Form {
            Section("Where transcription runs") {
                Picker("Engine", selection: engineBinding) {
                    Text("On this Mac").tag(TranscriptionEngineChoice.local)
                    Text("A service you set up").tag(TranscriptionEngineChoice.cloud)
                }
                .pickerStyle(.inline)
            }

            if engine == .local {
                Section("On this Mac") {
                    LabeledContent("Status") {
                        HStack(spacing: 10) {
                            Text(readinessLabel).foregroundStyle(.secondary)
                            Spacer()
                            if downloading {
                                ProgressView(value: progress).frame(width: 120)
                            } else if modelsReady == false {
                                // The one control that closes the cloud-to-local dead end: a store
                                // that skipped its download during setup has nothing on disk, and
                                // this is where it gets it.
                                Button("Download (\(LocalTranscriber.current.downloadSizeText))") {
                                    download()
                                }
                            }
                        }
                    }
                    if let downloadProblem {
                        Text(downloadProblem).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Your recordings stay on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if engine == .cloud {
                Section("The service") {
                    RemoteTranscriptionFields(store: model.store)
                }
                Section {
                    Label {
                        Text(cloudNote)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemBlue))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    // MARK: -

    /// Written through a binding rather than in an `onChange`, so the setting, the cached engine and
    /// the readiness label move together and the pane cannot draw a state the store is not in.
    private var engineBinding: Binding<TranscriptionEngineChoice> {
        Binding(get: { engine }, set: { choice in
            engine = choice
            try? model.store.setSetting(.transcribeBatchEngine, choice.rawValue)
            Task { await refreshEngine() }
        })
    }

    /// Two sentences, and which two depends on whether there is anything downloaded to reassure the
    /// user about. Both open with the fact that matters most, which is that their audio is uploaded.
    ///
    /// Switching away deletes nothing, and saying so is the point: a download silently thrown away
    /// by a picker would be unforgivable — and a user who assumes it *was* thrown away will not
    /// switch back. Neither, then: the files stay where they are and the pane says so.
    private var cloudNote: String {
        localModelsPresent
            ? "Your recordings are uploaded to that service. What is already downloaded here is "
                + "kept, so switching back needs no second download."
            : "Your recordings are uploaded to that service, and nothing is downloaded here. There "
                + "is also no live transcript while you talk."
    }

    private var localModelsPresent: Bool {
        StreamingFileEngine.modelsAreCached(LocalTranscriber.current.variant)
    }

    private var readinessLabel: String {
        switch modelsReady {
        case true: "Ready"
        case false: downloading ? "Downloading…" : "Not downloaded"
        case nil: "Checking…"
        }
    }

    private func load() async {
        engine = model.store.transcriptionEngine()
        modelsReady = await model.transcription.modelsReady()
        // Same reason as the wizard's step: this pane can be opened, closed and reopened while a
        // download runs, and its `downloading` flag dies with it. `prepareModels` joins the one in
        // flight rather than starting another, so rejoining is just calling it again.
        if await model.transcription.isPreparingModels { download() }
    }

    private func refreshEngine() async {
        await model.transcription.forgetResolvedEngine()
        modelsReady = await model.transcription.modelsReady()
    }

    private func download() {
        downloading = true
        downloadProblem = nil
        Task {
            do {
                try await model.transcription.prepareModels { value in
                    Task { @MainActor in progress = value }
                }
                modelsReady = await model.transcription.modelsReady()
            } catch {
                downloadProblem = "The download did not finish: \(error.localizedDescription)"
            }
            downloading = false
        }
    }
}

// MARK: - Vocabulary

/// The one rule about a term that the store does not enforce and the recogniser does.
///
/// `VocabularyBiasing` drops anything shorter than this before the CTC spotter is built, so a
/// stored two-letter term is a row this pane draws as active over a transcriber that has never
/// heard of it. Refused where it is typed instead, with the reason.
///
/// The number is repeated rather than imported because it lives on an actor internal to
/// MeetingsCore, which this unit does not own. `AppSourceGuardTests` reads the literal back out of
/// this file and fails if it ever stops matching `VocabularyBiasing.minimumTermLength`.
enum VocabularyRules {
    static let minimumTermLength = 3

    /// Why this term cannot be put in effect, or nil when it can.
    static func refusal(for term: String) -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count < minimumTermLength else { return nil }
        return "“\(trimmed)” is too short. Words under \(minimumTermLength) letters are ignored, "
            + "so add the longer word it appears in."
    }
}

/// Terms are global or folder-scoped, and auto-seeded ones are visibly marked and one click
/// to disable — because auto-seeding attendee names is the part most likely to go wrong, and a term
/// you cannot see is one you cannot fix.
private struct VocabularySettings: View {
    let model: AppModel

    @State private var terms: [VocabularyTerm] = []
    @State private var draft = ""
    @State private var scopeFolderID: String?
    /// Why the last Add was refused. Shown under the field rather than as an alert: the fix is to
    /// edit the text that is still sitting there.
    @State private var refusal: String?

    var body: some View {
        VStack(spacing: 0) {
            Table(visible) {
                TableColumn("Term") { term in
                    HStack(spacing: 6) {
                        Text(term.term)
                            .foregroundStyle(term.enabled ? .primary : .secondary)
                            .strikethrough(!term.enabled)
                        if term.source == .attendee {
                            Text("from attendees")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                }
                TableColumn("Scope") { term in
                    Text(term.folderID.flatMap { id in
                        model.folders.first { $0.id == id }?.name
                    } ?? "Global")
                    .foregroundStyle(.secondary)
                }
                TableColumn("") { term in
                    HStack(spacing: 4) {
                        Button(term.enabled ? "Disable" : "Enable") {
                            guard let id = term.id else { return }
                            _ = try? model.store.setVocabularyEnabled(id: id, !term.enabled)
                            reload()
                        }
                        // A word, not the bare trash glyph it used to be. This row deletes the term
                        // outright with no undo, and it sits a few pixels from Disable, which only
                        // parks it — an unlabelled icon beside a labelled one is how somebody
                        // meaning to disable a term destroys it instead.
                        Button("Remove") {
                            guard let id = term.id else { return }
                            _ = try? model.store.deleteVocabularyTerm(id: id)
                            reload()
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            // Alternating row backgrounds are right for a table that fills — Finder's list view —
            // and wrong for one holding five terms in a 400 pt pane, where the stripes carry on
            // past the last row as a stack of empty ones.
            .alternatingRowBackgrounds(.disabled)

            Divider()

            HStack(spacing: 8) {
                Picker("", selection: $scopeFolderID) {
                    Text("Global").tag(String?.none)
                    ForEach(model.folders) { folder in
                        Text(folder.name).tag(String?.some(folder.id))
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                TextField("Add a term", text: $draft)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, refusal == nil ? 12 : 4)
            // A term the recogniser will ignore is refused here rather than stored: a row in the
            // table above says the term is in effect, and for anything under three characters that
            // would be a lie the user has no way to see through.
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            // The one sentence the other three tabs all have and this one did not: what the list is
            // for, and where the rows you did not type came from.
            Text("""
                These spellings help the transcriber get names right. Names from your calendar \
                are added for you, and you can turn any of them off.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .onAppear(perform: reload)
    }

    /// Disabled terms stay in the list rather than disappearing — a soft-disable that hides the row
    /// is indistinguishable from a delete, and they stay visible on purpose.
    private var visible: [VocabularyTerm] {
        terms.sorted {
            ($0.folderID ?? "", $0.term.lowercased()) < ($1.folderID ?? "", $1.term.lowercased())
        }
    }

    private func reload() {
        terms = (try? model.store.allVocabularyTerms()) ?? []
    }

    private func add() {
        let term = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if let why = VocabularyRules.refusal(for: term) {
            refusal = why
            return
        }
        refusal = nil
        _ = try? model.store.addVocabularyTerm(
            VocabularyTerm(term: term, folderID: scopeFolderID, source: .manual)
        )
        draft = ""
        reload()
    }
}
