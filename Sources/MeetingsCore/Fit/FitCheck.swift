import Foundation

/// Running a fit end to end: scratch directory, fixture, ladder, and the write back to the store.
///
/// One entry point because there are two callers — the setup wizard and `meetings fit` — and the
/// wizard saying one thing while the CLI says another about the same machine is exactly the drift
/// worth spending a type to prevent.
public enum FitCheck {
    /// Never throws. Everything that can go wrong — no `say`, no writable temporary directory, a
    /// download that fails, the cap running out — comes back as a ``FitRecord`` that says so, and is
    /// stored, because a recorded honest fallback is worth more than an error the caller has to
    /// invent a response to.
    @discardableResult
    public static func run(
        store: MeetingStore,
        probe: any FitProbe = LiveFitProbe(),
        profile: MachineProfile = .current(),
        cap: TimeInterval = FitRunner.defaultCap,
        stage: @Sendable @escaping (FitStage) -> Void = { _ in }
    ) async -> FitRecord {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meetings-fit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let fixture = try? SpeechFixture.make(in: scratch)
        let record = await FitRunner(probe: probe, profile: profile, cap: cap)
            .run(fixture: fixture, stage: stage)
        try? store.applyFitRecord(record)
        return record
    }

    /// One sentence per stage, so the wizard's progress line and `meetings fit`'s stderr say the
    /// same words about the same moment.
    public static func sentence(for stage: FitStage) -> String {
        switch stage {
        case .profiling:
            "Looking at what this Mac is…"
        case .downloading(let option, let fraction):
            "Downloading \(LocalTranscriptionOption.named(option).title)… \(Int(fraction * 100))%"
        case .measuring(let option):
            "Running \(LocalTranscriptionOption.named(option).title) on two channels at once…"
        case .steppingDown(_, let to, let because):
            "\(because). Trying \(LocalTranscriptionOption.named(to).title) instead."
        case .done(let chosen):
            "Chose \(LocalTranscriptionOption.named(chosen).title)."
        }
    }
}
