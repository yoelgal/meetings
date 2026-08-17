import Foundation
import Testing

@testable import MeetingsCore

/// Adopting the write-up provider's credentials for transcription is a convenience with a knife in
/// it: the two features upload different things to different places, and the failure mode of getting
/// it wrong is one provider's API key transmitted to another provider along with the audio of every
/// meeting.
///
/// The Keychain here is always injected. A test that reached the real one would put the operator's
/// login Keychain in the blast radius of `swift test`.
@Suite final class RemoteCredentialAdoptionTests {
    let directory: URL
    let store: MeetingStore

    init() throws {
        directory = try TestStore.makeDirectory()
        store = try TestStore.open(directory)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A recording Keychain, so a test can assert what was written as well as what was returned.
    final class Vault {
        var items: [String: String] = [:]
        var writes: [(secret: String?, account: String)] = []

        func read(_ account: String) -> String? { items[account] }

        func write(_ secret: String?, _ account: String) {
            writes.append((secret, account))
            if let secret { items[account] = secret } else { items.removeValue(forKey: account) }
        }
    }

    private func adopt(_ vault: Vault) throws -> Bool {
        try store.adoptCloudCredentialsForTranscription(
            keychainRead: vault.read, keychainWrite: vault.write)
    }

    private func configureWriteUpProvider(
        url: String = "https://api.anthropic.com/v1",
        model: String = "claude-sonnet",
        keyRef: String = "cloud",
        secret: String = "sk-write-up",
        in vault: Vault
    ) throws {
        try store.setSetting(.aiCloudBaseURL, url)
        try store.setSetting(.aiCloudModel, model)
        try store.setSetting(.aiCloudKeyRef, keyRef)
        vault.items[keyRef] = secret
    }

    // MARK: - The convenience it exists for

    @Test func anEmptyTranscriptionFormAdoptsTheWholeTriple() throws {
        let vault = Vault()
        try configureWriteUpProvider(in: vault)

        #expect(try adopt(vault))

        #expect(try store.setting(.transcribeRemoteBaseURL) == "https://api.anthropic.com/v1")
        #expect(try store.setting(.transcribeRemoteModel) == "claude-sonnet")
        #expect(try store.setting(.transcribeRemoteKeyRef) == "transcribe")
        #expect(vault.items["transcribe"] == "sk-write-up", "the secret is copied, not the account name")
    }

    @Test func runningTwiceChangesNothingTheSecondTime() throws {
        let vault = Vault()
        try configureWriteUpProvider(in: vault)
        #expect(try adopt(vault))
        #expect(try adopt(vault) == false, "a second call has nothing left to fill")
    }

    @Test func nothingIsAdoptedWithoutAWriteUpEndpoint() throws {
        let vault = Vault()
        // A model and a key naming no provider: copying either would fill a form whose destination
        // nobody has stated.
        try store.setSetting(.aiCloudModel, "claude-sonnet")
        try store.setSetting(.aiCloudKeyRef, "cloud")
        vault.items["cloud"] = "sk-write-up"

        #expect(try adopt(vault) == false)
        #expect(try store.setting(.transcribeRemoteModel) == nil)
        #expect(try store.setting(.transcribeRemoteKeyRef) == nil)
        #expect(vault.writes.isEmpty)
    }

    // MARK: - The key never travels to an endpoint it does not belong to

    /// The leak this gate exists for, in the state the app manufactures by itself.
    ///
    /// `RemoteTranscriptionFields.load()` writes OpenAI's base URL onto the transcription row the
    /// first time that pane is *looked at*, and never writes a `keyRef`. Per-field adoption then found
    /// the endpoint occupied, skipped it, found the key empty and filled it from a different
    /// provider — so the next upload sent an Anthropic key to `api.openai.com` with the audio.
    @Test func aKeyIsNeverPairedWithAnEndpointFromAnotherProvider() throws {
        let vault = Vault()
        try configureWriteUpProvider(in: vault)
        // Exactly what viewing the cloud transcription pane once leaves behind.
        try store.setSetting(.transcribeRemoteBaseURL, "https://api.openai.com/v1")
        try store.setSetting(.transcribeRemoteModel, "whisper-1")

        #expect(try adopt(vault) == false, "a mismatched endpoint adopts nothing at all")

        #expect(try store.setting(.transcribeRemoteKeyRef) == nil,
                "the write-up provider's key must not be filed against another provider's endpoint")
        #expect(vault.items["transcribe"] == nil)
        #expect(vault.writes.isEmpty, "and nothing may be written to the Keychain either")
        #expect(try store.setting(.transcribeRemoteBaseURL) == "https://api.openai.com/v1",
                "the endpoint that was already chosen is left exactly as it was")
    }

    /// The same endpoint is the one case where the key does belong, so the convenience still works
    /// for somebody transcribing and writing up at the same provider.
    @Test func theSameEndpointStillAdoptsTheKey() throws {
        let vault = Vault()
        try configureWriteUpProvider(url: "https://api.openai.com/v1", in: vault)
        try store.setSetting(.transcribeRemoteBaseURL, "  https://api.openai.com/v1 ")

        #expect(try adopt(vault), "whitespace a text field left behind is not a different endpoint")
        #expect(try store.setting(.transcribeRemoteKeyRef) == "transcribe")
        #expect(vault.items["transcribe"] == "sk-write-up")
    }

    // MARK: - What is already there is never destroyed

    /// The row can be empty while the Keychain item is not: clearing the Keychain-account field in
    /// Settings stores nil on the row and leaves the secret behind. Guarding on the row alone
    /// destroyed a live key, because `setSecret` is a delete-then-add upsert.
    @Test func aLiveSecretUnderTheDestinationAccountIsNotOverwritten() throws {
        let vault = Vault()
        try configureWriteUpProvider(url: "https://api.openai.com/v1", in: vault)
        vault.items["transcribe"] = "sk-the-one-already-in-use"

        _ = try adopt(vault)

        #expect(vault.items["transcribe"] == "sk-the-one-already-in-use")
        #expect(!vault.writes.contains { $0.account == "transcribe" })
    }

    @Test func aTranscriptionKeyRefTheUserSetIsLeftAlone() throws {
        let vault = Vault()
        try configureWriteUpProvider(url: "https://api.openai.com/v1", in: vault)
        try store.setSetting(.transcribeRemoteKeyRef, "my-own-label")
        vault.items["my-own-label"] = "sk-mine"

        _ = try adopt(vault)

        #expect(try store.setting(.transcribeRemoteKeyRef) == "my-own-label")
        #expect(vault.items["transcribe"] == nil)
    }

    // MARK: - The egress gate applies to this door too

    /// `SettingKey.egressRefusal` is the write gate on the row that decides where every meeting's
    /// audio is uploaded, and both the Settings window and `meetings config set` enforce it. Adoption
    /// is the third writer of that row. A cleartext value can only be in `ai.cloud.baseURL` because it
    /// was written before the refusal shipped — promoting it here would put the audio on the wire in
    /// the clear through a door that never asked.
    @Test func aCleartextWriteUpEndpointIsNotPromotedOntoTheAudioRow() throws {
        let vault = Vault()
        try store.setSetting(.aiCloudBaseURL, "http://collector.example.com/v1")
        try store.setSetting(.aiCloudModel, "some-model")
        try store.setSetting(.aiCloudKeyRef, "cloud")
        vault.items["cloud"] = "sk-write-up"

        #expect(try adopt(vault) == false)
        #expect(try store.setting(.transcribeRemoteBaseURL) == nil)
        #expect(vault.writes.isEmpty)
    }

    /// A loopback endpoint is the configuration this app is *for* — a transcriber the user runs
    /// themselves — and the gate has always allowed it `http`.
    @Test func aLoopbackWriteUpEndpointIsStillAdopted() throws {
        let vault = Vault()
        try configureWriteUpProvider(url: "http://127.0.0.1:8080/v1", in: vault)

        #expect(try adopt(vault))
        #expect(try store.setting(.transcribeRemoteBaseURL) == "http://127.0.0.1:8080/v1")
    }
}
