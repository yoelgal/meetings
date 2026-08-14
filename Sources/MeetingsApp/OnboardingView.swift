import AppKit
import MeetingsCore
import SwiftUI

/// The setup wizard: permissions → model download → AI mode → CLI install. Skippable, and
/// every step is reachable from Settings afterwards, so nothing here is a gate.
///
/// The shape follows the macOS 26 "What's New" pattern: one big bold title, a column
/// of icon + heading + one-sentence rows, one prominent button at the bottom.
struct OnboardingView: View {
    let model: AppModel
    /// A screenshot seam only — see `Appearance.panel`. Nil in every real launch.
    var initialStep: String?
    let finish: () -> Void

    @State private var step = OnboardingView.resumedStep()

    /// Set by the model step when transcription is pointed at a remote endpoint that has not been
    /// proved to work. It holds Continue on that one step, and on that one condition.
    ///
    /// Every other step here is skippable and stays skippable — a permission ungranted or a model
    /// undownloaded announces itself the moment it matters, loudly, in the app. A wrong API key does
    /// not: it fails after the first real meeting, with the audio already recorded, and the only
    /// cheap moment to catch it is this one. Hence a gate here and nowhere else, and hence
    /// ``verifyRequested`` rather than a locked door — "Skip setup" still works, and one failed
    /// verification puts a way past it on screen.
    @State private var remoteUnverified = false
    /// Bumped to ask the model step to run its verification now.
    @State private var verifyRequested = 0
    @State private var allowUnverified = false

    /// The size the wizard was designed at, and the shape it is cut to.
    /// Not private: the window scene opens at this size on a first run, so the wizard is never
    /// watched resizing into place.
    static let card = CGSize(width: 620, height: 580)
    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    /// Where the wizard had got to, in UserDefaults rather than the settings table: it is progress
    /// through a screen, not something the CLI or an agent has any business reading or setting.
    ///
    /// It is remembered because this wizard is interrupted *by design*. Granting Screen Recording
    /// ends with macOS quitting and reopening the app — that relaunch is the only way a running
    /// process picks the grant up — and coming back to page one, three pages behind the permission
    /// you just granted, reads as the grant having been thrown away.
    private static let stepKey = "onboarding.step"

    private static func resumedStep() -> Step {
        Step(rawValue: UserDefaults.standard.integer(forKey: stepKey)) ?? .welcome
    }

    enum Step: Int, CaseIterable {
        case welcome, permissions, model, mode, cli

