import AppKit
import MeetingsCore
import SwiftUI

/// The setup wizard: permissions → the transcriber → who writes the summary → the CLI. Skippable,
/// and every step is reachable from Settings afterwards, so nothing here is a gate.
///
/// The shape follows the macOS 26 "What's New" pattern: one big bold title, a column
/// of icon + heading + one-sentence rows, one prominent button at the bottom.
///
/// The governing constraint on every page is *presses*. Anything the machine can decide, the
/// machine decides and shows as already chosen: the transcriber has no model list, the mode step
/// arrives on the recommended mode with the agent this Mac actually has already filled in, and a
/// cloud key typed once is carried across rather than typed twice. What is left for the user is
/// the handful of decisions only they can make.
struct OnboardingView: View {
    let model: AppModel
    /// A screenshot seam only — see `Appearance.panel`. Nil in every real launch.
    var initialStep: String?
    let finish: () -> Void

    @State private var step = OnboardingView.resumedStep()

    /// Set by the transcriber step when transcription is pointed at a remote endpoint that has not
    /// been proved to work. It holds Continue on that one step, and on that one condition.
    ///
    /// Every other step here is skippable and stays skippable — a permission ungranted or a model
    /// undownloaded announces itself the moment it matters, loudly, in the app. A wrong API key does
    /// not: it fails after the first real meeting, with the audio already recorded, and the only
    /// cheap moment to catch it is this one. Hence a gate here and nowhere else, and hence
    /// ``verifyRequested`` rather than a locked door — "Skip setup" still works, and one failed
    /// verification puts a way past it on screen.
    @State private var remoteUnverified = false
    /// Bumped to ask the transcriber step to run its verification now.
    @State private var verifyRequested = 0
    @State private var allowUnverified = false
    /// True from the moment the user presses Download until that download settles, whether it
    /// succeeds or fails.
    ///
    /// It lives up here rather than inside the step because the footer is what has to react to it,
    /// and it is written through a `Binding` rather than kept as the step's own `@State` for a
    /// second reason: leaving the step tears the step down while the download carries on, and a
    /// binding's storage outlives that teardown, so the completion still lands somewhere real
    /// instead of on a discarded copy of a view.
    @State private var downloadRunning = false

