import ArgumentParser
import Foundation
import MeetingsCore

/// The first command anyone runs when something looks wrong: which store am I talking to, what is in
/// it, and which of the pieces that need setting up are actually set up.
struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Store location, what is in it, and what is wired up."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await emitting(json: global.json) {
            let databaseURL = Paths.databaseURL
            // Read this before opening: opening creates the file, and "there was no store here" is
            // exactly the answer someone running status on a fresh machine is looking for.
            let existed = FileManager.default.fileExists(atPath: databaseURL.path)

            let context = try CLIContext.open()
            let meetings = try context.store.allMeetings()
            var byState: [String: Int] = [:]
            for meeting in meetings { byState[meeting.state.rawValue, default: 0] += 1 }

            let transcription = TranscriptionService(store: context.store)
            let modelsReady = await transcription.modelsReady()
            // Two facts, not one. `modelsReady` on the cloud path says "the endpoint is configured",
            // which is a different claim from "the models are on disk" and used to be reported with
            // the same words — a cloud user read "Parakeet models ready" about models they had
            // deliberately never downloaded.
            let engineSummary = await transcription.engineSummary()
            let engine = context.store.transcriptionEngine()
            let retentionDays = try context.store.settingInt(.audioRetentionDays) ?? 30
            let installed = installedOnPath()
            let fixture = Paths.calendarFixtureURL
            let size = ((try? FileManager.default.attributesOfItem(atPath: databaseURL.path))?[.size] as? Int) ?? 0

            if global.json {
                try Out.json(StatusJSON(
                    store: .init(path: databaseURL.path, existed: existed, sizeBytes: size),
                    meetings: .init(
                        total: meetings.count,
                        byState: Dictionary(uniqueKeysWithValues: MeetingState.allCases.map {
                            ($0.rawValue, byState[$0.rawValue] ?? 0)
                        })
                    ),
                    transcription: .init(
                        modelsReady: modelsReady,
                        engine: engine.rawValue,
                        summary: engineSummary
                    ),
                    calendar: .init(
                        source: fixture == nil ? "eventkit" : "fixture",
                        authorization: context.calendar.authorizationStatus().rawValue,
                        fixturePath: fixture?.path
                    ),
                    cli: .init(onPath: installed != nil, path: installed),
                    audio: .init(retentionDays: retentionDays)
                ))
                return
            }

            let stateSummary = MeetingState.allCases
                .compactMap { state in byState[state.rawValue].map { "\($0) \(state.rawValue)" } }
                .joined(separator: ", ")

            Out.line(Format.columns([
                ["store", "\(databaseURL.path)\(existed ? " (\(Format.bytes(size)))" : " (created just now)")"],
                ["meetings", meetings.isEmpty ? "none yet" : "\(meetings.count) total (\(stateSummary))"],
                ["transcription", engineSummary],
                ["calendar", calendarLine(context: context, fixture: fixture)],
                ["cli", installed.map { "on PATH at \($0)" }
                    ?? "not on PATH. Install it from Settings > Command line"],
                // The setting is named, and the behaviour is only claimed as far as it is true:
                // `Retention.sweepOnLaunch` runs when the *app* launches, so a store nobody has
                // opened in a month still has its audio. "deleted after 30 days" on its own was a
                // promise this process does not keep.
                ["audio", retentionDays == 0
                    ? "audio.retentionDays = 0 (audio is never purged)"
                    : "audio.retentionDays = \(retentionDays) (audio is purged \(retentionDays) days "
                        + "after a meeting, by a sweep that runs when the app launches)"],
            ]).joined(separator: "\n"))
        }
    }

    private func calendarLine(context: CLIContext, fixture: URL?) -> String {
        let status = context.calendar.authorizationStatus().rawValue
        guard let fixture else { return "\(status) (EventKit)" }
        return "\(status) (fixture \(fixture.path))"
    }

    /// Whether `meetings` is reachable as a command, and from where. The app's Settings button
    /// symlinks it into /usr/local/bin, but a PATH lookup is what actually decides whether
    /// an agent typing `meetings` finds it.
    private func installedOnPath() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("meetings")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }
}

private struct StatusJSON: Encodable {
    struct Store: Encodable {
        let path: String
        let existed: Bool
        let sizeBytes: Int
    }
    struct Meetings: Encodable {
        let total: Int
        let byState: [String: Int]
    }
    struct Transcription: Encodable {
        /// Whether transcription can actually run: the model on disk for the local engine, a
        /// complete configuration for the remote one. Not "files exist" — see `engine`.
        let modelsReady: Bool
        /// `fluidaudio` or `remote`.
        let engine: String
        /// One sentence for a human. There is no `localModel` beside it any more: which local model
        /// runs is not a setting, it is derived from this Mac's language, so a field naming it would
        /// be reporting a choice nobody made.
        let summary: String
    }
    struct Calendar: Encodable {
        let source: String
        let authorization: String
        let fixturePath: String?
    }
    struct CLI: Encodable {
        let onPath: Bool
        let path: String?
    }
    struct Audio: Encodable {
        let retentionDays: Int
        var keptForever: Bool { retentionDays == 0 }

        enum CodingKeys: String, CodingKey { case retentionDays, keptForever }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(retentionDays, forKey: .retentionDays)
            try container.encode(keptForever, forKey: .keptForever)
        }
    }

    let store: Store
    let meetings: Meetings
    let transcription: Transcription
    let calendar: Calendar
    let cli: CLI
    let audio: Audio
}
