import Foundation
import Testing

@testable import MeetingsCore

/// Counts `prepare` calls and stays in flight long enough for a second caller to arrive.
///
/// It throws rather than returning. `prepareModels` moves on to the *streaming* model after the
/// batch engine, and that step is a static on `FluidAudioStreamingTranscriber` with no injection
/// seam — letting the test reach it would start a real ~1 GB download from the suite. Throwing stops
/// the run at exactly the point this test is about, and both callers observe the same error.
private final class CountingEngine: TranscriptionEngine, @unchecked Sendable {
    struct Stop: Error {}

    private let lock = NSLock()
    private var count = 0
    var prepareCalls: Int { lock.withLock { count } }

    let name = "counting"
    let model = "counting"

    func prepare(progress: @Sendable (Double) -> Void) async throws {
        lock.withLock { count += 1 }
        progress(0.5)
        try? await Task.sleep(for: .milliseconds(300))
        throw Stop()
    }

    func transcribe(
        _ audio: URL,
        vocabulary: [VocabularyTerm],
        progress: @Sendable (Double) -> Void
    ) async throws -> [EngineSegment] { [] }

    func vocabularyReport() async -> VocabularyBiasingReport? { nil }
    func release() async {}
}

@Suite final class ModelDownloadTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Pressing Download twice used to start two downloads.
    ///
    /// Found on a real install, not theorised: three write file descriptors open on the same
    /// `weight.bin.partial` and four connections to the CDN, because the wizard's step keeps
    /// `downloading` in `@State`, navigating away destroys it while the download carries on, and
    /// coming back offers a button that started another one. Whichever writer finished last renamed
    /// a file the other two were still writing into, so the failure mode is a model that is the
    /// right size and is not a model.
    @Test func aSecondCallJoinsTheDownloadInFlight() async {
        let engine = CountingEngine()
        let service = TranscriptionService(store: store, engine: engine, audioRoot: directory)

        async let first: Void = { try? await service.prepareModels { _ in } }()
        // Long enough that the first call is inside `prepare` and suspended, which is the state the
        // wizard is in when someone navigates back to the step.
        try? await Task.sleep(for: .milliseconds(80))
        async let second: Void = { try? await service.prepareModels { _ in } }()

        _ = await (first, second)
        #expect(engine.prepareCalls == 1,
                "two callers must share one download; \(engine.prepareCalls) means a second was started")
    }

    /// Four presses, one download. The bug was not limited to the second press.
    @Test func manyCallersStillMeanOneDownload() async {
        let engine = CountingEngine()
        let service = TranscriptionService(store: store, engine: engine, audioRoot: directory)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try? await service.prepareModels { _ in } }
            }
        }
        #expect(engine.prepareCalls == 1)
    }

    /// A joiner is handed the progress so far before it waits.
    ///
    /// Without it the rejoining view draws an empty bar until the next tick from the engine, which
    /// on a slow download is seconds of looking like it restarted — the exact thing the reporter
    /// mistook for a restart in the first place.
    @Test func aJoinerIsToldWhereTheDownloadAlreadyIs() async {
        let engine = CountingEngine()
        let service = TranscriptionService(store: store, engine: engine, audioRoot: directory)

        async let first: Void = { try? await service.prepareModels { _ in } }()
        try? await Task.sleep(for: .milliseconds(80))

        let seen = Locked<[Double]>([])
        async let second: Void = { try? await service.prepareModels { value in seen.append(value) } }()
        _ = await (first, second)

        // 0.5 from the engine, scaled by the 0.6 the batch model is worth.
        #expect(seen.value.first == 0.3,
                "the joiner's first callback should be the progress already reached, not 0")
        // Without this the test passes with the bug present: an unguarded second call runs its own
        // `prepare`, which reports 0.5 straight away, so the joiner sees 0.3 for the wrong reason.
        // The value alone does not distinguish joining from restarting; the call count does.
        #expect(engine.prepareCalls == 1, "and it should have reached 0.3 by joining, not by restarting")
    }

    /// The flag the views read to decide whether to rejoin rather than offer a button.
    @Test func reportsWhetherADownloadIsRunning() async {
        let engine = CountingEngine()
        let service = TranscriptionService(store: store, engine: engine, audioRoot: directory)

        #expect(await service.isPreparingModels == false)
        async let running: Void = { try? await service.prepareModels { _ in } }()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await service.isPreparingModels)
        _ = await running
        // Cleared on failure too, or one failed download would wedge every later attempt.
        #expect(await service.isPreparingModels == false)
    }
}

/// A box a `@Sendable` closure can append to from whatever executor calls it.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func append(_ element: Double) where T == [Double] { lock.withLock { stored.append(element) } }
}
