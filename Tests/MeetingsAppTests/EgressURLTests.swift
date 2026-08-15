import Foundation
import MeetingsCore
import SwiftUI
import Testing

@testable import MeetingsApp

/// **The Settings window must not accept what `meetings config set` refuses.**
///
/// The refusal used to live in `ConfigCommand` alone, so the two rows that decide where this Mac's
/// audio and transcripts are uploaded were guarded on the command line and wide open in the window
/// — which writes on every keystroke, and swallowed the error if there had been one. Same rule, both
/// doors, asserted here against a real store rather than by reading the view as text.
@MainActor @Suite final class EgressURLTests {
    private let directory: URL
    private let store: MeetingStore

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meetings-egress-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MeetingStore(
            dbPool: try MeetingsDatabase.open(at: directory.appendingPathComponent("store.db"))
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Types `text` into the field the way the window does — through `SettingBinding`, one whole
    /// value at a time, which is what a paste is and what the last keystroke of typing is.
    private func type(_ text: String, into key: SettingKey) {
        let cache = Cache()
        let field = SettingBinding(store: store, key: key)
            .binding(Binding(get: { cache.text }, set: { cache.text = $0 }))
        field.wrappedValue = text
        #expect(cache.text == text, "the field still shows what was typed, accepted or not")
    }

    private final class Cache { var text = "" }

    @Test(arguments: [SettingKey.transcribeRemoteBaseURL, .aiCloudBaseURL])
    func theWindowRefusesACleartextEndpointExactlyAsTheCLIDoes(_ key: SettingKey) throws {
        type("https://api.example.com/v1", into: key)
        #expect(try store.setting(key) == "https://api.example.com/v1")

        type("http://collector.example.com/v1", into: key)
        #expect(try store.setting(key) == "https://api.example.com/v1", """
            A cleartext endpoint typed into Settings was stored. The audio of every meeting, or \
            every transcript, would go to it in the clear — and the CLI refuses the same value.
            """)

        // A self-hosted endpoint on this Mac never reaches the wire and has no certificate to
        // present, so it keeps its http — the configuration this app is for.
        type("http://127.0.0.1:8080/v1", into: key)
        #expect(try store.setting(key) == "http://127.0.0.1:8080/v1")

        // And clearing the field still clears the row: no endpoint is not an insecure endpoint.
        type("", into: key)
        #expect(try store.setting(key) == nil)
    }

    /// Every other row is unaffected — this is a rule about two keys, not a URL policy for the
    /// settings table.
    @Test func anOrdinarySettingIsWrittenWhateverItSays() throws {
        type("http://collector.example.com/v1", into: .aiManualPasteCommand)
        #expect(try store.setting(.aiManualPasteCommand) == "http://collector.example.com/v1")
    }

    /// A row written before the refusal existed keeps working — the app never refuses to run over a
    /// value it once accepted — and Settings says so where the value is shown.
    @Test func aStoredCleartextEndpointIsWarnedAboutRatherThanBroken() throws {
        try store.setSetting(.transcribeRemoteBaseURL, "http://lan-box:8080/v1")
        #expect(try store.setting(.transcribeRemoteBaseURL) == "http://lan-box:8080/v1",
                "the stored value stays readable; the fix is a warning, not a lockout")

        let warning = try #require(
            SettingKey.egressRefusal("http://lan-box:8080/v1", for: .transcribeRemoteBaseURL)
        )
        #expect(warning.contains("in the clear"), "and the warning has to say what is wrong")
        #expect(SettingKey.egressRefusal("http://localhost:11434/v1", for: .aiCloudBaseURL) == nil)
        #expect(SettingKey.egressRefusal("https://api.openai.com/v1", for: .aiCloudBaseURL) == nil)
    }
}
