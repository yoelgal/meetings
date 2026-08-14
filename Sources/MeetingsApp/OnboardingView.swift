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
                Button(step.next == nil ? "Start using Meetings" : "Continue") {
                    if let next = step.next {
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
        case .model: ModelStep(model: model)
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

private struct ModelStep: View {
    let model: AppModel

    @State private var ready: Bool?
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            FeatureRow(
                symbol: "arrow.down.circle",
                heading: "Two Parakeet models, about 1 GB together",
                detail: "The live one keeps up while you talk. The larger one makes the accurate "
                    + "pass when you stop. Downloaded once, then transcription needs no network."
            )
            FeatureRow(
                symbol: "bolt",
                heading: "Runs on the Neural Engine",
                detail: "An hour of meeting transcribes in well under a minute."
            )

            VStack(alignment: .leading, spacing: 10) {
                switch (ready, downloading) {
                case (true, _):
                    Label("Both models are on this Mac and ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: .systemGreen))
                case (_, true):
                    ProgressView(value: progress) {
                        Text("Downloading the models")
                    } currentValueLabel: {
                        Text(progress.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                    }
                    // Full width of the column. 380 was a number with nothing behind it: it left
                    // the bar stopping short of everything above and below it, which reads as a
                    // layout mistake rather than a measurement.
                    .frame(maxWidth: .infinity)
                default:
                    Button("Download now") { download() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Text("You can skip this and still record. The live transcript stays empty "
                        + "until the models are downloaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(Color(nsColor: .systemRed))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10, style: .continuous))
        }
        .task { ready = await model.transcription.modelsReady() }
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