        var next: Step? { Step(rawValue: rawValue + 1) }
        var previous: Step? { Step(rawValue: rawValue - 1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(title)
                        // A text style rather than a point size, so the wizard tracks Dynamic Type.
                        .font(.largeTitle.weight(.bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    content
                }
                .padding(.horizontal, 40)
                .padding(.top, 44)
                .padding(.bottom, 24)
            }

            Divider()

            HStack(spacing: 12) {
                // Skippable at every step, and it says so. A wizard you cannot leave is a wizard
                // people quit the app to escape.
                // Same reason as "Show the other two modes": grey plain text is what this app's
                // captions look like, and the one way out of the wizard has to look like a way out.
                Button("Skip setup", action: complete)
                    .buttonStyle(.link)
                if gating, allowUnverified {
                    Button("Continue without verifying") {
                        withAnimation { step = step.next ?? step }
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                // Only once there is something behind you. A Back button greyed out on page one is
                // a control that spends its first impression telling you it does not work.
                if let previous = step.previous {
                    Button("Back") { withAnimation { step = previous } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        // Nothing here is committed by moving between pages: permissions are
                        // granted by their own buttons, the download runs where it runs, and the
                        // mode is a stored setting. Going back re-reads, it does not undo.
                        .keyboardShortcut("[", modifiers: .command)
                }
                Text("\(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button(gating ? "Verify and continue" : (step.next == nil ? "Start using Meetings" : "Continue")) {
                    if gating {
                        allowUnverified = true
                        verifyRequested += 1
                    } else if let next = step.next {
                        withAnimation { step = next }
                    } else {
                        complete()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
        }
        .frame(width: Self.card.width, height: Self.card.height)
        .background(WizardWindowSize(size: Self.card))
        .onAppear {
            if let initialStep, let index = Int(initialStep), let parsed = Step(rawValue: index) {
                step = parsed
            }
        }
        .onChange(of: step) { _, moved in
            UserDefaults.standard.set(moved.rawValue, forKey: Self.stepKey)
        }
    }

    /// The one condition Continue is held on: the model step, a remote endpoint, nothing proven yet.
    private var gating: Bool { step == .model && remoteUnverified }

    private var title: String {
        switch step {
        case .welcome: "Welcome to Meetings"
        case .permissions: "Three permissions"
        case .model: "The transcriber"
        case .mode: "Who writes the summary"
        case .cli: "The command line tool"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .model:
            ModelStep(model: model, unverified: $remoteUnverified, verifyRequested: verifyRequested) {
                withAnimation { step = step.next ?? step }
            }
        case .mode: ModeStep(model: model)
        case .cli: CLIStep()
        }
    }

    private func complete() {
        try? model.store.setSetting(.onboardingCompleted, "true")
        // Finished or skipped, the resume point is spent. Left behind, "Show the setup guide again"
        // would open on whichever page the wizard happened to end on.
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        finish()
        // Hand the window back the way it was found. The app behind the wizard is not a fixed size
        // and would otherwise open into the wizard's footprint.
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
            window.styleMask.insert(.resizable)
            window.setContentSize(MeetingsApp.defaultWindowSize)
            window.center()
        }
    }
}

/// Holds the window at the wizard's size for as long as the wizard is on screen.
///
/// The wizard is a fixed 620×580 and the window is not. On an ordinary window that takes care of
/// itself — SwiftUI shrinks the frame to the content. Full screen is where it falls apart: the
/// window cannot shrink, so the wizard ends up a small panel marooned in the middle of the display
/// with a field of empty background around it. Leaving full screen is the only fix; there is no
/// size a full-screen window can be.
private struct WizardWindowSize: NSViewRepresentable {
    let size: CGSize

    /// Owns the full-screen observer so it is torn down with the wizard rather than leaked.
    final class Coordinator {
        var token: (any NSObjectProtocol)?

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        let coordinator = context.coordinator
        // The view has no window until it is in the hierarchy, which is one runloop turn away.
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            guard window.styleMask.contains(.fullScreen) else { return resize(window) }

            // Resizing during the full-screen animation is thrown away, so wait for the window to
            // actually be back before touching its size.
            coordinator.token = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { _ in resize(window) }
            window.toggleFullScreen(nil)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Non-resizable while the wizard is up: every step is laid out at exactly this size, and a
    /// window the user can drag wider than its only content is a window that looks broken.
    private func resize(_ window: NSWindow) {
        window.setContentSize(size)
        window.styleMask.remove(.resizable)
        window.center()
    }
}

/// The icon + heading + one sentence row the whole wizard is built out of.
private struct FeatureRow: View {
    let symbol: String
    let heading: String
    let detail: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            FeatureRow(
                symbol: "waveform.badge.mic",
                heading: "Records both sides, separately",
                detail: "Your microphone and your Mac's audio are captured as two tracks, so the "
                    + "transcript can tell you apart from everyone else."
            )
            FeatureRow(
                symbol: "cpu",
                heading: "Transcribes on this Mac",
                detail: "Live while you talk, then a more accurate pass when you stop. No account "
                    + "and no upload."
            )
            FeatureRow(
                symbol: "square.and.pencil",
                heading: "Your notes steer the write-up",
                detail: "Notes you type during a meeting anchor to that moment in the transcript, "
                    + "and the summary is written around them."
            )
            FeatureRow(
                symbol: "terminal",
                heading: "Your own agent does the writing",
                detail: "Meetings has no prompts of its own. A command line tool hands the "
                    + "transcript to the agent you already use."
            )
        }
    }
}

private struct PermissionsStep: View {
    @State private var statuses: [Permission: PermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Nothing is asked for until you press the button next to it. Meetings still "
                + "works without them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Permission.allCases) { permission in
                PermissionRow(
                    permission: permission,
                    status: statuses[permission] ?? permission.status
                ) { statuses[permission] = $0 }
                Divider()
            }

            // Before they grant anything, because "you will be asked for these again after every
            // update" changes how the next three buttons feel, and finding out a week later does
            // not.
            if CodeSignature.isAdHoc { AdHocSigningNotice() }

            // A real risk, this one: the OS dialog says "screen recording" for what is
            // audio-only, and people reasonably refuse it. Explaining it before the dialog appears
            // is the mitigation, so it gets its own line rather than a footnote.
            Label {
                Text("""
                    macOS calls system-audio capture **Screen Recording**. Meetings never records \
                    your screen. The screen-capture API is the only way Apple exposes system audio.
                    """)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemBlue))
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10, style: .continuous))
        }
        .onAppear { statuses = Permission.snapshot() }
        .refreshingPermissions(into: $statuses)
    }
}

