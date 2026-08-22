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
    /// Every other step here can be left unfinished — a permission ungranted or a model
    /// undownloaded announces itself the moment it matters, loudly, in the app. A wrong API key does
    /// not: it fails after the first real meeting, with the audio already recorded, and the only
    /// cheap moment to catch it is this one. Hence a gate here and nowhere else, and hence
    /// ``verifyRequested`` rather than a locked door — one failed verification puts a way past it
    /// on screen.
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
    /// True when Local is selected and the model is not on disk. Continue then goes to ``download``.
    @State private var downloadNeeded = false


    /// The size the wizard was designed at. Every step is laid out against it.
    /// Not private: the window scene opens at this size on a first run, so the wizard is never
    /// watched resizing into place.
    static let card = CGSize(width: 560, height: 700)

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
        case welcome = 0
        case permissions = 1
        case model = 2
        /// New page. Raw 5 so a store that saved `mode` (3) or `cli` (4) still resumes there.
        case download = 5
        case mode = 3
        case cli = 4

        static let sequence: [Step] = [.welcome, .permissions, .model, .download, .mode, .cli]

        var index: Int { Self.sequence.firstIndex(of: self) ?? 0 }

        var next: Step? {
            let sequence = Self.sequence
            guard let i = sequence.firstIndex(of: self), i + 1 < sequence.count else { return nil }
            return sequence[i + 1]
        }

        var previous: Step? {
            let sequence = Self.sequence
            guard let i = sequence.firstIndex(of: self), i > 0 else { return nil }
            return sequence[i - 1]
        }
    }


    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let fraction = CGFloat(step.index) / CGFloat(max(Step.sequence.count - 1, 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(24, geo.size.width * fraction))
                        .shadow(color: Color.accentColor.opacity(0.45), radius: 6)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 28)
            .padding(.top, 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 26, weight: .semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    content
                        .id(step)
                        .transition(.opacity)
                        .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            footer
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
        }
        .frame(width: Self.card.width, height: Self.card.height)
        .background(Color.clear)
        .onAppear {
            if let initialStep, let index = Int(initialStep), let parsed = Step(rawValue: index) {
                step = parsed
            }
        }
        .onChange(of: step) { _, moved in
            UserDefaults.standard.set(moved.rawValue, forKey: Self.stepKey)
        }
    }

    @ViewBuilder
    private var footer: some View {
        standardFooter
    }

    @ViewBuilder
    private var standardFooter: some View {
        HStack(spacing: 12) {
            if hold == .unverifiedEndpoint, allowUnverified {
                Button("Continue without verifying") {
                    withAnimation(.easeOut(duration: 0.15)) { step = .mode }
                }
                .buttonStyle(.link)
            } else if hold == .downloadRunning {
                EmptyView()
            }
            Spacer()
            if let previous = retreatTarget {
                Button("Back") { withAnimation(.easeOut(duration: 0.15)) { step = previous } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("[", modifiers: .command)
            }
        }
        Button(action: advance) {
            Text(continueTitle)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color.accentColor, in: .rect(cornerRadius: 12, style: .continuous))
        .keyboardShortcut(.defaultAction)
        .disabled(hold == .downloadRunning)
        .opacity(hold == .downloadRunning ? 0.45 : 1)
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
        if step == .download, downloadRunning { return .downloadRunning }
        if step == .model, remoteUnverified { return .unverifiedEndpoint }
        return nil
    }

    private var continueTitle: String {
        if hold == .downloadRunning { return "Please wait…" }
        if hold == .unverifiedEndpoint { return "Verify and continue" }
        return step.next == nil ? "Start using Meetings" : "Continue"
    }

    private var title: String {
        switch step {
        case .welcome: "Welcome to Meetings"
        case .permissions: "Permissions"
        case .model: "Transcribe"
        case .download: "Downloading the model"
        case .mode: "Write-up"
        case .cli: "Agent"
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome: "Both sides, on this Mac."
        case .permissions: "Optional. Asked only when needed."
        case .model: "Local or cloud."
        case .download: "\(LocalTranscriber.current.languages). \(LocalTranscriber.current.downloadSizeText)."
        case .mode: "Your agent, a cloud provider, or manual."
        case .cli: "Command and skill for your agent."
        }
    }

    /// Back from write-up skips the download page unless we actually opened it.
    private var retreatTarget: Step? {
        if step == .mode { return downloadNeeded ? .download : .model }
        return step.previous == .download && !downloadNeeded ? .model : step.previous
    }

    private func advance() {
        if hold == .unverifiedEndpoint {
            allowUnverified = true
            verifyRequested += 1
            return
        }
        if step == .model {
            withAnimation(.easeOut(duration: 0.15)) { step = downloadNeeded ? .download : .mode }
            return
        }
        if let next = step.next {
            withAnimation(.easeOut(duration: 0.15)) { step = next == .download && !downloadNeeded ? .mode : next }
        } else {
            complete()
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
                downloadNeeded: $downloadNeeded,
                verifyRequested: verifyRequested
            ) {
                withAnimation(.easeOut(duration: 0.15)) { step = downloadNeeded ? .download : .mode }
            }
        case .download:
            DownloadStep(model: model, downloading: $downloadRunning)
        case .mode: ModeStep(model: model)
        case .cli: CLIStep()
        }
    }

    private func complete() {
        try? model.store.setSetting(.onboardingCompleted, "true")
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        finish()
    }
}

