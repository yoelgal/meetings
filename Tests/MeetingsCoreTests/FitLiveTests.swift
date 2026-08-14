import Foundation
import Testing

@testable import MeetingsCore

/// `meetings fit` against the real models on the real Neural Engine.
///
/// Off unless `MEETINGS_LIVE_FIT=1`: it downloads up to ~700 MB and spins the ANE, which is not a
/// unit test. It is the only thing that exercises ``LiveFitProbe`` — everything in `FitTests` runs
/// the ladder against scripted numbers — so a change to the probe is not proven until this has been
/// run once by hand:
///
///     MEETINGS_LIVE_FIT=1 MEETINGS_HOME=$(mktemp -d) swift test --filter FitLive
///
/// Speech is synthesised with `say -o` straight to a file. Nothing reaches the speakers.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEETINGS_LIVE_FIT"] != nil))
struct FitLiveTests {
    /// The fixture has to be real speech of a real length before any number off it means anything.
    @Test func theFixtureIsTwoDistinctTracksOfActualSpeech() throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }

        let fixture = try SpeechFixture.make(in: directory)
        #expect(fixture.audioSeconds > 5, "too short to measure a decoder against")
        #expect(fixture.mic.samples != fixture.system.samples,
                "two channels of the same audio would let a cache flatter the result")
        // Speech, not a run of zeros: a silent fixture would measure a decoder that decodes nothing.
        #expect(fixture.mic.samples.contains { abs($0) > 0.01 })
    }

    /// The measurement itself, on the option that has always shipped. Asserts the shape of the
    /// numbers rather than their values — the values are what the run is *for*, and pinning them
    /// would turn a slower CI machine into a failing build.
    @Test func theShippingModelMeasuresOnThisMachine() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }

        let option = LocalTranscriptionOption.fallback
        let fixture = try SpeechFixture.make(in: directory)
        let probe = LiveFitProbe()
        try await probe.download(option) { _ in }
        let measurement = try await probe.measure(option, fixture: fixture)

        print("""

            \(option.title) on \(MachineProfile.current().summary)
              \(measurement.sentence)
              peak \(measurement.peakMemoryBytes / 1_000_000) MB over \(measurement.audioSeconds) s of audio

            """)

        #expect(measurement.optionID == option.id)
        #expect(measurement.realTimeFactor > 0, "a zero real-time factor means the run never decoded")
        #expect(measurement.timeToFirstTextMs > 0)
        #expect(measurement.peakMemoryBytes > 0)
        // Two channels of clear synthetic speech through the model this app ships. Well under half
        // the words wrong is a low bar deliberately: this is checking the harness scored a real
        // transcript, not checking the model.
        #expect((measurement.wordErrorPercent ?? 100) < 50,
                "the transcript came back too wrong to be a transcript — check the drain, not the model")
    }

    /// End to end, the way onboarding runs it: profile, download, measure, record. Whatever it picks
    /// is a real answer for this Mac, so the assertions are about honesty rather than about which
    /// option won.
    @Test func aFullFitProducesAVerifiedRecordForThisMac() async throws {
        let directory = try TestStore.makeDirectory()
        defer { TestStore.remove(directory) }
        let store = try TestStore.open(directory)

        let record = await FitCheck.run(store: store) { print(FitCheck.sentence(for: $0)) }
        print("\n\(record.headline)\n")

        #expect(store.fitRecord() == record, "the record has to survive the round trip to the store")
        #expect(store.localTranscriptionOption().id == record.chosenOptionID)
        // Verified means measured. If it is true there has to be a measurement behind it, and if it
        // is false there must be no claim of one.
        if record.verified {
            #expect(record.measurements.contains { $0.optionID == record.chosenOptionID })
        } else {
            #expect(record.chosenOptionID == LocalTranscriptionOption.fallback.id)
        }
    }
}