/// Choosing where transcription runs, and on what.
///
/// The shape is deliberate: the app measures what actually runs well on *this* Mac and presents that
/// as the answer, and the list underneath is the override. A picker of equal-looking options makes
/// the user do work the machine can do — and the safest option is not the best one on most machines.
private struct ModelStep: View {
    let model: AppModel
    /// True while transcription is pointed at a remote endpoint nothing has proved works. Read by
    /// the wizard's footer.
    @Binding var unverified: Bool
    /// A counter the wizard bumps to mean "run the verification now".
    let verifyRequested: Int
    /// Called when a verification passes, so Continue does not need a second press.
    let advance: () -> Void

    @State private var engine = TranscriptionEngineChoice.local
    @State private var selected = LocalTranscriptionOption.fallback
    @State private var record: FitRecord?
    @State private var fitStage: FitStage?
    @State private var fitting = false
    @State private var showAllModels = false

    @State private var ready: Bool?
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Both choices first, then the panel belonging to whichever is selected — unlike the
            // mode step, which can afford a panel tucked under each of its cards.
            //
            // The panels here are not the same size. "On this Mac" carries the fit check, the model
            // rows and the download state: about 350 pt, against a 620x580 wizard whose scroll
            // viewport is roughly 515 pt once the footer is out. With the cloud card sitting under
            // all of that it began around 575 pt down — past the bottom edge, and macOS hides the
            // scrollbar until something scrolls, so it was not below the fold so much as absent.
            // The step read as offering one engine.
            EngineCard(
                title: "On this Mac",
                detail: "Audio never leaves the machine. One download, then transcription needs no "
                    + "network and no account.",
                badge: "Recommended",
                selected: engine == .local
            ) { select(.local) }

            EngineCard(
                title: "A transcription service",
                detail: "Nothing is downloaded. The audio of every meeting is uploaded to the "
                    + "endpoint you configure, and transcribed there.",
                badge: nil,
                selected: engine == .cloud
            ) { select(.cloud) }