/// OpenLookAway's onboarding window: a raw `NSWindow` whose `contentView` is
/// `installGlassHost`. SwiftUI `Window` owns a titlebar that paints black on
/// become-key; this stack does not.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    static let windowID = "meetings-onboarding"
    private var window: NSWindow?
    private var onFinished: (() -> Void)?
    private var accepted = false
    /// First-run close quits. Replaying the guide from Settings just dismisses.
    private var quitOnClose = true

    func show(model: AppModel, initialStep: String?, onFinished: @escaping () -> Void) {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        self.onFinished = onFinished
        accepted = false
        quitOnClose = (try? model.store.settingBool(.onboardingCompleted)) != true
        let root = OnboardingView(model: model, initialStep: initialStep) { [weak self] in
            self?.accept()
        }
        let card = OnboardingView.card
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: card.width, height: card.height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Meetings"
        window.titleVisibility = .hidden
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
        window.isReleasedWhenClosed = false
        window.installGlassHost(root)
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Last Continue. Reveal the app first, then close this window.
    func accept() {
        guard !accepted else { return }
        accepted = true
        let done = onFinished
        onFinished = nil
        done?()
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !accepted else { return }
        onFinished = nil
        window = nil
        if quitOnClose {
            NSApp.terminate(nil)
        }
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
        VStack(alignment: .leading, spacing: 20) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            }
            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(
                    symbol: "waveform",
                    heading: "Both sides",
                    detail: "Mic and system audio, one transcript."
                )
                FeatureRow(
                    symbol: "laptopcomputer",
                    heading: "On this Mac",
                    detail: "Local by default. Cloud if you want it."
                )
                FeatureRow(
                    symbol: "sparkles",
                    heading: "Written up",
                    detail: "Your agent turns the call into notes."
                )
            }
            .padding(.top, 4)
        }
    }
}