    /// The size the wizard was designed at. Every step is laid out against it.
    /// Not private: the window scene opens at this size on a first run, so the wizard is never
    /// watched resizing into place.
    static let card = CGSize(width: 620, height: 580)

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
                // people quit the app to escape. Drawn as a link rather than a caption because grey
                // plain text is what this app's captions look like, and the one way out of the
                // wizard has to look like a way out.
                Button("Skip setup", action: complete)
                    .buttonStyle(.link)
                if hold == .unverifiedEndpoint, allowUnverified {
                    Button("Continue without verifying") {
                        withAnimation { step = step.next ?? step }
                    }
                    .buttonStyle(.link)
                } else if hold == .downloadRunning {
                    // A dead Continue with nothing next to it reads as a bug. One line saying what
                    // it is waiting for turns the same disabled button into a progress report.
                    Text("Continue once the download finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Button(continueTitle) {
                    if hold == .unverifiedEndpoint {
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
                .disabled(hold == .downloadRunning)
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

    /// The two things that can hold Continue, both of them on the transcriber step.
    ///
    /// An enum rather than one Bool because the two holds are not the same shape and must not be
    /// offered the same escape. A download in flight is a **wait**: it finishes by itself in under a
    /// minute, so the only honest control is a Continue that is briefly dead. An unverified endpoint
    /// is a **judgement**: nothing resolves it but a request that can legitimately fail — a VPN that
    /// is not up yet — so it gets a verify action and, after one attempt, a way past.
    ///
    /// Collapsing them into a single `gating` Bool, which is what this replaces, went wrong in both
    /// directions. The download would have inherited "Continue without verifying", handing the user
    /// a link past a download the app is halfway through; and either condition arming overwrote the
    /// other, so switching to the service card mid-download turned a plain wait into a verify
    /// prompt, and switching back turned a failed verification into no hold at all.
    private enum Hold {
        case downloadRunning, unverifiedEndpoint
    }

    private var hold: Hold? {
        guard step == .model else { return nil }
        // The download outranks the endpoint deliberately: it is the shorter wait and it has no
        // escape hatch to offer, which is precisely what stops an in-flight download borrowing one.
        // When it settles this falls through to the endpoint, so neither hold is lost.
        if downloadRunning { return .downloadRunning }
        if remoteUnverified { return .unverifiedEndpoint }
        return nil
    }

    private var continueTitle: String {
        if hold == .unverifiedEndpoint { return "Verify and continue" }
        return step.next == nil ? "Start using Meetings" : "Continue"
    }

    private var title: String {
        switch step {
        case .welcome: "Welcome to Meetings"
        case .permissions: "Three things to allow"
        case .model: "Transcribing your meetings"
        case .mode: "Who writes the summary"
        case .cli: "Connecting your agent"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .model:
            TranscriberStep(
                model: model,
                unverified: $remoteUnverified,
                downloading: $downloadRunning,
                verifyRequested: verifyRequested
            ) {
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
                detail: "Your mic and your Mac's audio are kept as two tracks, so the transcript "
                    + "can tell you apart from everyone else."
            )
            FeatureRow(
                symbol: "cpu",
                heading: "Transcribes on this Mac",
                detail: "As you talk, with no account and nothing uploaded."
            )
            FeatureRow(
                symbol: "square.and.pencil",
                heading: "Your notes steer the write-up",
                detail: "Notes you type stick to that moment in the transcript, and the summary is "
                    + "written around them."
            )
            FeatureRow(
                symbol: "terminal",
                heading: "Your own agent writes it",
                detail: "Meetings has no prompts of its own. It hands the transcript to the agent "
                    + "you already use."
            )
        }
    }
}

private struct PermissionsStep: View {
    @State private var statuses: [Permission: PermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Nothing is asked for until you press its button. Meetings still works without "
                + "them.")
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
            // is the mitigation, so it keeps its own line rather than becoming a footnote — and the
            // fact survives the shortening even though the paragraph did not.
            //
            // One string literal, not two joined with `+`. A concatenation is an expression, so
            // SwiftUI never sees a `LocalizedStringKey` and the `**` renders as two literal
            // asterisks — see `MarkdownLiteralTests`.
            Label {
                Text("""
                    macOS calls system-audio capture **Screen Recording**. Meetings never records \
                    your screen; that API is the only way Apple gives access to system audio.
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

/// Where transcription runs: here, or a service.
///
/// That is the whole decision, and it is the only one on this page. There is no model list, no tier,
/// no measured throughput and no "live versus final", because ``LocalTranscriber`` already resolved
/// all of it from the system language — one model, one download, one pass. A reader who does not
/// know what a transcription model is cannot choose between two of them, and asking them to was
/// work the machine could do.
private struct TranscriberStep: View {
    let model: AppModel
    /// True while transcription is pointed at a remote endpoint nothing has proved works. Read by
    /// the wizard's footer.
    @Binding var unverified: Bool
    /// True from the press of Download until it settles. The wizard's footer holds Continue on it.
    @Binding var downloading: Bool
    /// A counter the wizard bumps to mean "run the verification now".
    let verifyRequested: Int
    /// Called when a verification passes, so Continue does not need a second press.
    let advance: () -> Void

    @State private var engine = TranscriptionEngineChoice.local

    @State private var ready: Bool?
    @State private var progress = 0.0
    @State private var problem: String?

    /// Bumped when cloud credentials are carried over, to make ``RemoteTranscriptionFields`` read
    /// the rows again. Its fields load into `@State` once, so without this the carry-over would
    /// write four correct settings rows and leave four visibly empty boxes on top of them.
    @State private var remoteReload = 0
    /// Whether anything was actually carried over, so the reassurance is only shown when it is true.
    @State private var carriedOverCredentials = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Both choices first, then the panel belonging to whichever is selected. The two panels
            // are different heights and the wizard's scroll viewport is only about 515 pt once the
            // footer is out, so a card placed *under* the other card's panel began below the bottom
            // edge — and macOS hides the scrollbar until something scrolls, so it did not read as
            // below the fold, it read as absent. The step looked like it offered one choice.
            ModeCard(
                title: "On this Mac",
                detail: "Your audio never leaves the machine. One download, then it works with no "
                    + "network and no account.",
                badge: "Recommended",
                selected: engine == .local
            ) { select(.local) }

            ModeCard(
                title: "A transcription service",
                detail: "Nothing to download. The audio of every meeting is uploaded to a service "
                    + "you set up, and transcribed there.",
                badge: nil,
                selected: engine == .cloud
            ) { select(.cloud) }

            switch engine {
            case .local:
                ConfigurationPanel { localBody }
            case .cloud:
                ConfigurationPanel {
                    if carriedOverCredentials {
                        Label(
                            "Filled in from your write-up provider, so you do not type it twice.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    RemoteTranscriptionFields(
                        store: model.store,
                        verifyRequested: verifyRequested,
                        reloadRequested: remoteReload
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

    // MARK: - On this Mac

    @ViewBuilder
    private var localBody: some View {
        switch (ready, downloading) {
        case (true, _):
            Label("Ready. Your meetings are transcribed on this Mac.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
                .fixedSize(horizontal: false, vertical: true)
        case (_, true):
            ProgressView(value: progress) {
                Text("Downloading — \(LocalTranscriber.current.downloadSizeText)")
            } currentValueLabel: {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            Text("This happens once. You can carry on as soon as it finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Button("Download — \(LocalTranscriber.current.downloadSizeText)") { download() }
                .buttonStyle(.bordered)
                .controlSize(.large)
            // The old copy read "you can skip this and still record", which is true and misleading
            // in the same breath. Recording works; nothing downstream of it does. Someone deciding
            // whether to wait should be told what they are trading, not reassured.
            Text("Skip it and you get audio only: no transcript, no search, no write-up. You can "
                + "download later in Settings.")
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
        // Arriving on a store that is already pointed at a service: carry the credentials over
        // *before* the fields appear. Doing it only on the card press is too late in that case,
        // because `RemoteTranscriptionFields.load` fills its own OpenAI defaults on first sight, and
        // a row that is no longer empty is a row the carry-over will not touch.
        if engine == .cloud { carryOverCloudCredentials() }
        ready = await model.transcription.modelsReady()
        // Leaving this step tears the view down and takes `progress` with it, while the download
        // itself carries on. Coming back therefore offered a Download button for a download already
        // running, and pressing it used to start a second one.
        //
        // Rejoining is now the same call: `prepareModels` attaches to the download in flight
        // rather than starting one, so this needs no separate resume path — and it re-arms the
        // footer's hold, which is correct, because the download really is still running.
        if await model.transcription.isPreparingModels { download() }
    }

    private func select(_ choice: TranscriptionEngineChoice) {
        engine = choice
        // Choosing the endpoint arms the verification hold; choosing local disarms it. Picking the
        // service and then changing your mind must not leave Continue held on a verification for an
        // engine that is no longer selected.
        unverified = choice == .cloud
        try? model.store.setSetting(.transcribeBatchEngine, choice.rawValue)
        if choice == .cloud { carryOverCloudCredentials() }
        // The service caches the engine it resolved on first use, and that cache outlives this
        // press. Without dropping it, switching here and recording in the same launch would still
        // run the previous engine.
        Task {
            await model.transcription.forgetResolvedEngine()
            ready = await model.transcription.modelsReady()
        }
    }

    /// A base URL, model and key set up for the write-up provider describe an account the same
    /// person almost certainly wants to transcribe with, and typing them a second time into a second
    /// pane is the single most avoidable set of presses in this window.
    ///
    /// Safe to call more than once: the store copies only onto rows that are still empty, so a value
    /// the user typed here is never replaced, and a second call after the first has filled everything
    /// copies nothing and reports false.
    private func carryOverCloudCredentials() {
        guard (try? model.store.adoptCloudCredentialsForTranscription()) == true else { return }
        carriedOverCredentials = true
        remoteReload += 1
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
            // Released on failure as well as success. A hold that outlived a failed download would
            // leave Continue dead with an error message beside it and no way forward at all.
            downloading = false
        }
    }
}

/// Who writes the summary, and — for the mode that needs one — which agent.
///
/// All three modes are on screen at once. They used to be one card and a "Show the other two modes"
/// button, which cost a press to discover that the other two existed and left the least capable mode
/// selected for anyone who never found it. Three cards is the same page with two fewer decisions
/// hidden in it.
private struct ModeStep: View {
    let model: AppModel

    @State private var mode = AIMode.localAgent
    /// The identity of the shared command fields, bumped when ``prefillAgent`` rewrites the rows
    /// underneath them.
    ///
    /// ``LocalAgentCommandFields`` seeds its command text *and* its agent picker from the store in
    /// `onAppear` and does not read them again, which is right for a pane being typed into. It is
    /// also a race with this step: `mode` starts on `.localAgent`, so the panel is already on screen
    /// during the same pass that writes the detected agent's commands, and child and parent
    /// `onAppear` ordering is not something to rely on. A new identity remounts the shared view
    /// after the write, which re-seeds both — so the picker lands on the agent this Mac has rather
    /// than on whatever the row said a moment earlier.
    @State private var commandFields = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Recommended, and first, because it is the mode that actually does the thing the app is
            // for without being asked. The second sentence is not a caveat, it is the fact of the
            // mode: the shipped default command hands the whole transcript to a hosted agent, and
            // leaving that as an absence actively misled anyone picking this mode to keep their data
            // on their own machine.
            ModeCard(
                title: "Your agent, automatically",
                detail: "Meetings runs your agent as soon as a meeting is transcribed, without "
                    + "asking. Whether the transcript leaves this Mac depends on the command you set.",
                badge: "Recommended",
                selected: mode == .localAgent
            ) { select(.localAgent) }

            // Each mode's own settings, under the option that needs them. Chosen here rather than
            // deferred to Settings because a mode picked and left unconfigured does nothing at all,
            // silently, at the end of the next meeting.
            if mode == .localAgent {
                // The agent chooser lives inside `LocalAgentCommandFields`, next to the command it
                // fills in, so this page and Settings ▸ AI cannot end up with two pickers over one
                // settings row disagreeing about which agent is configured.
                ConfigurationPanel {
                    LocalAgentCommandFields(store: model.store)
                        .id(commandFields)
                }
            }

            ModeCard(
                title: "Only when you ask",
                detail: "Nothing runs on its own. Finished meetings wait under Needs write-up until "
                    + "you hand one to your agent yourself.",
                badge: nil,
                selected: mode == .manual
            ) { select(.manual) }

            ModeCard(
                title: "A cloud provider",
                detail: "A provider you set up writes the summary. Your transcript and notes are "
                    + "sent to them.",
                badge: nil,
                selected: mode == .cloud
            ) { select(.cloud) }

            if mode == .cloud {
                ConfigurationPanel { CloudProviderFields(store: model.store) }
            }
        }
        .onAppear(perform: start)
        // Separate from `start` because it is the one thing on this page that can be slow: see
        // ``prefillAgent``.
        .task { await prefillAgent() }
    }

    // MARK: -

    /// The recommended mode is *written*, not merely drawn, and only while the store still reads as
    /// shipped.
    ///
    /// Drawing a selection the store does not hold is the bug this avoids: the page would show the
    /// recommended mode selected, the user would press Continue agreeing with it, and the store
    /// would still say `manual` — a setting silently disagreeing with the screen that set it. So the
    /// recommendation is committed the first time the step is seen.
    ///
    /// The condition is "the row still equals the shipped default". It cannot distinguish a user who
    /// deliberately chose the shipped value from one who never touched it — nothing can, from one
    /// row — but it does guarantee the far worse case never happens: a mode the user actually chose
    /// is never overwritten by this page arriving. ``prefillAgent`` applies the same test to the
    /// command rows.
    private func start() {
        let stored = loadSetting(model.store, .aiMode)
        if stored == SettingKey.aiMode.defaultValue {
            select(.localAgent)
        } else {
            mode = AIMode(stored: stored)
        }
    }

    /// Fills in the commands for the agent this Mac actually has, so the step arrives already
    /// correct and costs one press — Continue.
    ///
    /// This is the largest single saving in the wizard, and it is deliberately *not* in the shared
    /// ``LocalAgentCommandFields``, which draws the agent picker for both this page and Settings ▸
    /// AI. Opening a Settings tab is not consent to rewrite a command row; arriving on an
    /// untouched store during first-run setup is exactly the moment a good guess is wanted. So the
    /// control is shared and this one write is not.
    ///
    /// ``AgentPreset/detected(searchPath:)`` resolves against the PATH a spawned agent really gets,
    /// which is what makes the guess worth writing: a hit means the command filled in will start,
    /// rather than merely look plausible. It is also why this is `async` and hops off the main
    /// actor. That search now unions the login shell's PATH, which on its first call in the process
    /// spawns `$SHELL -ilc` and is bounded at two seconds — run inline from `onAppear` that is up to
    /// two seconds of frozen window at the exact moment the user pressed Continue onto this page,
    /// which reads as the wizard having crashed. Only the settings write comes back to the main
    /// actor.
    ///
    /// Nothing happens unless the row still reads exactly as shipped. That test cannot tell a user
    /// who typed the default back from one who never touched it — no single row can — but it does
    /// guarantee the case that would actually hurt never happens: a command someone edited is never
    /// overwritten by this page being opened. When it does not fire, the shared view's own seeding
    /// selects the matching agent, or "Something else", from whatever the row holds.
    ///
    /// The row is read twice, once each side of the hop, and both reads have to agree that it is
    /// untouched. The first read is the cheap skip: anyone who has already configured this never
    /// pays for a shell spawn at all. The second is the correctness one — those two seconds are
    /// wide enough for the user to type in the command field, which is on screen throughout on a
    /// fresh store, and a guess that lands on top of what they just typed is precisely the thing
    /// this must never do.
    private func prefillAgent() async {
        guard storedRunCommandIsShipped else { return }
        // Hoisted out of the `guard` on purpose: a trailing closure inside a guard condition parses
        // as the guard's own body.
        let detection = Task.detached(priority: .userInitiated) { AgentPreset.detected() }
        guard let detected = await detection.value, storedRunCommandIsShipped else { return }
        write(detected)
    }

    private var storedRunCommandIsShipped: Bool {
        loadSetting(model.store, .aiLocalAgentRunCommand)
            == SettingKey.aiLocalAgentRunCommand.defaultValue
    }

    /// Both command forms, from one choice.
    ///
    /// The two rows are separate settings for a good reason — a run command execs and starts a fresh
    /// headless run, a paste command goes into a session already open and execs nothing — but they
    /// are never separate *decisions*. Somebody who says "I use Claude Code" would not expect the
    /// copy button on the Needs-write-up card to still be offering another agent's line.
    private func write(_ chosen: AgentPreset) {
        try? model.store.setSetting(.aiLocalAgentRunCommand, chosen.runCommand)
        try? model.store.setSetting(.aiManualPasteCommand, chosen.pasteCommand)
        commandFields += 1
    }

    private func select(_ new: AIMode) {
        mode = new
        try? model.store.setSetting(.aiMode, new.rawValue)
    }
}

/// The fields a chosen mode needs, in the shape this wizard already uses for the one panel on a page
/// that reports or asks for something — the download's box and the CLI step's box.
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

/// One choice on a step that is nothing but choices: the transcriber's two, and the summary's three.
/// Same control, same meaning, so the two pages do not teach two different idioms for "pick one".
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
                heading: "The meetings command",
                detail: "Puts the tool inside Meetings.app where your agent can find it, so it can "
                    + "reach your meetings from anywhere."
            )
            FeatureRow(
                symbol: "sparkles",
                heading: "A skill for your agent",
                detail: "Installed on launch, so \"add some notes to my call with Will tomorrow\" "
                    + "works straight away."
            )

            VStack(alignment: .leading, spacing: 10) {
                Label(status.label, systemImage: isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(isInstalled ? AnyShapeStyle(Color(nsColor: .systemGreen)) : AnyShapeStyle(.secondary))
                if !isInstalled {
                    Button("Install the meetings command") {
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
                        "No agent found on this Mac yet, so there is nowhere to put the skill.",
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
