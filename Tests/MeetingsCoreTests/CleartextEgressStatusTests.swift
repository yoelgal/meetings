import Foundation
import Testing

@testable import MeetingsCore

/// `meetings status` and the Settings pane read the same sentence out of
/// ``TranscriptionService/engineSummary()``, and until now only the pane said anything about a
/// cleartext endpoint.
///
/// The refusal in ``SettingKey/egressRefusal(_:for:)`` is a **write** gate by design, so somebody
/// upgrading with `http://lan-box:8080` already in the table keeps uploading every meeting's audio
/// in the clear and keeps being told, on the one line they run when something looks wrong, only that
/// it is "uploaded there". An upgrade is exactly when that line gets read.
@Suite final class CleartextEgressStatusTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Written straight to the table rather than through the CLI, because the point is a row the
    /// current gate would refuse — the only way one gets there is an older build.
    private func summary(baseURL: String) async throws -> String {
        try store.setSetting(.transcribeBatchEngine, "remote")
        try store.setSetting(.transcribeRemoteBaseURL, baseURL)
        try store.setSetting(.transcribeRemoteModel, "whisper-1")
        try store.setSetting(.transcribeRemoteKeyRef, "unit-test-cleartext")
        MeetingsKeychain.setSecret("sk-unit-test", account: "unit-test-cleartext")
        defer { MeetingsKeychain.setSecret(nil, account: "unit-test-cleartext") }
        return await TranscriptionService(store: store, engine: nil, audioRoot: directory)
            .engineSummary()
    }

    @Test func aStoredCleartextEndpointIsNamedAsOne() async throws {
        let line = try await summary(baseURL: "http://lan-box:8080/v1")
        #expect(line.contains("lan-box"))
        #expect(line.contains("in the clear"), "status has to say the audio is not encrypted")
        #expect(line.contains("http"), "and name the scheme, so the fix is obvious")
    }

    /// The warning has to be worth reading, which means it cannot appear on the configuration this
    /// app is *for*: a transcriber the user is running themselves, on this machine.
    @Test func httpsAndLoopbackAreLeftAlone() async throws {
        let secure = try await summary(baseURL: "https://api.openai.com/v1")
        #expect(!secure.contains("in the clear"))

        let loopback = try await summary(baseURL: "http://127.0.0.1:8080/v1")
        #expect(!loopback.contains("in the clear"), "a self-hosted endpoint never leaves the Mac")
    }
}