private struct PermissionsStep: View {
    @State private var statuses: [Permission: PermissionStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Permission.allCases) { permission in
                PermissionRow(
                    permission: permission,
                    status: statuses[permission] ?? permission.status,
                    compact: true
                ) { statuses[permission] = $0 }
                Divider()
            }
            if CodeSignature.isAdHoc { AdHocSigningNotice() }
            Text("macOS calls system-audio capture **Screen Recording**. Meetings never records your screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
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
    @Binding var downloadNeeded: Bool
    /// A counter the wizard bumps to mean "run the verification now".
    let verifyRequested: Int
    /// Called when a verification passes, so Continue does not need a second press.
    let advance: () -> Void

    @State private var engine = TranscriptionEngineChoice.local
    @State private var ready: Bool?
    @State private var remoteReload = 0
    @State private var carriedOverCredentials = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                EngineTile(
                    symbol: "laptopcomputer",
                    title: "Local",
                    selected: engine == .local
                ) { select(.local) }
                EngineTile(
                    symbol: "cloud",
                    title: "Cloud",
                    selected: engine == .cloud
                ) { select(.cloud) }
            }
            if engine == .cloud {
                ConfigurationPanel {
                    if carriedOverCredentials {
                        Label(
                            "Filled from your write-up provider.",
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

    private func load() async {
        engine = model.store.transcriptionEngine()
        unverified = engine == .cloud
        if engine == .cloud { carryOverCloudCredentials() }
        ready = await model.transcription.modelsReady()
        refreshDownloadNeeded()
        if await model.transcription.isPreparingModels {
            downloadNeeded = true
        }
    }

    private func select(_ choice: TranscriptionEngineChoice) {
        engine = choice
        unverified = choice == .cloud
        try? model.store.setSetting(.transcribeBatchEngine, choice.rawValue)
        if choice == .cloud { carryOverCloudCredentials() }
        Task {
            await model.transcription.forgetResolvedEngine()
            ready = await model.transcription.modelsReady()
            refreshDownloadNeeded()
        }
    }

    private func refreshDownloadNeeded() {
        downloadNeeded = engine == .local && ready != true
    }

    private func carryOverCloudCredentials() {
        guard (try? model.store.adoptCloudCredentialsForTranscription()) == true else { return }
        carriedOverCredentials = true
        remoteReload += 1
    }
}

/// Dedicated wait. Auto-starts, and `prepareModels` joins a download already in flight.
private struct DownloadStep: View {
    let model: AppModel
    @Binding var downloading: Bool
    @State private var progress = 0.0
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 28) {
            DownloadIconTile(progress: progress) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                        .clipShape(.rect(cornerRadius: 16, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(Color(nsColor: .systemRed))
            }
        }
        .task { start() }
    }

    private func start() {
        downloading = true
        problem = nil
        progress = 0
        Task {
            do {
                try await model.transcription.prepareModels { value in
                    Task { @MainActor in progress = max(progress, value) }
                }
                progress = 1
            } catch {
                problem = "The download failed: \(error.localizedDescription)"
            }
            downloading = false
        }
    }
}

/// App Store download: dim icon, pie wipe restores full colour.
private struct DownloadIconTile<Content: View>: View {
    let progress: Double
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack {
            content
                .saturation(0.2)
                .opacity(0.35)
            content
                .mask(PieReveal(progress: progress))
        }
        .frame(width: 108, height: 108)
        .background(Color.primary.opacity(0.08), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .overlay {
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(10)
                .opacity(progress < 1 ? 1 : 0)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }
}

private struct PieReveal: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: hypot(rect.width, rect.height),
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * max(0, min(progress, 1))),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct EngineTile: View {
    let symbol: String
    let title: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(title)
                    .font(.headline)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 148)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                in: .rect(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
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
    /// Bumped when ``prefillAgent`` rewrites the command rows underneath the shared fields, to ask
    /// them to read the rows again.
    ///
    /// ``LocalAgentCommandFields`` seeds its command text *and* its agent picker from the store in
    /// `onAppear` and does not read them again, which is right for a pane being typed into. It is
    /// also a race with this step: `mode` starts on `.localAgent`, so the panel is already on
    /// screen during the same pass that writes the detected agent's commands, and child and parent
    /// `onAppear` ordering is not something to rely on.
    ///
    /// This was a `.id()` remount, which is the wrong tool for it. A new identity does not re-seed
    /// a view, it destroys and rebuilds one — taking the fields' other `@State` with it, including
    /// the `checking` flag and the `result` of "Check the command". Prefill lands up to two seconds
    /// after the panel appears, because it awaits a PATH resolution bounded at two seconds, so it
    /// routinely fell inside a check the user had just started: the spinner disappeared, the button
    /// re-enabled, and the verdict was written to a discarded copy of the view and never drawn. For
    /// the one mode that runs unattended, the control that proves the command works read as broken.
    ///
    /// A counter re-seeds the two rows in place and leaves everything else standing, which is the
    /// same seam ``RemoteTranscriptionFields`` already uses for the same problem.
    @State private var commandFieldsReload = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Recommended, and first, because it is the mode that actually does the thing the app is
            // for without being asked. The second sentence is not a caveat, it is the fact of the
            // mode: the shipped default command hands the whole transcript to a hosted agent, and
            // leaving that as an absence actively misled anyone picking this mode to keep their data
            // on their own machine.
            ModeCard(
                title: "Your agent, automatically",
                detail: "Runs after each meeting. Depends on the command you set.",
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
                    LocalAgentCommandFields(store: model.store, reloadRequested: commandFieldsReload)
                }
            }

            ModeCard(
                title: "Only when you ask",
                detail: "Finished meetings wait under Needs write-up.",
                badge: nil,
                selected: mode == .manual
            ) { select(.manual) }

            ModeCard(
                title: "A cloud provider",
                detail: "Transcript and notes are sent to them.",
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
        commandFieldsReload += 1
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
                detail: "Where your agent can find it."
            )
            FeatureRow(
                symbol: "sparkles",
                heading: "A skill for your agent",
                detail: "Installed on launch."
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
                        "No agent found on this Mac yet.",
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