            switch engine {
            case .local:
                localBody
            case .cloud:
                ConfigurationPanel {
                    RemoteTranscriptionFields(
                        store: model.store,
                        verifyRequested: verifyRequested
                    ) { outcome in
                        unverified = !(outcome?.ok ?? false)
                        if outcome?.ok == true { advance() }
                    }
                }
            }
        }
        .task { await load() }
        .onDisappear { unverified = false }
    }

    // MARK: - Local

    @ViewBuilder
    private var localBody: some View {
        ConfigurationPanel {
            if let record {
                FitResultRow(record: record)
            } else if fitting {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(fitStage.map(FitCheck.sentence) ?? "Checking what runs best on your Mac…")
                        .font(.callout)
                    Text("It downloads one model and runs it here, on two channels at once, the way "
                        + "a real meeting does. Up to \(Int(FitRunner.defaultCap / 60)) minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Check what runs best on this Mac") { runFit() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Text("Downloads one model and measures it here rather than guessing from the "
                        + "spec sheet. Up to \(Int(FitRunner.defaultCap / 60)) minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            if showAllModels || record == nil {
                ForEach(LocalTranscriptionOption.all) { option in
                    ModelRow(option: option, record: record, selected: option.id == selected.id) {
                        choose(option)
                    }
                }
            } else {
                Button {
                    withAnimation { showAllModels = true }
                } label: {
                    Label("Choose a different model", systemImage: "chevron.down")
                }
                .buttonStyle(.link)
            }

            Divider()
            downloadState
        }
    }

    @ViewBuilder
    private var downloadState: some View {
        switch (ready, downloading) {
        case (true, _):
            Label(
                selected.runsSeparateBatchPass
                    ? "Both models are on this Mac and ready"
                    : "The model is on this Mac and ready",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemGreen))
        case (_, true):
            ProgressView(value: progress) {
                Text("Downloading \(selected.title) — \(selected.downloadSizeText)")
            } currentValueLabel: {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
        default:
            Button("Download \(selected.downloadSizeText) now") { download() }
                .buttonStyle(.bordered)
                .controlSize(.large)
            // The old copy read "you can skip this and still record", which is true and
            // misleading in the same breath. Recording works; nothing downstream of it does.
            // No transcript means no search, and no summary, because there is nothing for an
            // agent to write one from. Someone deciding whether to wait should be told what
            // they are trading, not reassured.
            Text("Without it you get audio and nothing else: no transcript, no search, and no "
                + "write-up, since there is nothing for your agent to read. You can download "
                + "later from Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(Color(nsColor: .systemRed))
        }
    }

    // MARK: -

    private func load() async {
        engine = model.store.transcriptionEngine()
        unverified = engine == .cloud
        selected = model.store.localTranscriptionOption()
        record = model.store.fitRecord()
        ready = await model.transcription.modelsReady()
        // Leaving this step tears the view down and takes `downloading` and `progress` with it,
        // while the download itself carries on. Coming back therefore offered a Download button
        // for a download already running, and pressing it used to start a second one.
        //
        // Rejoining is now the same call: `prepareModels` attaches to the download in flight
        // rather than starting one, so this needs no separate resume path.
        if await model.transcription.isPreparingModels { download() }
    }

    private func select(_ choice: TranscriptionEngineChoice) {
        engine = choice
        // Choosing the endpoint arms the gate; choosing local disarms it. Picking cloud and then
        // changing your mind must not leave Continue held on a verification for an engine that is
        // no longer selected.
        unverified = choice == .cloud
        try? model.store.setSetting(.transcribeBatchEngine, choice.rawValue)
        // The service caches the engine it resolved on first use, and that cache outlives this
        // press. Without dropping it, switching here and recording in the same launch would still
        // run the previous engine.
        Task {
            await model.transcription.forgetResolvedEngine()
            ready = await model.transcription.modelsReady()
        }
    }

    private func choose(_ option: LocalTranscriptionOption) {
        selected = option
        try? model.store.setSetting(.transcribeLocalModel, option.id)
        Task {
            await model.transcription.forgetResolvedEngine()
            ready = await model.transcription.modelsReady()
        }
    }

    private func runFit() {
        fitting = true
        problem = nil
        Task {
            let outcome = await FitCheck.run(store: model.store) { stage in
                Task { @MainActor in fitStage = stage }
            }
            record = outcome
            selected = outcome.chosen
            engine = .local
            await model.transcription.forgetResolvedEngine()
            ready = await model.transcription.modelsReady()
            fitting = false
        }
    }

    private func download() {
        downloading = true
        problem = nil
        Task {
            do {
                try await model.transcription.prepareModels { value in
                    Task { @MainActor in progress = value }
                }
                ready = await model.transcription.modelsReady()
            } catch {
                problem = "The download failed: \(error.localizedDescription)"
            }
            downloading = false
        }
    }
}

/// What `fit` decided, with the numbers that decided it — or, when it could not measure, that fact
/// in the same place and the same size.
struct FitResultRow: View {
    let record: FitRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(record.verified
                    ? AnyShapeStyle(Color(nsColor: .systemGreen))
                    : AnyShapeStyle(Color(nsColor: .systemOrange)))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.chosen.title).font(.headline)
                Text(record.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(record.machine.summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// One model set in the picker: what it is, what it costs, and the numbers if anyone has measured
/// it. A tier nobody has measured shows no numbers rather than plausible ones.
struct ModelRow: View {
    let option: LocalTranscriptionOption
    /// What `fit` last measured on this Mac, if it has run. It outranks the shipped claim — see
    /// ``LocalTranscriptionOption/performanceLine(measuredBy:)``.
    let record: FitRecord?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(option.title).font(.headline)
                        Text(option.downloadSizeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(option.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Live: \(option.liveModel) · Final: \(option.finalModel) · \(option.languages)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let line = option.performanceLine(measuredBy: record) {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The engine cards, drawn like the AI mode cards on the next step — same control, same meaning.
private struct EngineCard: View {
    let title: String
    let detail: String
    let badge: String?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        ModeCard(title: title, detail: detail, badge: badge, selected: selected, select: select)
    }
}

private struct ModeStep: View {
    let model: AppModel

    @State private var mode = AIMode.manual
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModeCard(
                title: "Manual",
                detail: "Nothing runs on its own. Finished meetings collect under Needs write-up, "
                    + "and you ask your own agent to write them when you are ready.",
                badge: "Recommended",
                selected: mode == .manual
            ) { select(.manual) }

            // Already on an advanced mode when the wizard reopens: showing only the Manual card, and
            // showing it unselected, would say the chosen mode had been thrown away.
            if showAdvanced || mode != .manual {
                // The second sentence is not a caveat, it is the fact of the mode: the shipped
                // default template is `claude -p`, which hands the whole transcript to a hosted
                // agent. Leaving that as an absence, under a Cloud card that used to claim it was
                // the only mode that sent anything anywhere, actively misled anyone picking this
                // one to keep their data on their own machine.
                ModeCard(
                    title: "Local agent",
                    detail: "Meetings runs your agent command in the background as soon as a "
                        + "meeting is transcribed, without asking. Whether the transcript leaves "
                        + "this Mac depends on the command you set.",
                    badge: nil,
                    selected: mode == .localAgent
                ) { select(.localAgent) }

                // Each mode's own settings, under the option that needs them. Chosen here rather
                // than deferred to Settings because a mode picked and left unconfigured does
                // nothing at all, silently, at the end of the next meeting.
                if mode == .localAgent {
                    ConfigurationPanel { LocalAgentCommandFields(store: model.store) }
                }

                ModeCard(
                    title: "Cloud",
                    detail: "A provider you configure writes the summary. The transcript and your "
                        + "notes are sent to that provider.",
                    badge: nil,
                    selected: mode == .cloud
                ) { select(.cloud) }

                if mode == .cloud {
                    ConfigurationPanel { CloudProviderFields(store: model.store) }
                }
            } else {
                // A control, drawn as one. `.buttonStyle(.plain).foregroundStyle(.secondary)` is
                // exactly how this app draws static explanatory text, so the one thing on this
                // step that reveals the other two modes was indistinguishable from a caption.
                Button {
                    withAnimation { showAdvanced = true }
                } label: {
                    Label("Show the other two modes", systemImage: "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .onAppear { mode = AIMode(stored: loadMode()) }
    }

    private func loadMode() -> String {
        ((try? model.store.setting(.aiMode)) ?? nil) ?? AIMode.manual.rawValue
    }

    private func select(_ new: AIMode) {
        mode = new
        try? model.store.setSetting(.aiMode, new.rawValue)
    }
}

/// The fields a chosen mode needs, in the shape this wizard already uses for the one panel on a page
/// that reports or asks for something — the model download's box and the CLI step's box.
///
/// The rounded border is applied here rather than in the fields themselves: in Settings they are
/// rows of a grouped `Form`, which styles them, and outside one they would otherwise draw as bare
/// underlined text.
private struct ConfigurationPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

private struct ModeCard: View {
    let title: String
    let detail: String
    let badge: String?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.18), in: .capsule)
                        }
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? AnyShapeStyle(.tint.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.35)),
                in: .rect(cornerRadius: 10, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct CLIStep: View {
    @State private var status = CLIInstall.status()
    @State private var problem: String?
    /// Where the skill actually landed. The row above promises this happens on launch, and a
    /// promise about a file written somewhere you cannot see is worth naming the path for.
    @State private var skillTargets: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            FeatureRow(
                symbol: "link",
                heading: "meetings, on your PATH",
                detail: "Links the tool inside Meetings.app to /usr/local/bin, so your agent can "
                    + "reach your meetings from any directory."
            )
            FeatureRow(
                symbol: "sparkles",
                heading: "A skill for your agent",
                detail: "Meetings installs an agent skill on launch, so \"add some notes to my "
                    + "call with Will tomorrow\" works straight away."
            )

            VStack(alignment: .leading, spacing: 10) {
                Label(status.label, systemImage: isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isInstalled ? AnyShapeStyle(Color(nsColor: .systemGreen)) : AnyShapeStyle(.secondary))
                if !isInstalled {
                    Button("Install the command line tool") {
                        Task {
                            problem = await CLIInstall.install()
                            status = CLIInstall.status()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                if let problem {
                    Text(problem)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                ForEach(skillTargets, id: \.self) { target in
                    Label(target, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .textSelection(.enabled)
                }
                if skillTargets.isEmpty {
                    Label(
                        "No agent tool found on this Mac, so there is nowhere to put the skill yet.",
                        systemImage: "circle.dashed"
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10, style: .continuous))
        }
        // Reports where launch put it; never installs. Pressing Continue is not consent to write
        // into another tool's configuration — the launch write is, and it has already happened.
        .task {
            skillTargets = SkillInstall.targets()
                .filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
                .map { "Skill installed for \($0.tool) at \($0.fileURL.path)" }
        }
    }

    private var isInstalled: Bool {
        if case .installed = status { return true }
        return false
    }
}
