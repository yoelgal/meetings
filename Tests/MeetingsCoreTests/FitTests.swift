import Foundation
import Testing

@testable import MeetingsCore

/// A probe with the models taken out of it: it returns whatever the test says each candidate
/// measured, so the ladder — where it starts, when it steps down, what the cap does, what a failure
/// becomes — can be driven without a gigabyte of Core ML or a Neural Engine.
private final class ScriptedProbe: FitProbe, @unchecked Sendable {
    /// Keyed by option id. A missing key throws, which is how "this download failed" is expressed.
    var results: [String: FitMeasurement] = [:]
    var downloadFailures: Set<String> = []
    private let lock = NSLock()
    private var order: [String] = []
    /// Every candidate actually measured, in order. The ladder's behaviour is as much about what it
    /// did *not* run as about what it chose.
    var measured: [String] { lock.withLock { order } }

    struct NoModel: Error {}
    struct DownloadFailed: Error {}

    func download(_ option: LocalTranscriptionOption, progress: @Sendable @escaping (Double) -> Void) async throws {
        guard !downloadFailures.contains(option.id) else { throw DownloadFailed() }
        progress(1)
    }

    func measure(_ option: LocalTranscriptionOption, fixture: SpeechFixture) async throws -> FitMeasurement {
        lock.withLock { order.append(option.id) }
        guard let result = results[option.id] else { throw NoModel() }
        return result
    }

    static func measurement(_ id: String, rtfx: Double, firstText: Int = 700) -> FitMeasurement {
        FitMeasurement(
            optionID: id, realTimeFactor: rtfx, timeToFirstTextMs: firstText,
            peakMemoryBytes: 1_000_000_000, audioSeconds: 15, wordErrorPercent: 3)
    }
}

/// Boxes for the two things a `@Sendable` closure has to mutate from whatever executor calls it.
private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FitStage] = []
    var values: [FitStage] { lock.withLock { stored } }
    func append(_ stage: FitStage) { lock.withLock { stored.append(stage) } }
}

private final class TickCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}

@Suite struct FitTests {
    /// The one machine anybody has measured, to its real reported shape: an M1 Pro is 6P/2E, not
    /// 8P. The first draft of the starting table asked for 8 performance cores and would have
    /// refused to try the top tier on exactly this Mac.
    static let fastMac = MachineProfile(
        chip: "Apple M1 Pro", performanceCores: 6, efficiencyCores: 2,
        memoryBytes: 16 * 1_073_741_824, osVersion: "macOS 26.1")
    static let smallMac = MachineProfile(
        chip: "Apple M1", performanceCores: 4, efficiencyCores: 4,
        memoryBytes: 8 * 1_073_741_824, osVersion: "macOS 26.0")
    static let intelMac = MachineProfile(
        chip: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", performanceCores: 0, efficiencyCores: 0,
        memoryBytes: 32 * 1_073_741_824, osVersion: "macOS 15.0")

    /// A fixture whose audio never gets decoded: the scripted probe ignores it, and its only job
    /// here is to be non-nil so the runner does not take the no-fixture branch.
    static func stubFixture() -> SpeechFixture {
        let track = SpeechFixture.Track(
            url: URL(fileURLWithPath: "/dev/null"), script: "hello", samples: [Float](repeating: 0, count: 16_000))
        return SpeechFixture(mic: track, system: track)
    }

    // MARK: - Where it starts

