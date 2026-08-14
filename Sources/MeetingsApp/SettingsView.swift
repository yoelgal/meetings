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
private struct SettingBinding {
    let store: MeetingStore
    let key: SettingKey

    func binding(_ cache: Binding<String>) -> Binding<String> {
        Binding(
            get: { cache.wrappedValue },
            set: { new in
                cache.wrappedValue = new
                try? store.setSetting(key, new.isEmpty ? nil : new)
            }
        )
    }
}

@MainActor
private func loadSetting(_ store: MeetingStore, _ key: SettingKey) -> String {
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
                    Every meeting with a link in that window gets a row, so you can write pre-notes \
                    before it starts. `meetings upcoming` uses the same window.
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
                    `0` keeps every recording forever. Only the WAV files are deleted. \
                    Transcripts and notes are kept.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Floating notes panel") {
                Toggle("Hide the notes panel from screen sharing", isOn: $model.notesPanelHiddenFromCapture)
                Text("On, the panel is invisible to Zoom, Meet, Teams and anything else that "
                    + "records the screen. It also disappears from your own screenshots, screen "
                    + "recordings and Mission Control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Keep the notes panel above other apps", isOn: $model.notesPanelFloats)
                Text("On, the panel stays on top of other windows, including full-screen ones. "
                    + "Off, it behaves like an ordinary window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Updates") {
                Toggle("Check GitHub for new releases", isOn: $model.updateCheckEnabled)
                Text("On, Meetings asks once a day whether a newer release is tagged, and says so "
                    + "at the foot of the sidebar. It sends nothing about you and nothing about "
                    + "your meetings. This is the only request the app makes that you did not ask "
                    + "for by setting up a cloud mode.")
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
                Text("Symlinks the CLI inside Meetings.app to /usr/local/bin, so your agent can "
                    + "use it from any directory.")
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
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section("How meetings get written up") {
                Picker("Mode", selection: modeBinding) {
                    Text("Manual (you drive your own agent)").tag(AIMode.manual)
                    if showAdvanced || mode != .manual {
                        Text("Local agent (runs a command when a meeting is ready)").tag(AIMode.localAgent)
                        Text("Cloud (an API writes the summary)").tag(AIMode.cloud)
                    }
                }
                .pickerStyle(.inline)
                if !showAdvanced, mode == .manual {
                    Button("Advanced modes…") { showAdvanced = true }
                }
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Each command in front of the mode that uses it. They were one section over one
            // setting, and one value cannot be both a slash command to paste and a binary to exec.
            Section("Your own agent session") {
                ManualPasteCommandFields(store: model.store)
            }

            if showAdvanced || mode == .localAgent {
                Section("Local agent") {
                    LocalAgentCommandFields(store: model.store)
                }
            }

            if showAdvanced || mode == .cloud {
                Section("Cloud provider") {
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
            "Nothing fires on its own. A finished meeting waits under Needs write-up until you ask "
                + "your own agent to write it."
        case .localAgent:
            "When a meeting reaches Needs write-up, Meetings runs the command below in the "
                + "background, without asking. Whether the transcript leaves this Mac depends on "
                + "the command you set."
        case .cloud:
            "When a meeting reaches Needs write-up, its transcript and your notes are sent to the "
                + "provider below and the summary it returns is saved."
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
            Offered by the Copy button on a meeting that needs writing up, with `{meeting_id}` \
            substituted. Meetings never runs it.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Mode B's one setting and its check.
///
/// The wizard's fourth page and Settings ▸ AI both draw *this* view, so there is one field bound to
/// one settings row. Two sets of fields over the same row is how the wizard and Settings come to
/// disagree about what is configured.
struct LocalAgentCommandFields: View {
    let store: MeetingStore

    @State private var template = ""
    @State private var result: AIVerification?

    var body: some View {
        TextField(
            "Command to run",
            text: SettingBinding(store: store, key: .aiLocalAgentRunCommand).binding($template)
        )
        .font(.callout.monospaced())
        .onAppear { template = loadSetting(store, .aiLocalAgentRunCommand) }

        // Named for what it does rather than "Verify": the check resolves a binary and stops, and a
        // button promising verification would be promising more than the sentence underneath it can
        // deliver.
        Button("Check the command") {
            result = AIVerify.localAgent(template: template)
        }

        if let result { VerifyResultLabel(result: result) }

        Text("""
            The first word has to be a real command on your PATH. `{meeting_id}` is substituted and \
            `MEETINGS_DB` is exported. It runs directly, without a shell.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        TextField("Model", text: SettingBinding(store: store, key: .aiCloudModel).binding($model))
        // Behind a disclosure, because it is a label the app can pick and almost nobody needs to.
        // It is the account attribute of the Keychain item, so there is no correct value to type
        // and no way for the user to know that from a text field sitting between two that do have
        // correct values. `saveKey` fills it in when it is blank; this is here for the one person
        // keeping several keys apart.
        DisclosureGroup("Keychain account") {
            TextField("Keychain account", text: SettingBinding(store: store, key: .aiCloudKeyRef).binding($keyRef))
                .labelsHidden()
            Text("The name this key is filed under in your Keychain. Any name works. Left blank, "
                + "Meetings uses \"cloud\".")
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

        Text("The key goes to the login Keychain under service com.yoelgal.Meetings. "
            + "The settings table stores only the account name. The transcript and your notes "
            + "are sent to the provider above.")
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

private struct TranscriptionSettings: View {
    let model: AppModel

    @State private var engine = ""
    @State private var remoteBaseURL = ""
    @State private var remoteModel = ""
    @State private var remoteKeyRef = ""
    @State private var remoteKey = ""
    @State private var modelsReady: Bool?
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var downloadProblem: String?

    var body: some View {
        Form {
            Section("On-device model") {
                LabeledContent("Parakeet TDT v3") {
                    HStack(spacing: 10) {
                        Text(modelLabel).foregroundStyle(.secondary)
                        Spacer()
                        if downloading {
                            ProgressView(value: progress).frame(width: 120)
                        } else if modelsReady == false {
                            Button("Download") { download() }
                        }
                    }
                }
                if let downloadProblem {
                    Text(downloadProblem).font(.caption).foregroundStyle(.secondary)
                }
                Text("About 600 MB, downloaded once. Everything after that runs on this Mac with "
                    + "no network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Batch engine") {
                Picker("Final pass", selection: SettingBinding(store: model.store, key: .transcribeBatchEngine).binding($engine)) {
                    Text("On this Mac (Parakeet)").tag("fluidaudio")
                    Text("Remote OpenAI-compatible endpoint").tag("remote")
                }
                Text("The live pass during a meeting is always on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if engine == "remote" {
                Section("Remote endpoint") {
                    TextField("Base URL", text: SettingBinding(store: model.store, key: .transcribeRemoteBaseURL).binding($remoteBaseURL))
                    TextField("Model", text: SettingBinding(store: model.store, key: .transcribeRemoteModel).binding($remoteModel))
                    SecureField("API key", text: $remoteKey)
                        .onSubmit(saveRemoteKey)
                    // Same disclosure and the same reason as the cloud one: an account name is a
                    // label with no correct value, and it does not belong between two fields that
                    // have one.
                    DisclosureGroup("Keychain account") {
                        TextField(
                            "Keychain account",
                            text: SettingBinding(store: model.store, key: .transcribeRemoteKeyRef)
                                .binding($remoteKeyRef)
                        )
                        .labelsHidden()
                        Text("The name this key is filed under in your Keychain. Any name works. "
                            + "Left blank, Meetings uses \"transcribe\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            engine = loadSetting(model.store, .transcribeBatchEngine)
            remoteBaseURL = loadSetting(model.store, .transcribeRemoteBaseURL)
            remoteModel = loadSetting(model.store, .transcribeRemoteModel)
            remoteKeyRef = loadSetting(model.store, .transcribeRemoteKeyRef)
            modelsReady = await model.transcription.modelsReady()
            // Same reason as the wizard's step: this pane can be opened, closed and reopened while a
            // download runs, and its `downloading` flag dies with it. `prepareModels` joins the one
            // in flight rather than starting another, so rejoining is just calling it again.
            if await model.transcription.isPreparingModels { download() }
        }
    }

    /// The same rule the cloud key follows. Before this, a key typed with the account field left
    /// blank was dropped on the floor: the field cleared, nothing was written, and the endpoint went
    /// on reporting no key. Silently discarding a pasted API key is the worst of the options here,
    /// and the account name is a label, so one can be picked.
    private func saveRemoteKey() {
        guard !remoteKey.isEmpty else { return }
        if remoteKeyRef.isEmpty {
            remoteKeyRef = "transcribe"
            try? model.store.setSetting(.transcribeRemoteKeyRef, remoteKeyRef)
        }
        MeetingsKeychain.setSecret(remoteKey, account: remoteKeyRef)
        remoteKey = ""
    }

    private var modelLabel: String {
        switch modelsReady {
        case true: "Ready"
        case false: downloading ? "Downloading…" : "Not downloaded"
        case nil: "Checking…"
        }
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
                downloadProblem = "The model could not be downloaded: \(error.localizedDescription)"
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
        return "“\(trimmed)” is too short. The recogniser ignores any term under "
            + "\(minimumTermLength) characters. Add the longer word it appears in instead."
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
            Text("Terms bias the transcriber toward the spelling you want. Attendee names from "
                + "your calendar are added automatically and can be turned off here.")
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
