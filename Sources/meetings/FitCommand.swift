import ArgumentParser
import Foundation
import MeetingsCore

/// Picks the transcription model that verifiably runs well on this Mac, by running it on this Mac.
///
/// The expensive part is unavoidable and worth naming: a candidate has to be downloaded before it
/// can be measured. So this profiles the machine to choose *where to start*, downloads that one,
/// measures it here, and steps down a tier if it misses. The profile is never the answer.
struct FitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fit",
        abstract: "Measure which transcription model runs well on this Mac, and select it.",
        discussion: """
            Downloads one candidate at a time and runs it against speech synthesised locally with \
            `say -o`, which writes a file — nothing is played. Both channels are decoded at once, \
            because that is what a meeting is; a single-channel measurement is about twice as \
            flattering as the truth.

            Nothing is reported that was not measured. If speech cannot be synthesised, or a \
            download fails, the model that has always shipped stays selected and the reason says so.

            The whole run is capped (see --cap). Re-run it any time — after a new model tier ships, \
            or on a machine whose thermal situation has changed — with `meetings fit --rerun`.
            """
    )

    @Flag(name: .long, help: "Measure again even if a fit has already been recorded.")
    var rerun = false

    @Flag(name: .long, help: "Profile this Mac and print what would be tried first. Downloads and measures nothing.")
    var dryRun = false

    @Option(name: .long, help: "Wall-clock ceiling for the whole run, in seconds, downloads included.")
    var cap: Double = FitRunner.defaultCap

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let context = try CLIContext.open()
            let profile = MachineProfile.current()

            if dryRun {
                let candidates = LocalTranscriptionOption.all
                let start = profile.startingIndex(among: candidates)
                if global.json {
                    try Out.json(FitDryRunJSON(
                        machine: profile,
                        wouldStartWith: candidates[start].id,
                        candidates: candidates.map(\.id)))
                    return
                }
                Out.line(Format.columns([
                    ["machine", profile.summary],
                    ["would start with", "\(candidates[start].title) (\(candidates[start].downloadSizeText))"],
                    ["candidates", candidates.map(\.id).joined(separator: ", ")],
                ]).joined(separator: "\n"))
                return
            }

            if !rerun, let existing = context.store.fitRecord() {
                throw CLIError.invalidState("""
                    This Mac was already fitted: \(existing.headline)
                    Run `meetings fit --rerun` to measure again.
                    """)
            }
            guard cap > 0 else {
                throw CLIError.usage("--cap is a number of seconds greater than zero.")
            }

            // The same entry point the setup wizard uses, so the two cannot report different
            // findings about the same machine. Progress goes to stderr, keeping `--json` a single
            // parseable value on stdout.
            let record = await FitCheck.run(store: context.store, profile: profile, cap: cap) { stage in
                guard !global.json else { return }
                Out.note(FitCheck.sentence(for: stage))
            }

            if global.json {
                try Out.json(record)
                return
            }
            var rows: [[String]] = [
                ["machine", record.machine.summary],
                ["chosen", "\(record.chosen.title) (\(record.chosen.id))"],
                ["why", record.reason],
                ["verified", record.verified ? "yes, measured on this Mac" : "no — nothing was measured"],
                ["bar", String(
                    format: "%.1fx real-time on two channels, first text within %d ms",
                    record.thresholds.realTimeFactor, record.thresholds.timeToFirstTextMs)],
                ["time limit", "\(Int(record.capSeconds))s for the whole run, downloads included"],
            ]
            for measurement in record.measurements {
                rows.append([
                    "measured \(measurement.optionID)",
                    measurement.sentence
                        + String(format: ", peak %.0f MB", Double(measurement.peakMemoryBytes) / 1_000_000),
                ])
            }
            Out.line(Format.columns(rows).joined(separator: "\n"))
        }
    }

}

private struct FitDryRunJSON: Encodable {
    let machine: MachineProfile
    let wouldStartWith: String
    let candidates: [String]
}