    /// The one extrapolation in the whole feature, pinned so a change to it is deliberate.
    @Test func theStartingCandidateComesFromTheMachineAndNothingElse() {
        let all = LocalTranscriptionOption.all
        #expect(Self.fastMac.startingIndex(among: all) == 0,
                "the machine the numbers came from has to be willing to try the top tier")
        // The regression that motivated pinning this: a threshold above the measured machine.
        #expect(MachineProfile.measuredPerformanceCores <= Self.fastMac.performanceCores)
        #expect(MachineProfile.measuredMemoryGB <= Self.fastMac.memoryGB)
        #expect(Self.smallMac.startingIndex(among: all) == all.count - 1)
        #expect(Self.intelMac.startingIndex(among: all) == all.count - 1,
                "no Neural Engine means start at the fallback, however much RAM there is")
        #expect(Self.intelMac.isAppleSilicon == false)
    }

    // MARK: - The ladder

    @Test func aCandidateThatClearsTheBarIsChosenOnItsOwnNumbers() async {
        let probe = ScriptedProbe()
        let top = LocalTranscriptionOption.all[0]
        probe.results[top.id] = ScriptedProbe.measurement(top.id, rtfx: 6.4, firstText: 780)

        let record = await FitRunner(probe: probe, profile: Self.fastMac).run(fixture: Self.stubFixture())

        #expect(record.chosenOptionID == top.id)
        #expect(record.verified)
        #expect(record.reason.contains("6.4x"))
        #expect(record.reason.contains("780 ms"))
        #expect(record.reason.contains("Apple M1 Pro"))
        #expect(probe.measured == [top.id], "nothing below it should have been downloaded at all")
    }

    /// The step-down, which is the point of the ladder. The top tier is measured, misses, and the
    /// fallback is measured and taken — and the record carries both.
    @Test func aCandidateThatMissesTheBarStepsDownAndSaysWhy() async {
        let probe = ScriptedProbe()
        let all = LocalTranscriptionOption.all
        probe.results[all[0].id] = ScriptedProbe.measurement(all[0].id, rtfx: 0.9)
        probe.results[all[1].id] = ScriptedProbe.measurement(all[1].id, rtfx: 5.1, firstText: 810)

        let stages = StageLog()
        let record = await FitRunner(probe: probe, profile: Self.fastMac)
            .run(fixture: Self.stubFixture()) { stage in
                if case .steppingDown = stage { stages.append(stage) }
            }

        #expect(record.chosenOptionID == all[1].id)
        #expect(record.verified)
        #expect(record.measurements.count == 2, "the rejected candidate stays in the record")
        #expect(record.measurements.first?.realTimeFactor == 0.9)
        #expect(stages.values.count == 1)
        #expect(probe.measured == [all[0].id, all[1].id])
    }

    /// Nothing clears the bar. The fallback still runs — there is nothing below it — but the record
    /// must not claim it was chosen *because* of its numbers.
    @Test func whenNothingClearsTheBarTheFallbackIsTakenAndSaidSo() async {
        let probe = ScriptedProbe()
        for option in LocalTranscriptionOption.all {
            probe.results[option.id] = ScriptedProbe.measurement(option.id, rtfx: 0.4)
        }

        let record = await FitRunner(probe: probe, profile: Self.fastMac).run(fixture: Self.stubFixture())

        #expect(record.chosenOptionID == LocalTranscriptionOption.fallback.id)
        #expect(record.reason.contains("nothing cleared the bar"))
    }

    /// The honesty requirement, spelled out: no fixture means no measurement means the shipping
    /// default, marked unverified, with the reason on the record.
    @Test func withNoFixtureNothingIsMeasuredAndTheFallbackIsMarkedUnverified() async {
        let probe = ScriptedProbe()
        let record = await FitRunner(probe: probe, profile: Self.fastMac).run(fixture: nil)

        #expect(record.chosenOptionID == LocalTranscriptionOption.fallback.id)
        #expect(record.verified == false)
        #expect(record.measurements.isEmpty)
        #expect(record.reason.contains("nothing was measured"))
        #expect(probe.measured.isEmpty)
        #expect(!record.headline.contains("chosen because"),
                "an unverified record must never be phrased as a measurement")
    }

    /// A download that fails is not a crash and not a silent pass — it steps down like any other
    /// miss, and the failure is the reason if nothing below works either.
    @Test func aFailedDownloadStepsDownRatherThanFailingTheRun() async {
        let probe = ScriptedProbe()
        let all = LocalTranscriptionOption.all
        probe.downloadFailures = [all[0].id]
        probe.results[all[1].id] = ScriptedProbe.measurement(all[1].id, rtfx: 5.0)

        let record = await FitRunner(probe: probe, profile: Self.fastMac).run(fixture: Self.stubFixture())

        #expect(record.chosenOptionID == all[1].id)
        #expect(record.verified)
        #expect(probe.measured == [all[1].id], "the candidate that would not download was never measured")
    }

    /// The cap, and that it is recorded. A clock that has already run past the ceiling means the
    /// first candidate is never even started.
    @Test func theCapStopsTheRunBeforeAnythingIsDownloaded() async {
        let probe = ScriptedProbe()
        for option in LocalTranscriptionOption.all {
            probe.results[option.id] = ScriptedProbe.measurement(option.id, rtfx: 9)
        }
        // The first reading is the run's start; every one after it is already past the ceiling.
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TickCount()
        let record = await FitRunner(
            probe: probe, profile: Self.fastMac, cap: 60,
            now: { clock.next() == 0 ? start : start.addingTimeInterval(120) }
        ).run(fixture: Self.stubFixture())

        #expect(probe.measured.isEmpty)
        #expect(record.verified == false)
        #expect(record.capSeconds == 60)
        #expect(record.reason.contains("60 second limit"))
    }

    // MARK: - The record

    @Test func theRecordRoundTripsThroughTheStoreAndSelectsWhatItJustified() throws {
        let directory = try TestStore.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TestStore.open(directory)

        let option = LocalTranscriptionOption.all[0]
        let record = FitRecord(
            chosenOptionID: option.id, reason: "6.4x real-time", verified: true,
            machine: Self.fastMac, thresholds: .standard,
            measurements: [ScriptedProbe.measurement(option.id, rtfx: 6.4)],
            ranAt: Date(timeIntervalSince1970: 1_700_000_000), capSeconds: 360)

        try store.applyFitRecord(record)
        #expect(store.fitRecord() == record)
        // The record and the selection cannot disagree: the store now runs what the record explains.
        #expect(store.localTranscriptionOption().id == option.id)
        #expect(store.transcriptionEngine() == .local)
    }

    /// The test above passes a whole-second date, which is why it never caught this: `ranAt` is
    /// stored as ISO 8601 and comes back without the fraction, so a record made from `Date()` — which
    /// is every real one — did not equal itself after a round trip, by a margin too small to appear
    /// in either printed value. `FitLiveTests` failed on it and nothing ungated did.
    @Test func aRecordMadeAtAnArbitraryInstantStillRoundTrips() throws {
        let directory = try TestStore.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TestStore.open(directory)

        let option = LocalTranscriptionOption.all[0]
        let record = FitRecord(
            chosenOptionID: option.id, reason: "6.4x real-time", verified: true,
            machine: Self.fastMac, thresholds: .standard,
            measurements: [ScriptedProbe.measurement(option.id, rtfx: 6.4)],
            ranAt: Date(timeIntervalSince1970: 1_700_000_000.4567), capSeconds: 360)

        try store.applyFitRecord(record)
        #expect(store.fitRecord() == record)
    }

    /// The picker used to print the shipped `measured` claim unconditionally, so `accurate-en` read
    /// "2.9% word error" on a Mac where `fit` had just reported 16.4% on its own shorter fixture.
    /// Both numbers are real; shown as one claim they contradict each other.
    @Test func aMeasurementFromThisMacReplacesTheShippedClaim() {
        let option = LocalTranscriptionOption.accurateEnglish
        let run = FitMeasurement(
            optionID: option.id, realTimeFactor: 6.4, timeToFirstTextMs: 1_056,
            peakMemoryBytes: 1_000_000_000, audioSeconds: 15, wordErrorPercent: 16.4)
        let record = FitRecord(
            chosenOptionID: option.id, reason: "6.4x real-time", verified: true,
            machine: Self.fastMac, thresholds: .standard, measurements: [run],
            ranAt: Date(timeIntervalSince1970: 1_700_000_000), capSeconds: 360)

        let measured = option.performanceLine(measuredBy: record)
        #expect(measured == "Measured on this Mac: 1056 ms to first text, 16.4% word error, on 15 s of audio")

        // Nothing measured this option, so the shipped claim stands — and both forms name the audio
        // they rest on, which is the whole reason the two numbers differ.
        let other = LocalTranscriptionOption.balanced.performanceLine(measuredBy: record)
        #expect(other == "Measured on an M1 Pro: 811 ms to first text, 4.6% word error, on 54 s of audio")
        #expect(option.performanceLine(measuredBy: nil)?.contains("2.9% word error") == true)
    }

    @Test func anUnreadableFitRowIsAMissingExplanationRatherThanAnError() throws {
        let directory = try TestStore.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TestStore.open(directory)

        try store.setSetting(.transcribeFitRecord, "{ not json")
        #expect(store.fitRecord() == nil)
    }

    // MARK: - Scoring

    @Test func wordErrorIgnoresCaseAndPunctuationAndCountsEdits() {
        #expect(TranscriptScore.wordErrorPercent(
            reference: "the rig is free on Thursday", heard: "The rig is free on Thursday.") == 0)
        #expect(TranscriptScore.wordErrorPercent(reference: "a b c d", heard: "a b c d") == 0)
        // One substitution in four words.
        #expect(TranscriptScore.wordErrorPercent(reference: "a b c d", heard: "a b x d") == 25)
        // Nothing heard at all is total loss, not a division by zero.
        #expect(TranscriptScore.wordErrorPercent(reference: "a b c d", heard: "") == 100)
        #expect(TranscriptScore.wordErrorPercent(reference: "", heard: "anything") == 0)
    }
}
